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

our $dbg_commands:shared = -1;
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
        $PROTOCOL_PUT
		$PROTOCOL_FILE
	    $PROTOCOL_BASE64
	    $PROTOCOL_CONTINUE
	    $PROTOCOL_OK

		recurseFxn

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
our $PROTOCOL_PUT		= "PUT";
our $PROTOCOL_FILE		= "FILE";
our $PROTOCOL_BASE64	= "BASE64";
our $PROTOCOL_CONTINUE  = "CONTINUE";
our $PROTOCOL_OK        = "OK";




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

    my $dir_info = Pub::FS::FileInfo->new(1,$dir);
    return $dir_info if !isValidInfo($dir_info);
	return error("dir($dir) is not a directory in $this->{NAME} _list",0,1)
		if !$dir_info->{is_dir};
	return error("$this->{NAME} could not opendir $dir",0,1)
		if !opendir(DIR,$dir);

    while (my $entry=readdir(DIR))
    {
        next if ($entry =~ /^(\.|\.\.)$/);
        my $path = makePath($dir,$entry);
        display($dbg_commands+1,1,"entry=$entry");
		my $is_dir = -d $path ? 1 : 0;

		my $info = Pub::FS::FileInfo->new($is_dir,$dir,$entry);
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
    my $path = makePath($dir,$subdir);
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
    my $path1 = makePath($dir,$name1);
    my $path2 = makePath($dir,$name2);

	my $is_dir = -d $path1;

	return error("$this->{NAME} file/dir $path1 not found") if !(-e $path1);
	return error("$this->{NAME} file/dir $path2 already exists") if -e $path2;
	return error("$this->{NAME} Could not rename $path1 to $path2")
		if !rename($path1,$path2);
	return Pub::FS::FileInfo->new($is_dir,$dir,$name2);
}


sub deleteCallback
{
	my ($this,
		$is_dir,
		$dir,
		$entry,
		$target_dir,		# unused for _delete
		$progress) = @_;	# unused for _delete

	if ($is_dir)
	{
		return error("$this->{NAME} Could not delete local dir $dir",0,1)
			if !rmdir($dir);
	}
	else
	{
		my $path = makePath($dir,$entry);
		return error("$this->{NAME} Could not delete local file $path",0,1)
			if !unlink($path);
	}
	return '';
}




sub _delete
{
	my ($this,
		$dir,
		$entries,
		$progress) = @_;

	display($dbg_commands,0,"$this->{NAME} _delete($dir,$entries)");

	my $rslt;
	if (!ref($entries))
	{
		$rslt = $this->deleteCallback(1,$dir,$entries,'',$progress);
	}
	else
	{
		my $rslt = $this->recurseFxn(
			'_delete',
			\&deleteCallback,
			$dir,
			$entries,
			'',					# unused target_dir for DELETE
			$progress);
	}

	$rslt ||= $this->_list($dir);
	return $rslt;
}


#------------------------------------------------------
#  _file(), and _base64()
#------------------------------------------------------


sub abortFile
{
	my ($this) = @_;
	display($dbg_commands,0,"$this->{NAME} abortFile($this->{file_name})");

	$this->{file_handle}->close()
		if $this->{file_handle};
	unlink $this->{file_temp_name}
		if $this->{file_temp_name} && -f $this->{file_temp_name};

	$this->{file_handle} = '';
	$this->{file_size}   = '';
	$this->{file_ts} 	 = '';
	$this->{file_name} 	 = '';
	$this->{file_temp_name} = '';
	$this->{file_offset} = 0;
}


sub finishFile
{
	my ($this) = @_;
	display($dbg_commands,0,"$this->{NAME} finishFile($this->{file_name})");

	my $rslt = '';
	my $use_name = $this->{file_temp_name} || $this->{file_name};

	if (!$this->{file_handle}->close())
	{
		$this->{file_handle} = '';
		$rslt = error("$this->{NAME} finishFile() Could not close($use_name)");
	}
	if ($this->{file_temp_name})
	{
		if (-f $this->{file_name} && !unlink $this->{file_name})
		{
			$rslt = error("$this->{NAME} finishFile() Could not unlink old($this->{file_name}");
		}
		elsif (!rename($this->{temp_file_name},$this->{file_name}))
		{
			$rslt = error("$this->{NAME} finishFile() Could not unlink rename($this->{temp_file_name},$this->{file_name})");
		}
	}

	if (!$rslt && $this->{file_ts} && !setTimestamp($this->{file_name},$this->{file_ts}))
	{
		$rslt = error("$this->{NAME} finishFile() Could not setTimestamp($this->{file_name},$this->{file_ts})");
	}

	$this->abortFile() if $rslt;
	$rslt ||= $PROTOCOL_OK;
	return $rslt;
}



