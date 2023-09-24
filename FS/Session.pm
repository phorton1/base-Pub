#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::Session
#-------------------------------------------------------
# Base Class Session.
#
# The base Session is purely local and has no SOCK.
#
# The doCommand() method returns FS::FileInfo objects
# or reports an error() and returns ''.

package Pub::FS::Session;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::FS::FileInfo;
use Time::HiRes qw( sleep  );
use Pub::Utils;
use Pub::FS::FileInfo;


my $TEST_DELAY = 0;
 	# delay local operatios to test progress stuff
 	# set this to 1 or 2 seconds to slow things down for testing

our $dbg_commands:shared = -2;
	# 0 = show atomic commands
	# -1 = show command header and return results
	# -2 = show recursive operation details
	# -3 = show gruesome recursive details


BEGIN {
    use Exporter qw( import );
	our @EXPORT = qw (
		$dbg_commands

		$PROTOCOL_HELLO
        $PROTOCOL_WASSUP
        $PROTOCOL_EXIT
        $PROTOCOL_ENABLE
        $PROTOCOL_DISABLE
        $PROTOCOL_ERROR
        $PROTOCOL_LIST
        $PROTOCOL_RENAME
        $PROTOCOL_MKDIR
        $PROTOCOL_ABORT
		$PROTOCOL_ABORTED
        $PROTOCOL_PROGRESS
        $PROTOCOL_DELETE
        $PROTOCOL_XFER
		$PROTOCOL_GET
	    $PROTOCOL_PUT
	    $PROTOCOL_CONTINUE
	    $PROTOCOL_BASE64

	);
}

# Protocol Verbs

our $PROTOCOL_HELLO		= "HELLO";
our $PROTOCOL_WASSUP 	= "WASSUP";
our $PROTOCOL_EXIT		= "EXIT";
our $PROTOCOL_ENABLE    = "ENABLED - ";
our $PROTOCOL_DISABLE   = "DISABLED - ";
our $PROTOCOL_ERROR     = "ERROR - ";
our $PROTOCOL_LIST 		= "LIST";
our $PROTOCOL_RENAME 	= "RENAME";
our $PROTOCOL_MKDIR 	= "MKDIR";
our $PROTOCOL_ABORT     = "ABORT";
our $PROTOCOL_ABORTED   = "ABORTED";
our $PROTOCOL_PROGRESS  = "PROGRESS";
our $PROTOCOL_DELETE 	= "DELETE";
our $PROTOCOL_XFER 		= "XFER";
our $PROTOCOL_GET       = "GET";
our $PROTOCOL_PUT		= "PUT";
our $PROTOCOL_CONTINUE  = "CONTINUE";
our $PROTOCOL_BASE64	= "BASE64";



#------------------------------------------------
# lifecycle
#------------------------------------------------

sub new
{
	my ($class, $params, $no_error) = @_;
	$params ||= {};
	$params->{NAME} ||= 'Session';
	$params->{RETURN_ERRORS}  ||= 0;
	my $this = { %$params };
	bless $this,$class;
	return $this;
}


#------------------------------------------------------
# local atomic commands
#------------------------------------------------------
# return a valid FileInfo directory objects or a
# text error(with call_level 0, and suppress_show)

sub _list
	# $dir must be fully qualified
{
    my ($this, $dir) = @_;
    display($dbg_commands,0,"$this->{NAME} _list($dir)");

    my $dir_info = Pub::FS::FileInfo->new($this,1,$dir);
    return $dir_info if !isValidInfo($dir_info);
	return error("dir($dir) is not a directory in $this->{NAME} _list",0,1)
		if !$dir_info->{is_dir};
	return error("$this->{NAME} could not opendir $dir",0,1)
		if !opendir(DIR,$dir);

    while (my $entry=readdir(DIR))
    {
        next if ($entry =~ /^(\.|\.\.)$/);
        my $path = makepath($dir,$entry);
        display($dbg_commands+1,1,"entry=$entry");
		my $is_dir = -d $path ? 1 : 0;

		my $info = Pub::FS::FileInfo->new($this,$is_dir,$dir,$entry);
		if (!isValidInfo($info))
		{
			closedir DIR;
			return $info;
		}
		$dir_info->{entries}->{$entry} = $info;
	}

    closedir DIR;
    return $dir_info;
}


