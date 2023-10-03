#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::Session
#-------------------------------------------------------
# Base Class Session.
#
# The base Session is purely local and has no SOCK.
#
# The doCommand() method returns FS::FileInfo objects,
# an ERROR or one of the ABORT, ABORTED, CONTINUE, or OK
# messges.

package Pub::FS::Session;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::FS::FileInfo;
use Time::HiRes qw( sleep  );
use Pub::Utils;
use Pub::FS::FileInfo;

my $DECODED_BUF_SIZE = 10000;

my $TEST_DELAY = 0;
 	# delay local operatios to test progress stuff
 	# set this to 1 or 2 seconds to slow things down for testing

our $dbg_commands:shared = 0;
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

		show_params

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
	$params->{IS_BRIDGED} ||= 0;
	my $this = { %$params };
	$this->{SERVER_ID} = getMachineId();
	bless $this,$class;
	return $this;
}

sub MACHINE_ID
{
	my ($this) = @_;
	my $id = $this->{SERVER_ID};
	$id =~ s/.*\///;
	return $id;
}

sub sameMachineId
{
	my ($this,$other) = @_;
	my $id1 = $this->MACHINE_ID();
	my $id2 = $other ? $other->MACHINE_ID() : '';
	return 1 if $id1 && $id1 eq $id2;
	return 0;
}

# utility for displaying length of BASE64 packets in debugging

sub show_params
{
	my ($what,$command,$param1,$param2,$param3) = @_;

	$param1 ||= '';
	$param2 ||= '';
	$param3 ||= '';

	$param3 = length($param3)." encoded bytes"
		if $command eq $PROTOCOL_BASE64 && $param3 !~ /^$PROTOCOL_ERROR/;
	$param2 = ref($param2) if ref($param2);
	return "$what $command($param1,$param2,$param3)";
}


#------------------------------------------------------
# local atomic commands
#------------------------------------------------------

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
    my ($this, $path, $ts, $may_exist) = @_;
    $may_exist ||= 0;
	display($dbg_commands,0,"$this->{NAME} _mkdir($path,$ts,$may_exist)");
	if ($may_exist)
	{
		display($dbg_commands+1,1,"_mkdir(may_exist,$path) -d=".(-d $path ? 1 : 0));
		return $PROTOCOL_OK
			if -d $path;
		return error("Path $path is not a directory in _mkdir",0,1)
			if -e $path;
	}
	return error("Could not _mkdir $path: $!",0,1)
		if !mkdir($path);
	return error("Could not setTimestap on $path in _mkdir: $!")
		if !setTimestamp($path,$ts);
	return $PROTOCOL_OK
		if $may_exist;
	return $this->_list(pathOf($path));
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


#-----------------------------------------------------
# delete()
#-----------------------------------------------------

sub _deleteOne
{
	my ($this,
		$is_dir,
		$dir,
		$target_dir,	# unused for _delete
		$entry) = @_;

	return $PROTOCOL_ABORTED if
		$this->{progress} &&
		!$this->{progress}->setEntry($entry,0);

	if ($is_dir)
	{
		return error("$this->{NAME} Could not delete local dir $dir",0,1)
			if !rmdir($dir);
	}
	else
	{
		my $path = makePath($dir,$entry);
		return error("$this->{NAME} Could not delete local file $path: $!",0,1)
			if !unlink($path);
	}

	return $PROTOCOL_ABORTED if
		$this->{progress} &&
		!$this->{progress}->setDone($is_dir,!$is_dir);

	return '';
}


sub _delete
{
	my ($this,
		$dir,
		$entries) = @_;

	display($dbg_commands,0,"$this->{NAME} _delete($dir,$entries)");

	my $rslt;
	if (!ref($entries))
	{
		$rslt = $this->_deleteOne(0,$dir,'',$entries);
	}
	else
	{
		my $rslt = $this->recurseFxn(
			'_delete',
			\&_deleteOne,
			$dir,
			'',			# unused target_dir for DELETE
			$entries);
	}

	$rslt ||= $this->_list($dir);
	return $rslt;
}


#------------------------------------------------------
#  _file(), and _base64()
#------------------------------------------------------

sub initFile
{
	my ($this) = @_;
	$this->{file_handle} = '';
	$this->{file_size}   = '';
	$this->{file_ts} 	 = '';
	$this->{file_name} 	 = '';
	$this->{file_temp_name} = '';
	$this->{file_offset} = 0;
}

