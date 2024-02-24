#!/usr/bin/perl
#--------------------------------------------------------
# PUB::Database
#-------------------------------------------------------
# Cava packager requires explicit Force Include
# Modules DBD:mysql and DBD::SQLite
#
# 2024-02-18 - Created from My::Database
#
# - databases only have VAR/CHAR, INTEGER, FLOAT, and BOOL fields
#
# - field {name} limited to 15 chars in some implementations
#
# - insert_record and update_record do not do partial updates.
#   update_record() has a param to allow $subset update.
#
# - Datetimes are stored in a text(26) format:
#
#	__DATE__ which is a VARCHAR(10) storage for a
# 		simple YYYY-MM-DD date
# 	__DATE_TIME__ which is a VARCHAR(26) storage for
#	    fully encoded GMT date time stamps
#
#   	yyyy-mm-dd hh:mm:ss -dd:dd
#
# 		where -dddd is the timezone offset from GMT
# 		(i.e. -05:00 for Bocas)
#
# - Error Handling
#
#   get_record() is not easily error checked.
#		as it may return undef for no record found
#	most other methods can be checked for undef/0 returns
#		indicating that an error has occurred
#	if an error occurs, $this->{errstr} will likely contain it
#		but may be stale, so don't check just it.
#	Most existing code was built to handle errors by wrapping
#		call chains in try{}{ blocks, and db failures typically
#		threw exceptions.
#	In this port, the throw() is disabled, and warnings are disabled,
#		by default.  They can be turned on by $params, either to
#		alleviate error checking, and/or to provide more visibility
#
#			PrintWarn
#			RaiseWarn
#			PrintError
#			RaiseError
#
#		'RaiseWarn' will cause exceptions, which you probably don't want for warnings!
#		'PrintWarn' might be useful
#		'RaiseError' is how it used to work.
#
# - AutoCommit
#
#	AutoCommit is explicitly set to 1 if not defined in $params
#
# - DBI Error 0E0
#
#    DBI $stmt->execute() may return a string '0E0' which perl interprests
#	 as a true boolean value if ('0E0') { code happens }
#
#    This works 'ok' for get_records(), as apparently perl dereferences @$rslt (@E0E)
#    as an 'empty array' without hanging, and I basically only look for records, or not.
#    But insert_record and update_record, and many other calls (i.e. direct sql(UPDATE)
#    statements, the expectation is a 0 or undef failure result, but that was not happening.
#
#    It is a thorny issue because it depends on the caller, and I can't just change
#    execute to start returning errors (execute() comes in varieties: do(), sql(), etc),
#    down to the fact that there may be direct uses of $db or $stmt in the code.
#
#-------------------------------------------------
# Notes 2024-02-18
#-------------------------------------------------
# I don't like the way you have to create a separate set of paramters for new
# databases ala first stab at inventory.  This will be really complicated on
# artisan.  But I need to take a break and think about it.


package Pub::Database;
use strict;
use warnings;
use DBI qw(:sql_types);
# use XBase;
# Stand-alone external DBF files are a different issue
use Pub::Utils;
use Pub::Prefs;
use Pub::DatabaseDefs;
use Pub::DatabaseImport;
use if !is_win(), 'DBD::SQLite::Constants';


our $dbg_db      	= 1;		# 0..1 connect() and disconnect()
our $dbg_params  	= 1;		# 0..1 standard_params()
our $dbg_defs    	= 1;		# 0..2 getFieldNamaes() and getFieldDefs()

our $dbg_get_rec	= 1;		# 0..1 get_record()
our $dbg_get_recs	= 1;		# 0..1 get_records()

our $dbg_exec   	= 1;		# 0..1 execute()
our $dbg_do   		= 1;		# 0..1 db_do()

our $dbg_create 	= 0;		# 0..2 createTable() && createDatabase()
our $dbg_insert 	= 1;		# 0..2 insert_record()
our $dbg_update 	= 1;		# 0..2 update_record()
our $dbg_bind    	= 1;		# 0..2 binding

our $dbg_exists     = 1;		# 0..1 databaseExists()
our $dbg_list	    = 1;		# 0..2 listDatabases()