sub _mkdir
	# $dir must be fully qualified
{
    my ($this, $dir, $subdir) = @_;
    display($dbg_commands,0,"$this->{NAME} _mkdir($dir)");
    my $path = makepath($dir,$subdir);
	return error("Could not _mkdir $path",0,1)
		if !mkdir($path);
	return $this->_list($dir);
}


sub _rename
	# $dir must be fully qualified
	# returns a partially qualified new FileInfo
{
    my ($this, $dir, $name1, $name2) = @_;
    display($dbg_commands,0,"$this->{NAME} _renameLocal($dir,$name1,$name2)");
    my $path1 = makepath($dir,$name1);
    my $path2 = makepath($dir,$name2);

	my $is_dir = -d $path1;

	return error("$this->{NAME} file/dir $path1 not found") if !(-e $path1);
	return error("$this->{NAME} file/dir $path2 already exists") if -e $path2;
	return error("$this->{NAME} Could not rename $path1 to $path2")
		if !rename($path1,$path2);
	return Pub::FS::FileInfo->new($this,$is_dir,$dir,$name2);
}


sub _delete			# RECURSES!!
	# returns a valid fileInfo directory listing on success
	# or a text error on failure
{
	my ($this,
		$dir,				# MUST BE FULLY QUALIFIED
		$entries,
		$progress,
		$level) = @_;

	$level ||= 0;
	display($dbg_commands,0,"$this->{NAME} _delete($dir,$level)");

    return $PROTOCOL_ABORTED if $progress && $progress->aborted();
	sleep($TEST_DELAY) if $TEST_DELAY;

	#----------------------------------------------------
	# scan directory of any dir entries
	#----------------------------------------------------
	# adding their child entries, and pushing them on @subdirs
	# otherwise, push file entries onto @files

	my $files = {};
	my $subdirs = {};

	for my $entry  (sort {uc($a) cmp uc($b)} keys %$entries)
	{
		my $entry_info = $entries->{$entry};
		display($dbg_commands+3,1,"entry=$entry is_dir=$entry_info->{is_dir}");
		if ($entry_info->{is_dir})
		{
			my $dir_path = makepath($dir,$entry);
			my $dir_entries = $entry_info->{entries};

			return error("_deleteLocal($level) could not opendir($dir_path)")
				if !opendir(DIR,$dir_path);
			while (my $dir_entry=readdir(DIR))
			{
				next if ($dir_entry =~ /^(\.|\.\.)$/);
				display($dbg_commands+2,1,"dir_entry=$dir_entry");
				my $sub_path = makepath($dir_path,$dir_entry);
				my $is_dir = -d $sub_path ? 1 : 0;

				my $info = Pub::FS::FileInfo->new($this,$is_dir,$dir_path,$dir_entry);
					# FileInfo->new() always returns something
				if (!isValidInfo($info))
				{
					closedir DIR;
					return $info;
				}
				$dir_entries->{$dir_entry} = $info;
			}

			closedir DIR;
			$subdirs->{$entry} = $entry_info;
		}
		else
		{
			$files->{$entry} = $entry_info;
		}
	}

	return $PROTOCOL_ABORTED if
		(scalar(keys %$subdirs) || scalar(keys %$files)) &&
		$progress &&
		!$progress->addDirsAndFiles(
			scalar(keys %$subdirs),
			scalar(keys %$files));

	#-------------------------------------------
	# depth first recurse thru subdirs
	#-------------------------------------------

	for my $entry  (sort {uc($a) cmp uc($b)} keys %$subdirs)
	{
		my $info = $subdirs->{$entry};
		my $err = $this->_delete(
			makepath($dir,$entry),			# dir
			$info->{entries},				# dir_info
			$progress,
			$level + 1);
		return $err if $err;
	}

	#-------------------------------------------
	# iterate the flat files in the directory
	#-------------------------------------------

	for my $entry (sort {uc($a) cmp uc($b)} keys %$files)
	{
		sleep($TEST_DELAY) if $TEST_DELAY;
		my $info = $files->{$entry};
		my $path = makepath($dir,$entry);
		return $PROTOCOL_ABORTED if $progress && $progress->aborted();
		return $PROTOCOL_ABORTED if $progress && !$progress->setEntry($path);

		display($dbg_commands,-5-$level,"$this->{NAME} DELETE local file: $path");
		return error("$this->{WHO} Could not delete local file $path",0,1)
			if !unlink($path);

		return $PROTOCOL_ABORTED if $progress && !$progress->setDone(0);
	}


	#----------------------------------------------
	# finally, delete the dir itself at level>0
	#----------------------------------------------
	# recursions return 1 upon success

	if ($level)
	{
		sleep($TEST_DELAY) if $TEST_DELAY;
		return $PROTOCOL_ABORTED if $progress && $progress->aborted();
		return $PROTOCOL_ABORTED if $progress && !$progress->setEntry($dir);

		display($dbg_commands,1,"$this->{NAME} DELETE local dir: $dir");
		return error("$this->{WHO} Could not delete local file $dir",0,1)
			if !rmdir($dir);

		return $PROTOCOL_ABORTED if $progress && !$progress->setDone(1);

	}

	# level 0 returns a directory listing on success

	return $this->_list($dir) if !$level;
	return '';
}



