#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::Session
#-------------------------------------------------------
# A Session accepts commands and acts upon.
# If they are purely local it acts on them directly:
#
# 	It can LIST or MKDIR a single directory at a time,
#     and can RENAME a single file or directory at a time.
# 	It can DELETE a set of local files recursively.
#
# For commands that are purely remote, it calls pure
#    virtual methods that must be implemented in
#    derived class.
#
# 	LIST, MKDIR, RENAME, and DELETE can be purely remote.
#
# All XFERS are hybrid, involving both a local and remote
#    aspect, and require substantial coordination.
#
# Note, once again, that for remote access this base class
# calls methods which are not implemented in it!!


package Pub::FS::Session;
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Select;
use IO::Socket::INET;
use Pub::Utils;
use Pub::FS::FileInfo;

our $dbg_session:shared = 1;
our $dbg_packets:shared = 0;
our $dbg_lists:shared = 1;
	# 0 = show lists encountered
	# -1 = show teztToList final hash
our $dbg_commands:shared = -1;
	# 0 = show atomic commands
	# -1 = show command header
	# -2 = show command details
our $dbg_recurse:shared = 0;


BEGIN {
    use Exporter qw( import );
	our @EXPORT = qw (

		$dbg_session
		$dbg_packets
		$dbg_lists
		$dbg_commands
		$dbg_recurse

		$DEFAULT_PORT
		$DEFAULT_HOST

		$SESSION_COMMAND_LIST
		$SESSION_COMMAND_RENAME
		$SESSION_COMMAND_MKDIR
		$SESSION_COMMAND_DELETE
		$SESSION_COMMAND_XFER
	);
}

our $DEFAULT_PORT = 5872;
our $DEFAULT_HOST = "localhost";

our $SESSION_COMMAND_LIST = "LIST";
our $SESSION_COMMAND_RENAME = "RENAME";
our $SESSION_COMMAND_MKDIR = "MKDIR";
our $SESSION_COMMAND_DELETE = "DELETE";
our $SESSION_COMMAND_XFER = "XFER";


#------------------------------------------------
# lifecycle
#------------------------------------------------

sub new
	# will try to connect to HOST:PORT if no SOCK is provided
{
	my ($class, $params, $no_error) = @_;
	$params ||= {};
	$params->{IS_REMOTE} ||= 0;
	$params->{HOST} ||= $DEFAULT_HOST;
	$params->{PORT} ||= $DEFAULT_PORT if !defined($params->{PORT});
	$params->{WHO} ||= $params->{IS_SERVER}?"SERVER":"CLIENT";
	my $this = { %$params };
	bless $this,$class;
	return if $this->{PORT} && !$this->{SOCK} && !$this->{IS_REMOTE} && !$this->connect();
	return $this;
}


sub session_error
    # report an error to the user and/or peer
    # server errors are capitalized!
{
    my ($this,$msg) = @_;
	error($msg);
    if ($this->{IS_SERVER} && $this->{SOCK})
    {
        $msg = "ERROR $msg";
        $this->sendPacket($msg);
		sleep(1);
	}
}



sub isConnected
{
    my ($this) = @_;
    return $this->{SOCK};
}


sub disconnect
{
    my ($this) = @_;
    display($dbg_session,-1,"$this->{WHO} disconnect()");
    if ($this->{SOCK})
    {
        $this->sendPacket('EXIT');
		close $this->{SOCK};
    }
    $this->{SOCK} = undef;
}



sub connect
{
    my ($this) = @_;
	my $host = $this->{HOST};
    my $port = $this->{PORT};

	display($dbg_session+1,-1,"$this->{WHO} connecting to $host:$port");

    my @psock = (
        PeerAddr => "$host:$port",
        PeerPort => "http($port)",
        Proto    => 'tcp' );
    my $sock = IO::Socket::INET->new(@psock);

    if (!$sock)
    {
        $this->session_error("$this->{WHO} could not connect to PORT $port")
			if !$this->{NO_CONNECT_ERROR};
    }
    else
    {
 		display($dbg_session,-1,"$this->{WHO} CONNECTED to PORT $port");
        $this->{SOCK} = $sock;

        return if !$this->sendPacket("HELLO");
        return if !defined(my $line = $this->getPacket(1));

        if ($line !~ /^WASSUP/)
        {
            $this->session_error("$this->{WHO} unexpected response from server: $line");
            return;
        }
    }

    return $sock ? 1 : 0;
}