our $dbg_import    	= 1;		# 0..2 importTableTextFile
our $dbg_export     = 1;		# 0..1 exportTableTextFile()



BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

		$DEFAULT_ENGINE

	    $engine_mysql
        $engine_sqlite
        $engine_postgres
    );

	push @EXPORT,@Pub::DatabaseDefs::EXPORT;
}


our $engine_mysql = 'mysql';
our $engine_sqlite = 'SQLite';
our $engine_postgres = 'Pg';

our $DEFAULT_ENGINE = $engine_sqlite;

our $field_type_cache = {};



# sub checkDBIResult
# 	# I have seen cases where DBI will return '0E0' for failures
#	# thinking that perl, will think it is zero, but that is not the case.
# 	# Here we check for it, and return 0.
# {
# 	my ($dbi_result) = @_;
# 	return 0 if $dbi_result && $dbi_result eq '0E0';
# 	return $dbi_result;
# }



#------------------------
# Params
#------------------------

sub isSQLite
{
    my ($this) =  @_;
    return $this->{engine} eq $engine_sqlite ? 1 : 0;
}

sub isMySQL
{
    my ($this) =  @_;
    return $this->{engine} eq $engine_mysql ? 1 : 0;
}

sub isPostgres
{
    my ($this) =  @_;
    return $this->{engine} eq $engine_postgres ? 1 : 0;
}



sub standard_params
{
    my ($in_params) = @_;
	display_hash($dbg_params,0,"standard_in_params(()",$in_params);
	my $out_params = {};
	mergeHash($out_params,$in_params);

    $out_params->{engine} ||= getPref("DATABASE_ENGINE");
    $out_params->{engine} ||= $DEFAULT_ENGINE;

	# standard pref based params (MYSQL_ PG_)

	my $pref_id = uc($out_params->{engine});

	if ($out_params->{engine} ne $engine_sqlite)
	{
		$out_params->{host} ||= getPref($pref_id.'_HOST');
		$out_params->{port} ||= getPref($pref_id.'_PORT');
		$out_params->{user} ||= getPrefDecrypted($pref_id.'_USER');
		$out_params->{password} ||= getPrefDecrypted($pref_id.'_PASS');
	}

	# $params->{sqlite_unicode} = 1 if isSQLite($params);
	$out_params->{sqlite_string_mode} = DBD::SQLite::Constants::DBD_SQLITE_STRING_MODE_BYTES()
		if !is_win();

	# all postgress and mySQL databases are lowercased

	$out_params->{database} = lc($out_params->{database}) if
		$out_params->{database} &&
		$out_params->{engine} ne $engine_sqlite;

	$out_params->{AutoCommit} = 1 if !defined($out_params->{AutoCommit});

	# don't clutter params with defaults if not needed
	# $out_params->{PrintWarn}  ||= 0;
	# $out_params->{RaiseWarn}  ||= 0;
	# $out_params->{PrintError} ||= 0;

	# we now set RaiseError to zero by default
    $out_params->{RaiseError} ||= 0;

	display_hash($dbg_params,0,"standard__out_params(()",$out_params);
    return $out_params;
}




#---------------------------------------------
# connect, disconnect
#---------------------------------------------

