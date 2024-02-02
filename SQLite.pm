#--------------------------------------------------
# Pub::SQLite.pm
#--------------------------------------------------
# Generic handled based interface to SQLite database(s)

package Pub::SQLite;
use strict;
use warnings;
use threads;
use threads::shared;
use DBI;
use Pub::Utils;

my $dbg_db = 0;
my $dbg_sqlite = 1;


our $SQLITE_UNICODE = 0;
	# This define goes to the heart of the problem with character
	# encodings, filenames, and attempting to share the database
	# on windows and linux.


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

		defineDatabase

        db_connect
        db_disconnect

		create_table

        get_record_db
		insert_record_db
		update_record_db
        get_records_db

        db_do

		get_table_fields
		db_init_rec

    );
};



my $default_dbuser:shared = '';
my $default_dbname:shared = '';
my $field_defs:shared = shared_clone({});
my $table_fields:shared = shared_clone({});


#-------------------------------------
# low level routines
#-------------------------------------

sub defineDatabase
	# MUST BE CALLED INLINE BY CLIENT!
{
	my ($user,$dbname,$defs) = @_;
	$default_dbuser = $user;
	$default_dbname = $dbname;
	$field_defs = $defs;

	for my $table (keys %$field_defs)
	{
		my $fields = shared_clone([]);
		$table_fields->{$table} = $fields;
		for my $def (@{$field_defs->{$table}})
		{
			my $copy = $def;
			$copy =~ s/\s.*$//;
			push @$fields,$copy;
		}
	}
}


sub sqlite_connect
{
	my ($db_name, $user, $password) = @_;

	# 2024-01-18 $SQLITE_UNICODE is an to determine
	# whether the database is stored in utf-8 or raw byte formats.
	# On windows, 1252 default encoding is same as the raw encoding (it's bytes only)
	# so, as long as we don't turn the flag on, the database is created thusly.

	$password ||= '';
    display($dbg_sqlite,0,"db_connect SQL_UNICODE=$SQLITE_UNICODE");

	my $dsn = "dbi:SQLite:dbname=$db_name";
	my $dbh = DBI->connect($dsn,$user,$password,{sqlite_unicode => $SQLITE_UNICODE });
    if (!$dbh)
    {
        error("Unable to connect to Database: ".$DBI::errstr);
        exit 1;
	}

	# On linux, this *might* be needed even if we specify $SQLITE_UNICODE = 0,
	# we still get the database stored (and retrievedd in utf-8)
	#
	if (!$SQLITE_UNICODE && !is_win())
	{
			use if !is_win(), 'DBD::SQLite::Constants';
			$dbh->{sqlite_string_mode} = DBD::SQLite::Constants::DBD_SQLITE_STRING_MODE_BYTES();
	}

	return $dbh;
}


sub sqlite_disconnect
{
	my ($dbh) = @_;
    display($dbg_sqlite,0,"db_disconnect");
    if (!$dbh->disconnect())
    {
        error("Unable to disconnect from database: ".$DBI::errstr);
        exit 1;
    }
}



#-------------------------------------
# API
#-------------------------------------

sub db_connect
{
	my ($db_name) = @_;
	$db_name ||= $default_dbname;

    display($dbg_db,0,"db_connect($db_name)");
	my $dbh = sqlite_connect($db_name,$default_dbuser,'');
	error("Could not connect to database($db_name)") if !$dbh;
	return $dbh;
}


sub db_disconnect
{
	my ($dbh) = @_;
    display($dbg_db,0,"db_disconnect");
	sqlite_disconnect($dbh);
}


sub get_table_fields
{
    my ($table) = @_;
    display($dbg_db+1,0,"get_table_fields($table)");
	return $table_fields->{$table};
}


sub create_table
{
	my ($dbh,$table) = @_;
	display($dbg_db,0,"create_table($table)");
	my $def = join(',',@{$field_defs->{$table}});
	$def =~ s/\s+/ /g;
	$dbh->do("CREATE TABLE $table ($def)");
}


