#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::ServerSession
#-------------------------------------------------------
# A Server Session is an instance of a SocketSession
# which does the commands locally, but sends packet
# replies back to the client via the socket.

package Pub::FS::ServerSession;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::FS::FileInfo;
use Time::HiRes qw( sleep  );
use Pub::Utils;
use Pub::FS::FileInfo;
use Pub::FS::SocketSession;
use base qw(Pub::FS::SocketSession);


my $TEST_DELAY = 0;
 	# delay local operatios to test progress stuff
 	# set this to 1 or 2 seconds to slow things down for testing


BEGIN {
    use Exporter qw( import );
	our @EXPORT = ( qw (
	),
	@Pub::FS::SocketSession::EXPORT );
}



#------------------------------------------------
# lifecycle
#------------------------------------------------

sub new
{
	my ($class, $params, $no_error) = @_;
	$params ||= {};
	$params->{NAME} ||= 'ServerSession';
	$params->{RETURN_ERRORS} ||= 1;
    my $this = $class->SUPER::new($params);
	$this->{aborted} = 0;
	return if !$this;
	bless $this,$class;
	return $this;
}


#------------------------------------------------------
# session-like commands that can abort
#------------------------------------------------------
# have to call getPacket() to check for ABORTS
# and send progress packets



sub checkAbort
{
	my ($this) = @_;
	my $packet;
	my $err = $this->getPacket(\$packet);
	return $PROTOCOL_ABORTED if !$err && $packet && $packet =~ /^$PROTOCOL_ABORT/;
	return '';
}


sub checkProgress
{
	my ($this,$msg) = @_;
    my $err = $this->checkAbort();
	return $err if $err;
	my $packet = "$PROTOCOL_PROGRESS\t$msg";
	$err = $this->sendPacket($packet);
	return $err;
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
	display($dbg_commands,0,"$this->{NAME} _delete($dir,$entries)");

    my $err = $this->checkAbort();
	return $err if $err;
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

	if (scalar(keys %$subdirs) || scalar(keys %$files))
	{
	    $err = $this->checkProgress("ADD\t".
			scalar(keys %$subdirs)."\t".
			scalar(keys %$files));
		return $err if $err;
	}

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

		$err = $this->checkProgress("ENTRY\t$path");
		return $err if $err;

		display($dbg_commands,-5-$level,"$this->{NAME} DELETE local file: $path");
		return error("$this->{WHO} Could not delete local file $path",0,1)
			if !unlink($path);

		$err = $this->checkProgress("DONE\t0");
		return $err if $err;
	}


	#----------------------------------------------
	# finally, delete the dir itself at level>0
	#----------------------------------------------
	# recursions return 1 upon success

	if ($level)
	{
		sleep($TEST_DELAY) if $TEST_DELAY;

		$err = $this->checkProgress("ENTRY\t$dir");
		return $err if $err;

		display($dbg_commands,1,"$this->{NAME} DELETE local dir: $dir");
		return error("$this->{WHO} Could not delete local file $dir",0,1)
			if !rmdir($dir);

		$err = $this->checkProgress("DONE\t1");
		return $err if $err;
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
	my $rslt = $this->SUPER::doCommand($command,$param1,$param2,$param3);
	display($dbg_commands+1,0,"$this->{NAME} doCommand($command,$param1,$param2,$param3) returning $rslt");

	my $packet = $rslt;
	if (isValidInfo($rslt))
	{
		if ($rslt->{is_dir} && keys %{$rslt->{entries}})
		{
			$packet = dirInfoToText($rslt)
		}
		else
		{
			$packet = $rslt->toText();
		}
	}

	$this->sendPacket($packet);
}


1;