sub connect
    # Client must pass in correct parameters and/or some that may
	# be present in preferences.
	#
	#	engine
	#		defaults to $engine_sqlite
	#	database
	#		required fully qualified filename for SQLite.
	#		Optional I think for mySQL and Postgres
	#		I think you can query both mySQL and postgres for existing databases
	#
	#	host
	#		for mySQL and Postgres servers
	#		can use MYSQL_HOST or PG_HOST preferences
	#		defaults to '', which I think is equivilant of 'localhost'
	#	port
	#		for mySQL and Postgres
	#		can use MYSQL_PORT or PG_PORT preferences
	#		I think/hope defaults for mySQL(XXXX) and Postgres(5432)
	#		are built in
	#	user
	#		for mySQL and Postgres
	#		not sure whats required for mySQL
	#		can use MYSQL_USER or PG_USER encrypted preferences
	#	password
	#		for mySQL and Postgres
	#		not sure whats required for mySQL
	#		can use MYSQL_PASS or PG_PASS encrypted preferences
	#
	#	database_def
	#		required database definition
	#
	# NOTES REGARDING SQLITE_UNICODE and MODE_BYTES
	#
	#	I generally want to get back exactly what I put into a database.
	#	It gets tricky in Perl with the stupid implicity utf8-typing, and
	#   transfering data to and from web browsers.
	#
	#	The initial 2024-02-18 port of this is going to use the encoding
	#	scheme cooked up for Artisan. We NEVER use sqlite_unicode=>1.
	#   On windows this results in 1252 encoding, which is equivilant
	#   to byte encoding.
	#
	#	On linux we specify DBD_SQLITE_STRING_MODE_BYTES to ensure that
	#   the data is not encoded or decoded when putting or getting from
	#   the database.
	#
    # Params must include the correct database_def
    # See openOrCreateDatabase for generalized entry point.
    # Allows for connection to the driver (mySQL) without a specific database
    # mySQL connects to a database fail if it doesn't exist
    # sqlite creates the database if it doesn't exist
    # my $dsn = "dbi:SQLite:dbname=$database";
{
    my ($class,$params) = @_;
    my $this = standard_params($params);
    bless $this,$class;
	$this->{errstr} = '';

    my $dsn = "dbi:$this->{engine}:".( $this->{database} ? "database=$this->{database};" : '');

	my $dbg_dsn = $dsn;
	if ($this->isPostgres())
	{
		for my $key (qw(port host user password))
		{
			if ($this->{$key})
			{
				$dsn .= "$key=$this->{$key};";
				$dbg_dsn .= "$key=$this->{$key};"
					if $key !~ /pass/i;
			}
		}
	}

    display($dbg_db,0,"connect($dbg_dsn)");
    $this->{dbh} = DBI->connect($dsn,$this->{user},$this->{password},$this);
    if (!$this->{dbh})
    {
        error("Unable to connect($dbg_dsn): $DBI::errstr");
        return;
    }

	# post connect standard settings

	if ($this->isPostgres())
	{
		if ($ENV{windir})
		{
			display($dbg_db,1,"setting client encoding to WIN1252 and pg_enable_utf8=0");
			$this->{dbh}->{pg_enable_utf8} = 0;
			$this->{dbh}->do("SET CLIENT_ENCODING TO 'WIN1252'");
		}
		else
		{
			display($dbg_db,1,"setting client encoding to UTF8 and pg_enable_utf8=1");
			$this->{dbh}->{pg_enable_utf8} = 0;
			$this->{dbh}->do("SET CLIENT_ENCODING TO 'UTF8'");
		}
	}

    display($dbg_db,1,"connected to database");
    return $this;
}




sub disconnect
{
    my ($this) = @_;
	$this->{errstr} = '';
    return warning(0,0,"$this->{database} already disconnected") if !$this->{dbh};
	display($dbg_db,0,"disconnect($this->{database}}");
    if (!$this->{dbh}->disconnect())
    {
		$this->{errstr} = $this->{dbh}->errstr || '';
        error("Unable to disconnect from database($this->{database}): $this->{errstr}");
        return;
    }

    # since there is only one database handle in the program right now,
    # and since this is the only file that knows we are using mysql,
    # and since you get errors if you don't call this:

   if (00 && !isSQLite($this))
   {
        display(0,0,"ending my_sql threads ...");
        # mysql_thread_end();
        # my $drh = DBI->install_driver("mysql");
        # my $rc = $drh->func('shutdown', $host, $user, $password, 'admin');
        my $rc = $this->{dbh}->do('SHUTDOWN');
        display(0,0,"back from my_sql threads ...rc = "._def($rc));
   }

    $this->{dbh} = undef;
    return 1;
}




#-----------------------------------------------------------
# Field Information and Utilties
#-----------------------------------------------------------