sub _file
	# it is not clear what this $progres parameter means
{
	my ($this,
		$size,
		$ts,
		$full_name,
		$progress) = @_;

	display($dbg_commands,0,"$this->{NAME} _file($size,$ts,$full_name)");
	my $free = diskFree();

	return error("$this->{NAME} _file Attempt to overwrite directory($full_name) with file!")
		if -d $full_name;
	return error("$this->{NAME} _file File($full_name) too big($size) for disk($free)")
		if $size > $free;
	return error("$this->{NAME} _file Could not make subdirectories($full_name)")
		if !my_mkdir($full_name,1,$dbg_commands);

	my $pid = $$;
	my $tid = threads->tid();
	my $temp_name = '';
	my $use_name = $full_name;
	if (-f $full_name)
	{
		$temp_name = "$full_name.$tid.$pid";
		$use_name = $temp_name;
	}

	my $fh = open ">$use_name";
	return error("$this->{NAME} _file Could not open '$use_name' for output")
		if !$fh;
	binmode $fh;

	$this->{file_handle} = $fh;
	$this->{file_size} = $size;
	$this->{file_ts} = $ts;
	$this->{file_name} = $full_name;
	$this->{file_temp_name} = $temp_name;
	$this->{file_offset} = 0;

	return $this->finishFile() if !$size;
	return $PROTOCOL_CONTINUE;
}



sub _base64
	# it is not clear what this $progres parameter means
{
	my ($this,
		$offset,
		$bytes,
		$content,
		$progress) = @_;

	my $rslt = '';
	my $ok = $PROTOCOL_CONTINUE;

	my $len = length($content);
	display($dbg_commands,0,"$this->{NAME} _base64($offset,$bytes,$len encoded_bytes)");

	if ($offset != $this->{file_offset})
	{
		$rslt = error("$this->{NAME} _base64 Unexpected offset($offset) for =($this->{file_name}) expected($this->{file_offset}")
	}
	elsif ($offset + $bytes > $this->{file_size})
	{
		$rslt = error("$this->{NAME} _base64 Bad parameters offset($offset) + bytes($bytes) > size($this->{size}");
	}
	else
	{
		my $data = decode64($content);
		$len = length($data);
		display($dbg_commands+1,1,"$this->{NAME} _base64 got $len decoded_bytes)");

		if ($len != $bytes + 4)
		{
			$rslt = error("$this->{NAME} _base64 Incorrect decoded byte length(".($len-4).") expected $bytes");
		}
		else
		{
			my $cs_bytes = substr($data,$len-4);
			$data = substr($data,0,$len-4);
			$len = length($data);

			# MSB first

			my $got_cs =
				ord(substr($cs_bytes,0,1)) << 24 +
				ord(substr($cs_bytes,1,1)) << 16 +
				ord(substr($cs_bytes,2,1)) << 8 +
				ord(substr($cs_bytes,3,1));

			my $calc_cs = 0;
			for (my $i=0; $i<$len; $i++)
			{
				$calc_cs += ord(substr($data,$i,1));
			}
			$calc_cs &= 0xFFFFFFFF;
			display($dbg_commands+1,1,"$this->{NAME} got_cs($got_cs) calc_cs($calc_cs)");

			if ($got_cs != $calc_cs)
			{
				$rslt = error("$this->{NAME} _base64 incorrect checksum got_cs($got_cs) calc_cs($calc_cs)");
			}
			else
			{
				my $wrote = syswrite($this->{file_handle}, $data, $bytes, $offset);
				$rslt = error("$this->{NAME} _base64 bad write($wrote) expected($bytes)")
					if $wrote != $bytes;
				$this->{file_offset} += $bytes;

				updateBytes

				$ok = $this->finishFile()
					if $this->{file_offset} == $this->{size};
			}
		}
	}

	if ($rslt)
	{
		$this->abortFile();
		return $rslt;
	}
}



#-----------------------------------------------------
# _put
#-----------------------------------------------------

sub putCallback
{
	my ($this,
		$is_dir,
		$dir,
		$entry,
		$target_dir,
		$progress) = @_;

	display($dbg_commands,0,"$this->{NAME} putCallback($is_dir,$dir,$entry,$target_dir)");
		#,".ref($progress).")");

	return '';
}



sub _put
{
	my ($this,
		$dir,
		$entries,		# ref() or single_file_name
		$target_dir,
		$progress,
		$other_session) = @_;

	display($dbg_commands,0,"$this->{NAME} _put($dir,$entries,$target_dir)");
		# ,".ref($progress).",".ref($other_session).")");

	my $rslt;
	if (!ref($entries))
	{
		$rslt = $this->putCallback(0,$dir,$entries,$target_dir,$progress);
	}
	else
	{
		$rslt = $this->recurseFxn(
			'_put',
			\&putCallback,
			$dir,
			$entries,
			$target_dir,
			$progress);
	}

	# note that we do not pass $progress to the other session

	$rslt ||= $other_session->doCommand($PROTOCOL_LIST,$target_dir,'','','','','');
	return $rslt;

}