#--------------------------------------------------
# packets
#--------------------------------------------------


sub sendPacket
{
    my ($this,$packet) = @_;

    if (length($packet) > 100)
    {
        display($dbg_packets,-1,"$this->{WHO} --> ".length($packet)." bytes",1);
    }
    else
    {
        display($dbg_packets,-1,"$this->{WHO} --> $packet",1);
    }

    my $sock = $this->{SOCK};
    if (!$sock)
    {
        $this->session_error("$this->{WHO} no socket in sendPacket");
        return;
    }

    if (!$sock->send($packet."\r\n"))
    {
        $this->{SOCK} = undef;
        $this->session_error("$this->{WHO} could not write to socket $sock");
        return;
    }

	$sock->flush();
    return 1;
}



sub getPacket
	# The protocol passes in $is_protocol, which blocks and prevents other
	# callers from getting packets.  Otherwise, the method does not block.

{
    my ($this,$is_protocol) = @_;
	$is_protocol ||= 0;

    my $sock = $this->{SOCK};
    if (!$sock)
    {
        $this->session_error("$this->{WHO} no socket in getPacket");
        return;
    }
	return if !$is_protocol && $this->{IN_PROTOCOL};
	$this->{IN_PROTOCOL} = $is_protocol;

	if (!$is_protocol)
	{
		my $select = IO::Select->new($sock);
		return if !$select->can_read(0.1);
	}

	my $CRLF = "\015\012";
	local $/ = $CRLF;

    my $packet = <$sock>;
    if (!defined($packet))
    {
		if ($is_protocol)
        {
			$this->{SOCK} = undef;
			$this->{IN_PROTOCOL} = 0;
			$this->session_error("$this->{WHO} no response from peer");
		}
		return;
    }

    $packet =~ s/(\r|\n)$//g;

    if (!$packet)
    {
		$this->{IN_PROTOCOL} = 0;
        $this->session_error("$this->{WHO} empty response from peer");
        return;
    }

    if (length($packet) > 100)
    {
        display($dbg_packets,-1,"$this->{WHO} <-- ".length($packet)." bytes",1);
    }
    else
    {
        display($dbg_packets,-1,"$this->{WHO} <-- $packet",1);
    }

	$this->{IN_PROTOCOL} = 0;
    return $packet;
}



#--------------------------------------------------
# textToList and listToText
#--------------------------------------------------
# These are flat lists of a directory.
# The first directory is the parent,
# and all files and subdirectories are direct children.

sub listToText
{
    my ($this,$list) = @_;
    display($dbg_lists,0,"$this->{WHO} listToText($list->{entry}) ".
		($list->{is_dir} ? scalar(keys %{$list->{entries}})." entries" : ""));

	my $text = $list->to_text()."\n";

	if ($list->{is_dir})
    {
		for my $entry (sort keys %{$list->{entries}})
		{
			my $info = $list->{entries}->{$entry};
			$text .= $info->to_text()."\n" if $info;
		}
	}
    return $text;
}