sub closeFile
{
	my ($this) = @_;
	display($dbg_commands,0,"$this->{NAME} closeFile($this->{file_name})");

	if ($this->{file_handle})
	{
		$this->{file_handle}->close();
		unlink $this->{file_temp_name} ?
			$this->{file_temp_name} :
			$this->{file_name};
	}
	$this->initFile();
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
		elsif (!rename($this->{file_temp_name},$this->{file_name}))
		{
			$rslt = error("$this->{NAME} finishFile() Could not rename($this->{file_temp_name},$this->{file_name})");
		}
	}

	if (!$rslt && $this->{file_ts} && !setTimestamp($this->{file_name},$this->{file_ts}))
	{
		$rslt = error("$this->{NAME} finishFile() Could not setTimestamp($this->{file_name},$this->{file_ts})");
	}

	$this->closeFile() if $rslt;
	$rslt ||= $PROTOCOL_OK;
	return $rslt;
}


sub _file
{
	my ($this,
		$size,
		$ts,
		$full_name) = @_;

	$this->initFile();
	display($dbg_commands,0,"$this->{NAME} _file($size,$ts,$full_name)");
	sleep($TEST_DELAY) if $TEST_DELAY;
	my $free = diskFree();

	return error("$this->{NAME} _file Attempt to overwrite directory($full_name) with file!")
		if -d $full_name;
	return error("$this->{NAME} _file File($full_name) too big($size) for disk($free)")
		if $size > $free;
	return error("$this->{NAME} _file Could not make subdirectories($full_name)")
		if !my_mkdir($full_name,1,$dbg_commands);
			# probably not needed now that PUT protocol includes MKDIR

	my $pid = $$;
	my $tid = threads->tid();
	my $temp_name = '';
	my $use_name = $full_name;
	if (-f $full_name)
	{
		$temp_name = "$full_name.$tid.$pid";
		$use_name = $temp_name;
	}

	return $PROTOCOL_ABORT if $this->{progress} &&
		$this->{progress}->aborted();

	return error("$this->{NAME} _file Could not open '$use_name' for output")
		if !open(my $fh, ">", $use_name);
	binmode $fh;

	$this->{file_handle} = $fh;
	$this->{file_size} = $size;
	$this->{file_ts} = $ts;
	$this->{file_name} = $full_name;
	$this->{file_temp_name} = $temp_name;
	$this->{file_offset} = 0;

	my $rslt = $size ?
		$PROTOCOL_CONTINUE :
		$this->finishFile();
	return $rslt;
}


sub calcChecksum
{
	my ($data) = @_;
	my $calc_cs = 0;
	for (my $i=0; $i<length($data); $i++)
	{
		$calc_cs += ord(substr($data,$i,1));
	}
	$calc_cs &= 0xFFFFFFFF;
	return $calc_cs;
}

sub _base64
{
	my ($this,
		$offset,
		$bytes,
		$content) = @_;

	my $rslt = '';
	my $len = length($content);
	display($dbg_commands,0,"$this->{NAME} _base64($offset,$bytes,$len encoded_bytes)");
	sleep($TEST_DELAY) if $TEST_DELAY;

	if ($content =~ s/^$PROTOCOL_ERROR//)
	{
		$rslt = $content;
	}
	elsif ($offset != $this->{file_offset})
	{
		$rslt = error("$this->{NAME} _base64 Unexpected offset($offset) for =($this->{file_name}) expected($this->{file_offset}")
	}
	elsif ($offset + $bytes > $this->{file_size})
	{
		$rslt = error("$this->{NAME} _base64 Bad parameters offset($offset) + bytes($bytes) > size($this->{size}");
	}
	elsif ($this->{progress} && $this->{progress}->aborted())
	{
		$rslt = $PROTOCOL_ABORT;
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

			# MSB first

			my $got_cs =
				(ord(substr($cs_bytes,0,1)) << 24) +
				(ord(substr($cs_bytes,1,1)) << 16) +
				(ord(substr($cs_bytes,2,1)) << 8 ) +
				ord(substr($cs_bytes,3,1));

			my $calc_cs = calcChecksum($data);
			display($dbg_commands+1,1,"$this->{NAME} ".sprintf("got_cs(0%08x) calc_cs(0x%08x)",$got_cs,$calc_cs));

			if ($got_cs != $calc_cs)
			{
				$rslt = error("$this->{NAME} _base64 incorrect checksum ".sprintf("got_cs(0%08x) calc_cs(0x%08x)",$got_cs,$calc_cs));
			}
			else
			{
				my $wrote = syswrite($this->{file_handle}, $data, $bytes);
				$rslt = error("$this->{NAME} _base64 bad write($wrote) expected($bytes)")
					if $wrote != $bytes;

				$this->{file_offset} += $bytes;

				$rslt ||= $this->{file_offset} == $this->{file_size} ?
					$this->finishFile() :
					$PROTOCOL_CONTINUE;
			}
		}
	}

	if ($rslt ne $PROTOCOL_OK &&
		$rslt ne $PROTOCOL_CONTINUE)
	{
		$this->closeFile();
	}

	return $rslt;
}



#-----------------------------------------------------
# _put
#-----------------------------------------------------

