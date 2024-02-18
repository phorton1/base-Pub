#!/usr/bin/perl
#--------------------------------------------------------
# Generic Database Import Export
#-------------------------------------------------------
# The database is created else where
# Export writes a series of insert statements.
#   400 records at a time.
# Import executes them.

package Pub::Database;	# continued
use strict;
use warnings;
use DBI;
use Archive::Zip;
use Pub::Utils;


our $dbg_export = 0;

our $NUM_PER_INSERT = 400;
	# how many records in a chunk
our $DBG_SHOW_EVERY = 100000;
	# how often to show record insert debugging

sub exportTableRecords
	# cannot fail
	# works with a list of records from the given table
{
	my ($this,$ofile,$table,$recs) = @_;

	my $num_recs = @$recs;

	LOG(0,"exportTableRecords($table) num_recs=$num_recs");
	print $ofile "\n\n";
	print $ofile ";\n";
	print $ofile "; TABLE $table($num_recs)\n";
	print $ofile ";\n";

	if (!$num_recs)
	{
		warning(0,1,"No records passed for $table ... returning 1!!");
		return 1;
	}

	my @fields = $this->getFieldNames($table);
    my $types = $this->getFieldStorageTypes($table);

	# using alternate approach to identifying and
	# NOT exporting the auto-increment ID field

	shift @fields if $fields[0] eq 'id';

	my $num = 0;
	my $num_this = 0;
	my $log_mod =
		$num_recs > 400000 ? 40000 :
		$num_recs > 40000 ? 4000 :
		400;

	for my $rec (@$recs)
    {
        if ($num % $NUM_PER_INSERT == 0)
        {
			if ($num % $log_mod == 0)
			{
				display(0,1,"record($num/$num_recs)");
			}
			print $ofile ";\n" if $num_this;
			print $ofile "\n";
			print $ofile "INSERT INTO $table (".join(",",@fields).") VALUES";
			$num_this = 0;
        }

        my $values = "";
        for my $field (@fields)
        {
            my $value = $rec->{$field};
			if ($types->{$field} eq 'STRING')
			{
	            $value = '' if !defined($value);
				$value =~ s/'/''/g;
	            $value = "'$value'";
			}
			else
			{
	            $value = '0' if !defined($value) || $value eq '';
			}
            $values .= "," if length($values);
            $values .= $value;
        }

		print $ofile "," if $num_this;
		print $ofile "\n";
		print $ofile "($values)";

		$num++;
		$num_this++;
    }

	print $ofile ";\n" if $num_this;
	print $ofile "\n";

	LOG(1,"finished exporting $table");
	return 1;
}


#------------------------------------
# export
#------------------------------------