sub textToList
	# returns a FS_INFO which is the base directory
{
    my ($this,$text) = @_;
	if ($text =~ s/^ERROR - //)
	{
		# ok, just to remember, here is how this gets to the UI.
		# in Pub::Utils all errors() are reported to any UI
		# via getAppFrame() and getAppFrame()->can("ShowError").
		# So, we strip off the leading "ERROR - " and just call
		# error() with the message and it shows up in the UI.

		$this->session_error($text);
		return;
	}

	# the first directory listed is the base directory
	# all sub-entries go into it's {entries} member

    my $result;
    my @lines = split("\n",$text);
    display($dbg_lists,0,"$this->{WHO} textToList() lines=".scalar(@lines));

    for my $line (@lines)
    {
        my $info = Pub::FS::FileInfo->from_text($this,$line);
		if (!$result)
		{
			$result = $info;
		}
		else
		{
			$result->{entries}->{$info->{entry}} = $info;
		}
    }

	display_hash($dbg_lists+1,2,"$this->{WHO} textToList($result->{entry})",$result->{entries});
    return $result;
}


#------------------------------------------------------
# local atomic commands
#------------------------------------------------------

sub _listLocalDir
	# $dir must be fully qualified
	# must return a full list with fully qualified $dir_info->{entry}
{
    my ($this, $dir) = @_;
    display($dbg_commands,0,"$this->{WHO} _listLocalDir($dir)");

    my $dir_info = Pub::FS::FileInfo->new($this,1,$dir);
    return if (!$dir_info);

    if (!opendir(DIR,$dir))
    {
        $this->session_error("$this->{WHO} could not opendir $dir");
		return;
    }
    while (my $entry=readdir(DIR))
    {
        next if ($entry =~ /^(\.|\.\.)$/);
        my $path = makepath($dir,$entry);
        display($dbg_commands+2,1,"entry=$entry");
		my $is_dir = -d $path ? 1 : 0;

		my $info = Pub::FS::FileInfo->new($this,$is_dir,$dir,$entry);
		if (!$info)
		{
			closedir DIR;
			return;
		}
		$dir_info->{entries}->{$entry} = $info;
	}

    closedir DIR;
    return $dir_info;

}


sub _mkLocalDir
	# $dir must be fully qualified
	# must return defined value upon success
{
    my ($this, $dir, $subdir) = @_;
    display($dbg_commands,0,"$this->{WHO} _mkLocalDir($dir,$subdir)");
    my $path = makepath($dir,$subdir);
	if (!mkdir($path))
	{
		$this->session_error("Could not mkdir $path");
		return;
	}
	return Pub::FS::FileInfo->new($this,1,$dir,$subdir);
}


sub _renameLocal
	# $dir must be fully qualified
	# may return a partially qualified new FileInfo
	# but the fileClientWindow also checks for a fully qualified
	# one and removes the part that matches.
{
    my ($this, $dir, $name1, $name2) = @_;
    display($dbg_commands,0,"$this->{WHO} _renameLocal($dir,$name1,$name2)");
    my $path1 = makepath($dir,$name1);
    my $path2 = makepath($dir,$name2);

	my $is_dir = -d $path1;

	if (!-e $path1)
	{
		$this->session_error("$this->{WHO} file/dir $path1 not found");
		return;
	}
	if (-e $path2)
	{
		$this->session_error("$this->{WHO} file/dir $path2 already exists");
		return;
	}
	if (!rename($path1,$path2))
	{
		$this->session_error("$this->{WHO} Could not rename $path1 to $path2");
		return;
	}

	return Pub::FS::FileInfo->new($this,$is_dir,$dir,$name2);
}




#------------------------------------------------------
# doCommand and doCommandRecursive
#------------------------------------------------------

sub doCommand
{
    my ($this,
		$command,
        $local,
        $param1,
        $param2,
        $param3,
		$progress) = @_;

	$command ||= '';
	$local ||= 0;
	$param1 ||= '';
	$param2 ||= '';
	$param3 ||= '';
	$progress ||= '';

	display($dbg_commands+1,0,"$this->{WHO} doCommand($command,$local,$param1,$param2,$param3) progress=$progress");

	# For these calls param1 MUST BE A FULLY QUALIFIED DIR

	if ($command eq $SESSION_COMMAND_LIST)				# $dir
	{
		return $local ?
			$this->_listLocalDir($param1) :
			$this->_listRemoteDir($param1);
	}
	elsif ($command eq $SESSION_COMMAND_MKDIR)			# $dir, $subdir
	{
		return $local ?
			$this->_mkLocalDir($param1,$param2) :
			$this->_mkRemoteDir($param1,$param2);
	}
	elsif ($command eq $SESSION_COMMAND_RENAME)			# $dir, $old_name, $new_name
	{
		return $local ?
			$this->_renameLocal($param1,$param2,$param3) :
			$this->_renameRemote($param1,$param2,$param3);
	}

	# for delete, a single filename name or list of entries
	# may be passed in. A local single filename is handled specially.

	elsif ($command eq $SESSION_COMMAND_DELETE)			# $dir, $entries_or_filename, undef, $progress
	{
		return $this->_deleteRemote($param1,$param3,$param2)
			if !$local;

		if (!ref($param2))		# single fully qualified filename
		{
			my $path = "$param1/$param2";
			display($dbg_commands,0,"$this->{WHO} DELETE single local file: $path");
			if (!unlink $path)
			{
				$this->session_error("$this->{WHO} Could not delete single local file $path");
				return;
			}
			return $this->_listLocalDir($param1);
		}
		return $this->_deleteLocal($param1,$param2,$progress);
	}

	$this->session_error("$this->{WHO} unsupported command: $command");
	return;
}



sub _deleteLocal
{
	my ($this,
		$dir,				# MUST BE FULLY QUALIFIED
		$entries,
		$progress,
		$level) = @_;

	$level ||= 0;

	display($dbg_recurse,-2-$level,"_deleteLocal($dir,$level)");
	return if $progress && $progress->aborted();

	#----------------------------------------------------
	# scan directory of any dir entries
	#----------------------------------------------------
	# adding their child entries, and pushing them on @subdirs
	# otherwise, push file entries onto @files

	my $files = {};
	my $subdirs = {};

	for my $entry  (sort {uc($a) cmp uc($b)} keys %$entries)
	{
		display($dbg_recurse,-4-$level,"entry=$entry");
		my $entry_info = $entries->{$entry};
		if ($entry_info->{is_dir})
		{
			my $dir_path = "$dir/$entry";
			my $dir_entries = $entry_info->{entries};
			$progress->incNumDirs() if $progress;

			if (!opendir DIR,$dir_path)
			{
				$this->session_error("_deleteLocal($level) could not opendir($dir)");
				return;
			}
			while (my $dir_entry=readdir(DIR))
			{
				next if ($dir_entry =~ /^(\.|\.\.)$/);
				display($dbg_recurse,-4-$level,"dir_entry=$dir_entry");
				my $sub_path = makepath($dir_path,$dir_entry);
				my $is_dir = -d $sub_path ? 1 : 0;

				my $info = Pub::FS::FileInfo->new($this,$is_dir,$dir_path,$dir_entry);
				if (!$info)
				{
					closedir DIR;
					return;
				}
				$dir_entries->{$dir_entry} = $info;
			}

			closedir DIR;
			$subdirs->{$entry} = $entry_info;
		}
		else
		{
			$progress->incNumFiles() if $progress;
			$files->{$entry} = $entry_info;
		}
	}

	#-------------------------------------------
	# depth first recurse thru subdirs
	#-------------------------------------------

	for my $entry  (sort {uc($a) cmp uc($b)} keys %$subdirs)
	{
		my $info = $entries->{$entry};
		return if !$this->_deleteLocal(
			"$dir/$entry",					# dir
			$info->{entries},				# dir_info
			$progress,
			$level + 1);
	}


	#-------------------------------------------
	# iterate the flat files in the directory
	#-------------------------------------------

	for my $entry  (sort {uc($a) cmp uc($b)} keys %$files)
	{
		return if $progress && $progress->aborted();
		my $info = $entries->{$entry};
		if (!$info->{is_dir})
		{
			$progress->incFilesDone($entry) if $progress;

			my $path = "$dir/$entry";
			display($dbg_recurse,-5-$level,"$this->{WHO} DELETE local file: $path");
			if (!unlink $path)
			{
				$this->session_error("$this->{WHO} Could not delete local file $path");
				return;
			}
		}
	}

	#----------------------------------------------
	# finally, delete the dir itself at level>0
	#----------------------------------------------
	# recursions return 1 upon success

	if ($level)
	{
		return if $progress && $progress->aborted();
		display($dbg_recurse,-5-$level,"$this->{WHO} DELETE local dir: $dir");
		if (!rmdir $dir)
		{
			$this->session_error("$this->{WHO} Could not delete local file $dir");
			return;
		}
		$progress->incDirsDone($dir) if $progress;

		return 1;
	}

	# level 0 returns a directory listing on success

	$progress->done() if $progress;
	return $this->_listLocalDir($dir);
}


1;