sub _putOne
{
	my ($this,
		$is_dir,
		$dir,
		$target_dir,
		$entry) = @_;

	display($dbg_commands,0,"$this->{NAME} _putOne($is_dir,$dir,$target_dir,$entry)");

	# ThreadedCommands for FILE and BASE64 will need some work ..
	# Assuming everything works peachy locally ...

	my $rslt = '';
	my $info = Pub::FS::FileInfo->new($is_dir,$dir,$entry);
	$rslt = $info if !isValidInfo($info);

	if (!$rslt)
	{
		my $ts = $info->{ts};
		my $size = $info->{size} || 0;
		my $path = makePath($dir,$entry);
		my $other_path = makePath($target_dir,$entry);

		return $PROTOCOL_ABORTED if
			$this->{progress} &&
			!$this->{progress}->setEntry($path,$size);

		if ($is_dir)
		{
			$rslt = $this->{other_session}->doCommand($PROTOCOL_MKDIR,
				$other_path,
				$ts,
				1);		# MAY_EXIST parameter specific to this method
			$rslt = '' if $rslt eq $PROTOCOL_OK;
		}
		else
		{
			my $size = $info->{size};

			if (!open(my $fh, "<", $path))
			{
				$rslt = error("$this->{NAME} _putOne($path) could not open file for reading");
			}
			else
			{
				binmode $fh;
				if (!$size)	# close ASAP
				{
					close $fh;
					$fh = 0;
				}

				$rslt = $this->{other_session}->doCommand($PROTOCOL_FILE,
					$size,
					$ts,
					$other_path);

				my $offset = 0;
				my $err_msg = '';
				while (!$err_msg && $rslt eq $PROTOCOL_CONTINUE)
				{
					my $data = '';
					my $bytes = $size - $offset;
					$bytes = $DECODED_BUF_SIZE if $bytes > $DECODED_BUF_SIZE;

					if ($bytes <= 0)
					{
						$err_msg = "$this->{NAME} _putOne($path) unexpected CONTINUE at offset($offset) size($size)";
						last;
					}

					my $got = sysread($fh, $data, $bytes);
					if ($got != $bytes)
					{
						$err_msg = "$this->{NAME} _putOne bad read($got) expected($bytes)";
						last;
					}
					else
					{
						# close the file ASAP, in case other session is
						# writing the same file and tries to close it

						if ($offset + $bytes >= $size)
						{
							close $fh;
							$fh = 0;
						}
						my $calc_cs = calcChecksum($data);
						display($dbg_commands+1,1,"$this->{NAME} _putOne ".sprintf("calc_cs(0x%08x)",$calc_cs));
						my $cs_bytes =
							chr(($calc_cs >> 24) & 0xff).
							chr(($calc_cs >> 16) & 0xff).
							chr(($calc_cs >> 8) & 0xff).
							chr($calc_cs & 0xff);
						my $encoded = encode64($data.$cs_bytes);

						$rslt = $this->{other_session}->doCommand($PROTOCOL_BASE64,
							$offset,
							$bytes,
							$encoded);

						$offset += $bytes;

						if (($rslt eq $PROTOCOL_OK ||
							 $rslt eq $PROTOCOL_CONTINUE) &&
							 $this->{progress} &&
							 !$this->{progress}->setBytes($offset))
						{
							$err_msg = $PROTOCOL_ABORTED;
						}

					}	# got == bytes
				}	# $rslt eq $PROTOCOL_CONTINUE;

				close $fh if $fh;

				# in the case of an error reading the file
				# once we have sent a FILE and received CONTINUE,
				# we call the other with a BASE64 0 0 ERROR message,
				# but do not check the results of the call

				if ($err_msg)
				{
					error($err_msg);
					$rslt = $err_msg;
					$this->{other_session}->doCommand($PROTOCOL_BASE64,0,0,
						$PROTOCOL_ERROR.$err_msg);
				}

				display($dbg_commands,0,"$this->{NAME} _putOne() ended with $rslt");
				$rslt = '' if $rslt eq $PROTOCOL_OK;

			}	# file opened
		}	# !info->{is_dir}
	}	# isValidInfo

	# returns blank to continue or an error

	$rslt ||= $PROTOCOL_ABORT if
		$this->{progress} &&
		!$this->{progress}->setDone($is_dir,!$is_dir);

	return $rslt;
}



sub _put
{
	my ($this,
		$dir,
		$target_dir,
		$entries) = @_;# ref() or single_file_name

	display($dbg_commands,0,"$this->{NAME} _put($dir,$target_dir,$entries)");

	my $rslt;
	if (!ref($entries))
	{
		$rslt = $PROTOCOL_ABORTED if
			$this->{progress} &&
			!$this->{progress}->addDirsAndFiles(0,1);
		$rslt ||= $this->_putOne(0,$dir,$target_dir,$entries);
	}
	else
	{
		$rslt = $this->recurseFxn(
			'_put',
			\&_putOne,
			$dir,
			$target_dir,
			$entries);
	}

	$rslt ||= $PROTOCOL_OK;
	return $rslt;

}