sub getFieldNames
	# returns an array of field names for a given table
	# can be called directly with $this==undef and $defs
{
	my ($this,$table,$defs) = @_;
	display($dbg_defs,0,"getFieldNames($table,"._def($defs).")".($this?'':" this(undef)"));
    $defs ||= $this->{database_def} if $this;
	my $fields = $defs->{$table};
	my @retval;

	for my $field (@$fields)
	{
		my ($name) = split(/\s+/,$field,2);
		display($dbg_defs+1,1,"name=$name");
		push @retval,$name;
	}
	return \@retval;
}



sub getFieldDefsArray
	# Return array of processed defs, in order
	# cached on $this if possible for speed
{
    my ($this,$table,$db_defs) = @_;
	return $this->{def_cache_array}->{$table}
		if $this && $this->{def_cache_array} && $this->{def_cache_array}->{$table};

	display($dbg_defs,0,"getFieldDefsArray($table,"._def($db_defs).")".($this?'':" this(undef)"));
    $db_defs ||= $this->{database_def} if $this;

	if (!$db_defs)
	{
		error("no defs in getFieldDefsArray($table)") if !$db_defs;
		return;
	}

	my $standard_id_create = !$this ? '' :
		$this->isPostgres() ? 'SERIAL' :
		$this->isMySQL() ? 'INTEGER PRIMARY KEY AUTO_INCREMENT' :
		'INTEGER PRIMARY KEY AUTOINCREMENT';

    my $result = [];
	my $table_def = $db_defs->{$table};
	if (!$db_defs)
	{
		error("no table_def in getFieldDefsArray($table)") if !$table_def;
		return;
	}

	my $colnum = 0;
    for my $field_def (@$table_def)
    {
		# field {name} limited to 15 chars in some implementations
		#
		# {def_type} = CHAR/VARCHAR, INTEGER, FLOAT, and BOOL or
		#
		#	__STANDARD_ID_FIELD__ which is a unique, autoincrementing
		#     	primary key given by using $STANDARD_ID_FIELD
		#	__DATE__ which is a VARCHAR(10) storage for a
		# 		simple YYYY-MM-DD date
		# 	__DATE_TIME__ which is a VARCHAR(26) storage for
		#	    fully encoded GMT date time stamps
		#
		# {type} maps those special types into their
		# 	underlying actual database type
		#
		# {create} is everything else in the spec

		my @parts = split(/\s+/,$field_def);
		my $name = shift(@parts);
		my $def_type = shift(@parts);
		my $rest = join(' ',@parts);

		my $type = $def_type;
		$type =~ s/$DB_FIELD_TYPE_DATE/$DB_FIELD_DEF_DATE/;
		$type =~ s/$DB_FIELD_TYPE_DATETIME/$DB_FIELD_DEF_DATETIME/;

		my $create = '';

		if ($def_type eq $STANDARD_ID_FIELD_TYPE)
		{
			$type = 'INTEGER';
			$create = $standard_id_create;
		}
		else
		{
			$create = $type;
			$create .= " COLLATE NOCASE" if
				$type eq 'VARCHAR' &&
				$this && $this->{engine} eq $engine_sqlite;
			$create .= " $rest" if $rest;
		}

        # width is used for display width as needed
		# CHAR/VARCHAR according to their length
		# BOOLS 4, FLOATS 8, INTEGERS 7

        my $width = $type =~ s/\((\d+)\)// ? $1 :
			$type eq 'BOOL' ? 4 :
            $type eq 'FLOAT' ? 8 : 7;

        my $def = {
            name => $name,
			colnum => $colnum++,
			type => $type,
			create => $create,
 			def_type => $def_type,
			# sql_type => myTypeToSQL_TYPE($type),
            width => $width,
            auto_increment => $def_type =~ /^$STANDARD_ID_FIELD_TYPE/ ? 1 : 0,
        };
		push @$result,$def;
		display_hash($dbg_defs+1,1,"def($name)",$def);
    }

	if ($this)
	{
		$this->{def_cache_array} ||= {};
		$this->{def_cache_array}->{$table} = $result;
	}

    return $result;
}