sub db_init_rec
{
	my ($table) = @_;
	my $rec = shared_clone({});
    for my $def (@{$field_defs->{$table}})
	{
		my ($field,$type) = split(/\s+/,$def);
		my $value = '';
		$value = 0 if $type =~ /^(INTEGER|BIGINT)$/i;
		$$rec{$field} = $value;
	}
	return $rec;
}


sub get_record_db
{
    my ($dbh,$query,$params) = @_;
    display($dbg_sqlite,0,"get_record_db()");
    my $recs = get_records_db($dbh,$query,$params);
    return $$recs[0] if ($recs && @$recs);
    return undef;
}


sub insert_record_db
	# inserts ALL table fields for a record
	# and ignores other fields that may be in rec.
	# best to call init_rec before this.
{
	my ($dbh,$table,$rec) = @_;

    display($dbg_db+1,0,"insert_record_db($table)");
	my $fields = get_table_fields($table);

	my @values;
	my $query = '';
	my $vstring = '';
	for my $field (@$fields)
	{
		$query .= ',' if $query;
		$query .= $field;
		$vstring .= ',' if $vstring;
		$vstring .= '?';
		push @values,$$rec{$field};
	}
	return db_do($dbh,"INSERT INTO $table ($query) VALUES ($vstring)",\@values);
}


sub update_record_db
{
	my ($dbh,$table,$rec,$id_field) = @_;
	$id_field ||= 'id';

	my $fields = get_table_fields($table);
	my $id = $$rec{$id_field};

    display($dbg_db+1,0,"update_record_db($table) id_field=$id_field id_value=$id");

	my @values;
	my $query = '';
	for my $field (@$fields)
	{
		next if (!$field);
		next if ($field eq $id_field);
		$query .= ',' if ($query);
		$query .= "$field=?";
		push @values,$$rec{$field};
	}
	push @values,$id;

	return db_do($dbh,"UPDATE $table SET $query WHERE $id_field=?",
		\@values);
}


sub get_records_db
{
    my ($dbh,$query,$params) = @_;
    $params = [] if (!defined($params));

    display($dbg_sqlite,0,"get_records_db($query)".(@$params?" params=".join(',',@$params):''));

    # not needed
	# implement SELECT * FROM table
    #
	#if ($query =~ s/SELECT\s+\*\s+FROM\s+(\S+)(\s|$)/###HERE###/i)
    #{
    #    my $table = $1;
    #    my $fields = join(',',@{get_table_fields($table)});
    #    $query =~ s/###HERE###/SELECT $fields FROM $table /;
    #}


	my $sth = $dbh->prepare($query);
    if (!$sth)
    {
        error("Cannot prepare database query($query): $DBI::errstr");
        return; # [];
    }
	if (!$sth->execute(@$params))
    {
        error("Cannot execute database query($query): $DBI::errstr");
        return; #  [];
    }

    my @recs;
	while (my $data = $sth->fetchrow_hashref())
	{
		push(@recs, $data);
    }
    if ($DBI::err)
    {
        error("Data fetching query($query): $DBI::errstr");
        return;
    }

    display($dbg_sqlite,1,"get_records_db() found ".scalar(@recs)." records");
    return \@recs;
}


sub db_do
    # general call to the database
    # used for insert, update, and delete
{
	my ($dbh,$query,$params) = @_;

	# display

	my $param_str = 'no params';
	if (defined($params) && @$params)
	{
		for my $p (@$params)
		{
			$p = 'undef' if (!defined($p));
			$param_str .= ',' if ($param_str);
			$param_str .= $p;
		}
	}
    display($dbg_sqlite,0,"db_do($query) $param_str");

    $params = [] if (!defined($params));
	my $sth = $dbh->prepare($query);
    if (!$sth)
    {
        error("Cannot prepare insert query($query): $DBI::errstr");
        return;
    }
    if (!$sth->execute(@$params))
    {
        error("Cannot execute insert query($query): $DBI::errstr)");
        return;
    }
    return 1;
}


1;