#-------------------------------------------------------
# recurseFxn
#-------------------------------------------------------

sub recurseFxn
{
	my ($this,
		$command,
		$callback,
		$dir,				# MUST BE FULLY QUALIFIED
		$entries,
		$target_dir,		# unused for DELETE
		$progress,
		$level) = @_;

	$level ||= 0;

	display($dbg_commands,0,"$this->{NAME} $command($dir,$level)");

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
			my $dir_path = makePath($dir,$entry);
			my $dir_entries = $entry_info->{entries};

			return error("$command($level) could not opendir($dir_path)")
				if !opendir(DIR,$dir_path);
			while (my $dir_entry=readdir(DIR))
			{
				next if ($dir_entry =~ /^(\.|\.\.)$/);
				display($dbg_commands+2,1,"dir_entry=$dir_entry");
				my $sub_path = makePath($dir_path,$dir_entry);
				my $is_dir = -d $sub_path ? 1 : 0;

				my $info = Pub::FS::FileInfo->new($is_dir,$dir_path,$dir_entry);
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

	if (scalar(keys %$subdirs) || scalar(keys %$files))
	{
		return $PROTOCOL_ABORTED if $progress &&
			!$progress->addDirsAndFiles(
				scalar(keys %$subdirs),
				scalar(keys %$files));
	}

	#-------------------------------------------
	# depth first recurse thru subdirs
	#-------------------------------------------

	for my $entry  (sort {uc($a) cmp uc($b)} keys %$subdirs)
	{
		my $info = $subdirs->{$entry};
		my $err = $this->recurseFxn(
			$command,
			$callback,
			makePath($dir,$entry),			# growing dir
			$info->{entries},				# child entries
			makePath($target_dir,$entry),	# growing target_dir
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
		my $path = makePath($dir,$entry);
		return $PROTOCOL_ABORTED if $progress && $progress->aborted();
		return $PROTOCOL_ABORTED if $progress && !$progress->setEntry($path);

		display($dbg_commands,1,"$this->{NAME} $command local file: $path");
		my $err = &$callback($this,0,$dir,$target_dir,$entry,$progress);
		return $err if $err;

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
		my $err = &$callback($this,1,$dir,$target_dir,$progress);
		return $err if $err;

		return $PROTOCOL_ABORTED if $progress && !$progress->setDone(1);

	}

	return '';
}


#------------------------------------------------------
# doCommand
#------------------------------------------------------
# $caller is usually undef and unused by local Seesion
# $other_session is the destination session, if available,
# for PUTs

sub doCommand
{
    my ($this,
		$command,
        $param1,
        $param2,
        $param3,
		$progress,
		$caller,
		$other_session) = @_;

	display($dbg_commands+1,0,"$this->{NAME} doCommand($command,$param1,$param2,$param3)");
		# ,".ref($progress).",$caller,".ref($other_session).")");

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

	# for DELETE and PUT a single filename name or list of entries

	elsif ($command eq $PROTOCOL_DELETE)			# $dir, $entries_or_filename, undef, $progress
	{
		$rslt = $this->_delete($param1,$param2,$progress);
	}
	elsif ($command eq $PROTOCOL_PUT)			# $dir, $target_dir, $entries_or_filename, $progress
	{
		$rslt = $this->_put($param1, $param2, $param3, $progress, $other_session);
	}

	# File handling protocols

	elsif ($command eq $PROTOCOL_FILE)			# $size, $ts, $fully_qualified_local_filename $progress
	{
		$rslt = $this->_file($param1, $param2, $param3, $progress);
	}
	elsif ($command eq $PROTOCOL_BASE64)		# $offset, $bytes, ENCODED_CONTENT $progress
	{
		$rslt = $this->_base64($param1, $param2, $param3, $progress);
	}


	# error for unsupported commands

	else
	{
		$rslt = error("$this->{NAME} unsupported command: $command",0,1);
	}

	# finished, error have already been reported ?!?!

	$rslt ||= error("$this->{NAME} unexpected empty doCommand() rslt",0,1);

	# RETURN_ERRORS == 0 for the base Session as used by the
	# Pane, as it reports errors in realtime, and expects a
	# blank or a FileInfo.  Other Session expects a file_info
	# or an error.

	if (!isValidInfo($rslt) && $rslt ne $PROTOCOL_ABORTED)
	{
		if ($this->{RETURN_ERRORS})
		{
			$rslt = $PROTOCOL_ERROR.$rslt;
		}
		else
		{
			$rslt = ''
		}
	}

	display($dbg_commands+1,0,"$this->{NAME} doCommand($command) returning $rslt");
	return $rslt;

}	# Session::doCommand()


1;