sub getFieldDefs
    # returns hash of defs by field name
	# for the given table
{
    my ($this,$table,$defs) = @_;
	return $this->{def_cache}->{$table}
		if $this && $this->{def_cache} && $this->{def_cache}->{$table};

    my $result = {};
    my $table_def = getFieldDefsArray($this,$table,$defs);
	return if !$table_def;
    for my $def (@$table_def)
    {
        $result->{$def->{name}} = $def;
    }

	if ($this)
	{
		$this->{def_cache} ||= {};
		$this->{def_cache}->{$table} = $result;
	}

    return $result;
}



#------------------------------------------------------------
# General SQL statements
#------------------------------------------------------------

sub createTable
{
	my ($this,$table,$defs) = @_;
	display($dbg_create,0,"createTable($table)");
	my $table_def = getFieldDefsArray($this,$table,$defs);
	return if !$table_def;

	my $text_defs = '';
	for my $def (@$table_def)
	{
		display($dbg_create,1,pad($def->{name},20)." ".$def->{create});

		$text_defs .= ',' if $text_defs;
		$text_defs .= "$def->{name} $def->{create}";
	}
	if (!$this->do("CREATE TABLE $table ($text_defs)"))
	{
		error("Could not create table $table: $this->{errstr}");
		return;
	}
	return 1;
}


sub get_record
	# $params parameter for binding was never used and
	# removed upon merging with vpoledb (My::SQL)
	# 2021-05-22 - added bound parameters back in
{
    my ($this,$query,$params) = @_;
    display($dbg_get_rec,0,"get_record($query)");
    my $recs = $this->get_records($query,$params);
	my $rec = $recs && @$recs ? $$recs[0] : undef;
    display($dbg_get_rec,0,"get_record($query)="._def($rec));
    return $rec;
}



sub get_records
	# $params parameter for binding was never used and
	# removed upon merging with vpoledb (My::SQL)
	# 2021-05-22 - added bound parameters back in
{
    my ($this,$query,$params) = @_;
	$this->{errstr} = '';
    display($dbg_get_recs,0,"get_records($query)");

	my @recs;
	my $sth = $this->execute($query,$params);
	if ($sth)
	{
		while (my $data = $sth->fetchrow_hashref())
		{
			push(@recs, $data);
		}
		if ($DBI::err)
		{
			$this->{errstr} = $sth->errstr || '';
			error("Data fetching query($query): $this->{errstr}");
			$sth->finish();

			return;
		}
	    $sth->finish();
	    display($dbg_get_recs,1,"get_records() found ".scalar(@recs)." records");
	}

    return \@recs;
}



sub insert_record
	# accepts sparse record
    # inserts ALL table fields for a record
	# emulating init_empty_rec
    # and ignores other fields that may be in rec.
{
    my ($this,$table,$rec) = @_;

    display_hash($dbg_insert,0,"insert_record($table)",$rec);

	my $table_def = $this->getFieldDefsArray($table);
	return if !$table_def;

    my $fstring = '';
    my $vstring = '';
    my $bind_values = [];

    for my $def (@$table_def)
    {
		next if $def && $def->{auto_increment};
		    # do not set the magic autoincrement ID

		my $field = $def->{name};
        $fstring .= ',' if $fstring;
        $fstring .= $field;;
        $vstring .= ',' if $vstring;
        $vstring .= '?';

		my $val = $rec->{$field};
		$val = '0' if !$val && $def->{type} =~ /INTEGER|FLOAT/;

		display($dbg_bind+1,2,"$field='"._def($val)."'");
		push @$bind_values,$val;
    }

	# binding with SQL_TYPES does not seem to work on postgress
	# therefore, I am going back to the default binding offered
	# by execute(), which always worked before

	my $query = "INSERT INTO $table ($fstring) VALUES ($vstring)";
	display($dbg_bind,1,"query=$query");

	my $rslt = $this->execute($query,$bind_values);
	return $rslt;
}