#-------------------------------------------------------
# recurseFxn
#-------------------------------------------------------
# Used by recursive DELETE and PUT

sub doFlatDir
	# the flatDir is done before recursion on _put,
	# and after the recursion on _delete
{
	my ($this,$command,$callback,$dir,$target_dir,$entry,) = @_;

	sleep($TEST_DELAY) if $TEST_DELAY;

	return $PROTOCOL_ABORTED if
		$this->{progress} &&
		$this->{progress}->aborted();

	display($dbg_commands,1,"$this->{NAME} $command local dir: $dir");

	my $err = &$callback($this,1,$dir,$target_dir,$entry);
	return $err if $err;
	return '';
}


sub recurseFxn
{
	my ($this,
		$command,
		$callback,
		$dir,				# MUST BE FULLY QUALIFIED
		$target_dir,		# unused for DELETE
		$entries,
		$level) = @_;

	$level ||= 0;

	display($dbg_commands,0,"$this->{NAME} $command($dir,$level)");

    return $PROTOCOL_ABORTED if
		$this->{progress} &&
		$this->{progress}->aborted();
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
		return $PROTOCOL_ABORTED if
			$this->{progress} &&
			!$this->{progress}->addDirsAndFiles(
				scalar(keys %$subdirs),
				scalar(keys %$files));
	}



	#-------------------------------------------
	# recurse thru subdirs
	#-------------------------------------------
	# do the flatDirs before the recursion for _put

	for my $entry  (sort {uc($a) cmp uc($b)} keys %$subdirs)
	{
		my $err;
		if ($command eq '_put')
		{
			$err = $this->doFlatDir($command,$callback,$dir,$target_dir,$entry);
			return $err if $err;
		}
		my $info = $subdirs->{$entry};
		$err = $this->recurseFxn(
			$command,
			$callback,
			makePath($dir,$entry),			# growing dir
			makePath($target_dir,$entry),	# growing target_dir
			$info->{entries},				# child entries
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

		return $PROTOCOL_ABORTED if $this->{progress} &&
			$this->{progress}->aborted();

		display($dbg_commands,1,"$this->{NAME} $command local file: $path");
		my $err = &$callback($this,0,$dir,$target_dir,$entry);
		return $err if $err;
	}

	# do the flatDir after the files for _delete

	if ($level && $command eq '_delete')
	{
		my $err = $this->doFlatDir($command,$callback,$dir,$target_dir,'');
		return $err if $err;
	}

	# method returns '' upon success

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
        $param3) = @_;

	display($dbg_commands+1,0,show_params("$this->{NAME} doCommand",$command,$param1,$param2,$param3));

	my $rslt;
	if ($command eq $PROTOCOL_LIST)					# $dir
	{
		$rslt = $this->_list($param1);
	}
	elsif ($command eq $PROTOCOL_MKDIR)				# $dir, $subdir, [$may_exist]
	{
		$rslt = $this->_mkdir($param1,$param2,$param3);
	}
	elsif ($command eq $PROTOCOL_RENAME)			# $dir, $old_name, $new_name
	{
		$rslt = $this->_rename($param1,$param2,$param3);
	}
	elsif ($command eq $PROTOCOL_DELETE)			# $dir, $entries_or_filename
	{
		$rslt = $this->_delete($param1,$param2);
	}
	elsif ($command eq $PROTOCOL_PUT)				# $dir, $target_dir, $entries_or_filename
	{
		$rslt = $this->_put($param1, $param2, $param3);
	}
	elsif ($command eq $PROTOCOL_FILE)				# $size, $ts, $fully_qualified_local_filename
	{
		$rslt = $this->_file($param1, $param2, $param3);
	}
	elsif ($command eq $PROTOCOL_BASE64)			# $offset, $bytes, ENCODED_CONTENT
	{
		$rslt = $this->_base64($param1, $param2, $param3);
	}
	else
	{
		$rslt = error("$this->{NAME} unsupported command: $command",0,1);
	}

	$rslt ||= error("$this->{NAME} unexpected empty doCommand() rslt",0,1);

	$rslt = $PROTOCOL_ERROR.$rslt if
		!isValidInfo($rslt) &&
		$rslt !~ /^($PROTOCOL_ERROR|$PROTOCOL_ABORT|$PROTOCOL_ABORTED|$PROTOCOL_CONTINUE|$PROTOCOL_OK)/;

	display($dbg_commands,0,"$this->{NAME} doCommand($command) returning $rslt");
	return $rslt;

}	# Session::doCommand()


1;