sub exportTable
	# works with huge tables a record at a time.
{
	my ($this,$ofile,$table) = @_;

	my $count = $this->get_record("SELECT count(*) AS count FROM $table");
	my $num_recs = $count ? $count->{count} : 0;

	return if !LOG(0,"exportTable($table) num_recs=$num_recs");
		# detect $client handle going offline in cmServcice

	print $ofile "\n\n";
	print $ofile ";\n";
	print $ofile "; TABLE $table($num_recs)\n";
	print $ofile ";\n";

	if (!$num_recs)
	{
		warning(0,1,"No records found in $table ... continuing!!");
		# return 1;
	}

	my $dbh = $this->{dbh};
	my $query = "SELECT * FROM $table";
    my $sth = $dbh->prepare($query);
    if (!$sth)
    {
        error("Could not prepare query($query): $DBI::errstr");
        return;
    }
    if (!$sth->execute())
    {
        $sth->finish();
        error("Cannot execute query($query): $DBI::errstr");
        return;
    }

	my @fields = $this->getFieldNames($table);
    my $types = $this->getFieldStorageTypes($table);

	# using alternate approach to identifying and
	# NOT exporting the auto-increment ID field

	shift @fields if $fields[0] eq 'id';

	my $num = 0;
	my $num_this = 0;
	my $log_mod =
		$num_recs > 400000 ? 40000 :
		$num_recs > 40000 ? 4000 :
		400;

	while (my $rec = $sth->fetchrow_hashref())
    {
        if ($num % $NUM_PER_INSERT == 0)
        {
			if ($num % $log_mod == 0)
			{
				if (!display(0,1,"record($num/$num_recs)"))
					# detect $client handle going offline in cmServcice
				{
			        $sth->finish();
					return;
				}
			}

			print $ofile ";\n" if $num_this;
			print $ofile "\n";
			print $ofile "INSERT INTO $table (".join(",",@fields).") VALUES";
			$num_this = 0;
        }

        my $values = "";
		my $debug_field = '';
		my $debug_value = '';

        for my $field (@fields)
        {
            my $value = $rec->{$field};

			if (!$debug_field)
			{
				$debug_field = $field;
				$debug_value = $value;
			}

			if ($types->{$field} eq 'STRING')
			{
	            $value = '' if !defined($value);

				# 2023-07-12 - THE RE WAS WRONG AND MESSED UP EXPORT OF BAGS starting on last build!
				# 	 I had not built and tested this before.  The RE was [0x00-0x1f] and
				# 	 should have been [\x00-\x1f].  So, starting with the build, backups stopped
				# 	 working (v833).  Tested and built a new one with v834.  I am debating whether
				#    to leave this line, or remove it.  If it works it is safer than not having it.
				# 2023-04-15 - found guia 1054135815 with several carriage returns in the description
				#    at first it looked like it came from ebox, but that was not the case.  Maybe the android stuff?
				#    I fixed the database record, but still not sure where it came from
				#    This untested line of code is intended to remove them from backups them jic.

				my $old_value = $value;
				if ($value =~ s/[\x00-\x1f]|\xff//g)
				{
					warning(0,0,"REMOVED ILLEGAL CHARS in backup $table $debug_field($debug_value): $field='$value' bytes=".bad_bytes($old_value));
				}


				$value =~ s/'/''/g;
	            $value = "'$value'";
			}
			else
			{
	            $value = '0' if !defined($value) || $value eq '';
			}
            $values .= "," if length($values);
            $values .= $value;
        }

		print $ofile "," if $num_this;
		print $ofile "\n";
		print $ofile "($values)";

		$num++;
		$num_this++;
    }

	print $ofile ";\n" if $num_this;
	print $ofile "\n";

    if ($DBI::err)
    {
        error("fetching query($query)");
	    $sth->finish();
		return;
    }

	my $rslt = LOG(1,"finished exporting $table");
		# detect $client handle going offline in cmServcice

    $sth->finish();
	return $rslt;
}



sub exportDatabaseText
	# Export the entire database to a
	# fully qualified text file.
{
	my ($this,$ofilename,$progress) = @_;
	my $defs = $this->{database_def};
	return if !LOG(0,"EXPORT_DATABASE_TEXT to $ofilename");
		# detect $client handle going offline in cmServcice

	my $ofile;
	if (!open($ofile,">$ofilename"))
	{
		error("Could not open $ofilename for writing");
		return;
	}
	for my $table (sort(keys(%$defs)))
	{
		$progress->update(1,"table($table)") if $progress;
		if (!LOG(0,"EXPORT TABLE($table)"))
		{
			# detect $client handle going offline in cmServcice
			close $ofile;
			return;
		}
		if (!$this->tableExists($table))
		{
			warning(0,0,"SKIPPING NON-EXISTING TABLE($table)");
		}
		elsif (!$this->exportTable($ofile,$table))
		{
			close $ofile;
			return;
		}
	}
	close $ofile;
	return LOG(0,"EXPORT_DATABASE_TEXT($ofilename) finished");
}





sub exportDatabaseZip
	# Export the database to a zip file.
	# Uses, and erases, a text file intermediate
{
	my ($this,$zip_filename,$progress) = @_;
		# $progress will have #tables plus 2 ticks

	return if !LOG(0,"EXPORT_DATABASE_ZIP to $zip_filename");

	# create the text file intermediate file name from
	# the fully qualified zip file_name passed in.

	my $text_filename = $zip_filename;
	if ($text_filename !~ s/\.zip$/.txt/)
	{
		error("exportDatabaseZip($zip_filename) must be a zip filename");
		return;
	}
	my $text_root = $text_filename;
	$text_root =~ s/.*\///;

	# try to make the directory if it does not exist

	return if !my_mkdir($zip_filename,1);

	# export the database
	# return undef if any errors (reported)

	if (!$this->exportDatabaseText($text_filename,$progress))
	{
		return;
	}

	# Create the zip file

	$progress->update(1,'zipping ...') if $progress;
	return if !LOG(1,"creating ZIP_FILE for text_root($text_root) ...");

	my $zip = Archive::Zip->new();
	my $zipfile = $zip->addFile($text_filename,$text_root);
	$zipfile->desiredCompressionLevel( 9 );

	$progress->update(1,'writing ...') if $progress;
	return if !LOG(1,"writing ZIP_FILE ...");
	my $non_zero_is_bad = $zip->writeToFileNamed( $zip_filename );
	if ($non_zero_is_bad)
	{
		error("Could not write zip file $zip_filename");
		return;
	}

	# get rid of the temporary database text file

	return if !LOG(1,"unlinking DATA_FILE($text_filename)");
	unlink($text_filename);

	# finished

	return LOG(0,"EXPORT_DATABASE_ZIP($zip_filename) finished");
}






#------------------------------------
# import
#------------------------------------

sub importDatabase
{
	my ($this,$ifilename,$progress) = @_;
		# the progress will have num_tables ticks

	LOG(0,"IMPORT_DATABASE($this->{database}) from $ifilename");
	my $ifile;
	if (!open($ifile,"<$ifilename"))
	{
		error("Could not open $ifilename for reading");
		return;
	}

	my $line;
	my $query = '';
	my $table = '';
	my $num_recs = 0;
	my $num_done = 0;
	my $num_this = 0;

	while (defined($line=<$ifile>))
	{
		$line =~ s/\s*$//;
		$line =~ s/^\s$//;

		# a blank line triggers any existing query

		if ($query ne '' && $line eq '')
		{
			my $log_mod =
				$num_recs > 400000 ? 40000 :
				$num_recs > 40000 ? 4000 :
				400;

			# 2023-04-17 - this tested chunk of code is ok to build.
			# I am leaving it on my machine to help me identify problems.

			if ($num_this != 400 && $num_this != $num_recs - $num_done)
			{
				warning(0,0,"bad number of records ($num_this) records $table($num_done/$num_recs)");
				LOG(0,"\n=======================\n$query\n====================\n");
				$num_this = 400;
			}
			if (($num_done % $log_mod) == 0)
			{
				my $msg = "insert $table($num_done/$num_recs)";
				LOG(2,$msg);
			}

			# display(0,3,"query=$query");

			if (!$this->do($query))
			{
				close $ifile;

				# 2023-04-17 - as as leaving this added error message (which was never hit)
				error("Could not insert($num_this) records into $table($num_done/$num_recs)");
				return;
			}
			$num_done += $num_this;
			$num_this = 0;
			$query = '';
		}

		# insert start the query which then adds till blank line

		if ($line =~ /^INSERT/)
		{
			#------------------------------------------
			# add the line to the insert statement
			#------------------------------------------

			$query = $line."\n";
		}
		elsif ($query ne '' && $line ne '')
		{
			$query .= $line."\n";
			$num_this++;
		}

		# show the comment for progress indicator
		# ; TABLE bags(198)

		if ($line =~ /; TABLE (\w*)\((\d+)\)/)
		{
			$table = $1;
			$num_recs = $2;
			$num_done = 0;
			$num_this = 0;
			$progress->update(1,"table($table)") if $progress;
			LOG(1,"TABLE($table) numrecs=$num_recs");
		}
		# ; TABLE $table(numrecs) for debugging

	}	# while $line

	close $ifile;
	LOG(0,"IMPORT_DATABASE($this->{database}) finished");
	return 1;

}




1;