sub update_record
{
    my ($this,$table,$rec,$id_field,$id_value,$subset) = @_;
	$subset ||= 0;

    display_hash($dbg_update,0,"update_record($table,$id_field,"._def($id_value).",$subset)",$rec);

	my $table_def = $this->getFieldDefsArray($table);
	return if !$table_def;

	# Set the ID field/value

	$id_field ||= $table_def->[0]->{name};
    $id_value = $rec->{$id_field} if !defined($id_value);
    display($dbg_update,1,"id_field=$id_field id_value=$id_value");

	# Build the Bind data

    my $vstring = '';
    my $bind_values = [];
    for my $def (@$table_def)
    {
		my $field = $def->{name};
        next if ($field eq $id_field);

		my $val = $rec->{$field};
		next if $subset && !defined($val);

        $vstring .= ',' if $vstring;
        $vstring .= "$field=?";

		$val = '0' if !$val && $def->{type} =~ /INTEGER|FLOAT/;
		display($dbg_bind+1,2,"$field='"._def($val)."'");

		push @$bind_values,$val;
    }

	push @$bind_values,$id_value;

	my $query = "UPDATE $table SET $vstring WHERE $id_field=?";
	display($dbg_bind,1,"query=$query");

	my $rslt;
	$rslt = $this->execute($query,$bind_values);
	return $rslt;
}




sub execute
	# low level method that returns a sth statement handle
	# allowing for working with cursors on large record sets
{
    my ($this,$query,$params) = @_;
	$params ||= [];
    display($dbg_exec,0,"execute() params="._def($params));

	$this->{errstr} = '';
    my $dbh = $this->{dbh};
    my $sth = $dbh->prepare($query);
    if (!$sth)
    {
		my $errstr = $dbh->errstr || '';
        error("Cannot prepare query($query): $errstr");
		$this->{errstr} = $errstr;
        return;
    }

	my $rslt = $sth->execute(@$params);

	# display(0,0,"execute() returned "._def($rslt));
	# $rslt = checkDBIResult($rslt);
	# we do not report '0E0' as an error, but this is a problem

	if (!$rslt)
    {
		my $errstr = $sth->errstr || '';
        error("Cannot execute query($query): $errstr");
		$this->{errstr} = $errstr;
        $sth->finish();
        return;
    }

	return $sth;
}



sub do
    # general call to the database
    # used for insert, update, and delete
	# calls execute() and finishes the $sth
{
    my ($this,$query,$params) = @_;
    display($dbg_do,0,"do($query) params="._def($params));
	my $sth = $this->execute($query,$params);
	$sth->finish() if $sth;
    return $sth ? 1 : 0;
}




#---------------------------------------
# High Level Database Functions
#---------------------------------------

sub databaseExists
	# SQLite tests directly for the existence of the database file
	# mySQL and postgress require params, get a list, and check against that.
{
    my ($params) = @_;
    my $database = $params->{database};
    my $exists = 0;
    if (isSQLite($params))
    {
        $exists = -f "$database" ? 1 : 0;
    }
    else
    {
		$database = lc($database);
        my $db_hash = listDatabases($params);
        $exists = $db_hash->{$database} ? 1 : 0;
    }
    display($dbg_exists,0,"databaseExits($database)=$exists");
    return $exists;
}