#------------------------------------------------------
# doCommand
#------------------------------------------------------

sub doCommand
{
    my ($this,
		$command,
        $param1,
        $param2,
        $param3,
		$progress) = @_;

	$command ||= '';
	$param1 ||= '';
	$param2 ||= '';
	$param3 ||= '';
	$progress ||= '';

	display($dbg_commands+1,0,"$this->{NAME} doCommand($command,$param1,$param2,$param3) progress=$progress");

	# For these calls param1 MUST BE A FULLY QUALIFIED DIR

	my $rslt;
	if ($command eq $PROTOCOL_LIST)					# $dir
	{
		$rslt = $this->_list($param1);
	}
	elsif ($command eq $PROTOCOL_MKDIR)				# $dir, $subdir
	{
		$rslt = $this->_mkdir($param1,$param2);
	}
	elsif ($command eq $PROTOCOL_RENAME)			# $dir, $old_name, $new_name
	{
		$rslt = $this->_rename($param1,$param2,$param3);
	}

	# for delete, a single filename name or list of entries
	# may be passed in. A local single filename is handled specially.

	elsif ($command eq $PROTOCOL_DELETE)			# $dir, $entries_or_filename, undef, $progress
	{
		if (ref($param2))
		{
			$rslt = $this->_delete($param1,$param2,$progress);
		}
		else
		{
			my $path = "$param1/$param2";
			display($dbg_commands,0,"$this->{NAME} DELETE single local file: $path");
			$rslt = error("$this->{NAME} Could not delete single local file $path",0,1)
				if !unlink($path);
			$rslt ||= $this->_list($param1);
		}
	}

	# elsif ($command eq $PROTOCOL_XFER)			# $dir, $entries_or_filename, $target_dir, $progress
	# {
	# 		$rslt = $this->_xfer($param1,$param2,$param3,$progress);
	# }

	else
	{
		$rslt = error("$this->{NAME} unsupported command: $command",0,1);
	}

	# finished, error have already been reported ?!?!

	$rslt ||= error("$this->{NAME} unexpected empty doCommand() rslt",0,1);

	# RETURN_ERRORS = 0 for the base Session as used by the
	# Pane, as it reports errors in realtime, and expects a
	# blank or a FileInfo.  The ServerSession expects a file_info
	# the exact packet it can pass back to the Client.

	if (!isValidInfo($rslt))
	{
		if ($this->{RETURN_ERRORS})
		{
			$rslt = $PROTOCOL_ERROR.$rslt
				if $rslt ne $PROTOCOL_ABORTED;
		}
		else
		{
			$rslt = ''
		}
	}

	return $rslt;

}	# Session::doCommand()


1;