sub listDatabases
     # SQLite will list databases in the $data dir
{
    my ($params) = @_;

    display_hash($dbg_list,0,"listDatabases()",$params);
    my %db_hash;

    if (isSQLite($params))
    {
        if (!opendir(DIR,$data_dir))
        {
            error("Could not opendir $data_dir for reading");
            return \&db_hash;
        }
        while (my $db = readdir(DIR))
        {
            if ($db =~ s/\.db$//)
            {
                $db_hash{"$data_dir/$db"} = 1;
                display($dbg_list+1,1,"$db");
            }
        }
        closedir DIR;
        return \%db_hash;
    }

    # otherwise, do it by dbi driver call

	my $dbi_params = '';
	my $std_params = standard_params($params);

	for my $key (qw(port host user password))
	{
		if ($std_params->{$key})
		{
			$dbi_params .= ';' if $dbi_params;
			$dbi_params .= "$key=$std_params->{$key}";
		}
	}
	display($dbg_db,0,"listDatabases($std_params->{engine})"); # $use_params")

    my @databases = DBI->data_sources($std_params->{engine},$dbi_params);

    for my $db (@databases)
    {
        display($dbg_list+1,1,"raw $db");
        $db =~ s/^.*:// if isMySQL($std_params);
		$db = $1 if $db =~ /dbname=(.*?);.*$/ && isPostgres($std_params);
        display($dbg_db,2,"final $db");
        $db_hash{$db} = 1 if $db;
    }

    return \%db_hash;
}



sub deleteDatabase
{
    my ($params) = @_;
	my $database = $params->{database};
    LOG(0,"deleteDatabase($database)");

    my $rslt = 0;
	my $errstr = '';
    if (isSQLite($params))
    {
        $rslt = unlink $params->{database};
    }
    else
    {
		$params->{database} = '' if isPostgres($params);
        my $this = Pub::Database->connect($params);
		$params->{database} = $database;	# restore
        return if !$this;
        $rslt = $this->do("DROP DATABASE $database");
		$errstr = $this->{errstr} if !$rslt;
		$this->disconnect();
    }
    error("Could not delete database($database): $errstr")
        if !$rslt;
    return $rslt;
}


sub createDatabase
	# for SQLite connect() is sufficient to create a database.
	# This method must be called for mySQL and postgress.
	# Caller must create tables as needed.
{
    my ($class,$params) = @_;
    my $database = $params->{database};
    LOG(0,"createDatabase($database)");

    # we have to login without the database member with mySQL

    if (isSQLite($params))
	{
		return $class->connect($params);
	}

	my $temp_params = {};
	mergeHash($temp_params,$params);
	delete $temp_params->{database};
	my $this = $class->connect($temp_params);
	return if !$this;

	$database = lc($database);

	my $extra_params = isPostgres($params) && $ENV{windir} ?
		"WITH TEMPLATE=template0 ENCODING='WIN1252'" : '';

	my $rslt = $this->do("CREATE DATABASE $database $extra_params");
	$this->disconnect();

	if (!$rslt)
	{
		error("Could not create database $database: $this->{errstr}");
		return;
	}

    $this = $class->connect($params);
	return $this;

}


#------------------------------------------
# tableExists
#------------------------------------------
# apparently not implemented for mySQL

sub tableExists
{
	my ($this,$table) = @_;
	my $query = '';
	if ($this->isSQLite())
	{
		$query = "SELECT name FROM sqlite_master WHERE type='table' AND name='$table'";
	}
	elsif ($this->isPostgres())
	{
		$query = "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename='$table'";
	}

	if ($query)
	{
		my $rslt = $this->get_record($query) ? 1 : 0;
		LOG(0,"tableExists($table)=$rslt engine=$this->{engine} query=$query");
		return $rslt;
	}

	error("tableExists($table) not implemented for engine=$this->{engine}");
	return 0;
}




#----------------------------------------------
# generic import/export from text file
#----------------------------------------------


sub generic_lr_value
{
	my ($line) = @_;
	$line =~ s/\s*$//;
	$line =~ s/^\s*//;
	$line =~ s/#.*$//;
	my $pos = index($line,'=');
	if ($pos > 0)
	{
		my $l = substr($line,0,$pos);
		my $r = substr($line,$pos+1);
		$l =~ s/\s*$//;
		$l =~ s/^\s*//;
		$r =~ s/\s*$//;
		$r =~ s/^\s*//;
		return (lc($l),$r);
	}
}


sub importTableTextFile
	# imports a text file that # allows # comments
	# that is created by hand or exportTableTextFile.
	# A new record is triggered when the text file contains
	# a PRIMARY_KEY=value line.
{
    my ($this,$table,$text_file,$drop_old) = @_;
	$drop_old ||= 0;
	LOG(0,"importTableTextFile($table,$text_file) DROP_OLD=$drop_old");

	my $table_def = $this->getFieldDefsArray($table);
	if (!$table_def)
	{
		error("Could not find table definition for $table");
		return;
	}

	# check to see if file exists, we'll open it later

	if (!-f $text_file)
	{
		error("File($text_file) not found in importTableTextFile($table)");
		return;
	}

	# if $drop_old
	# get the 'raw' defs (array of text lines)
	# for use with createTable if needed,
	# drop and recreate the table

	if ($drop_old)
	{
		LOG(1,"DROPPING old table($table)");
		if (!$this->do("DROP TABLE $table"))
		{
			error("Could not DROP old table($table): $this->{errstr}");
			return;
		}

		LOG(1,"CREATING new table($table)");
		return if !$this->createTable($table);
	}


	# we need the first field name, or if it is an auto-increment
	# primary id key, the second field field name, to trigger the
	# creation of a new record. field names are expected to be lc.

	my $first_field = $table_def->[0]->{auto_increment} ?
		$table_def->[1]->{name} : $table_def->[0]->{name};
	display($dbg_import,1,"first_field=$first_field");

	if (!open(IFILE,"<$text_file"))
	{
		error("Could not open $text_file for reading");
		return;
	}

	my $rec;
	my $line;
	my $num = 0;
	my $SHOW_EVERY = 100;
	display($dbg_import,0,"Processing text file $text_file");

	while (defined($line = <IFILE>))
	{
		my ($lval,$rval) = generic_lr_value($line);
		next if !$lval;

		if ($lval eq $first_field)
		{
			if ($rec)
			{
				display($dbg_import,1,"Inserting record($num)")
					if !$SHOW_EVERY || ($num % $SHOW_EVERY == 0);
				if (!$this->insert_record($table,$rec))
				{
					error("Could not insert record($num) into table($table) first_field=$first_field  value=$rec->{$first_field}: $this->{errstr}");
					close IFILE;
					return;
				}
			}

			$num++;
			$rec = {};
			# $rec = $this->init_empty_rec($table);
				# not strictly needed anymore, could just be {}
			display($dbg_import+1,1,"NEW RECORD $table($rval)");
		}

		display($dbg_import+2,2,"$lval=$rval");
		$rec->{$lval} = $rval;
	}

	close IFILE;

	if ($rec)
	{
		display($dbg_import,1,"Inserting last record($num)");
		if (!$this->insert_record($table,$rec))
		{
			error("Could not insert record($num) into table($table) first_field=$first_field value=$rec->{$first_field}: $this->{errstr}");
			return;
		}
	}

	LOG(0,"importTableTextFile($table) inserted $num records");
	return 1;
}




sub exportTableTextFile
	# export a text file sorted by the first usable field
{
    my ($this,$table,$text_file,$order_by) = @_;
	$order_by ||= '';
	LOG(0,"exportTableTextFile($table,$text_file,$order_by)");

	# get the 'processed' field definitions for
	# use in generating the text file. This is an
	# array of records extracted from my definitions:
	#
	#       name => $name,
    #       type => $type,
	#       width => $width,
    #       auto_increment

	my $table_def = $this->getFieldDefsArray($table);
	if (!$table_def)
	{
		error("Could not find table definition for $table");
		return;
	}

	my $first_field = $table_def->[0]->{name};
	$order_by ||= $first_field;

	# create and execute the query

	my $sth = $this->execute("SELECT * FROM $table ORDER BY $order_by");
    return if !$sth;

	# open the output file

	if (!open(OFILE,">$text_file"))
	{
        $sth->finish();
		error("Could not open $text_file for writing");
		return;
	}

	my $num = 0;
	my $SHOW_EVERY = 100;
	while (my $rec = $sth->fetchrow_hashref())
    {
		display($dbg_export,1,"dumping record($num)")
			if !$SHOW_EVERY || ($num % $SHOW_EVERY == 0);

		print OFILE "\n";
		for my $def (@$table_def)
		{
			next if $def->{auto_increment};
			my $field_name = $def->{name};
			my $val = $rec->{$field_name};
			if (!defined($val))
			{
				$val = '';
				$val = 0 if $def->{type} =~ /FLOAT|INTEGER/;
			}
			print OFILE uc($field_name)."=$val\n";
		}
		$num++;
	}
	$sth->finish();
	print OFILE "\n";
	close OFILE;
	LOG(0,"exportTableTextFile($table) wrote $num records)");
	return 1;
}



1;
