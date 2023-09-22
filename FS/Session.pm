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
use Time::HiRes qw( sleep  );
use IO::Select;
use IO::Socket::INET;
use Pub::Utils;
use Pub::FS::FileInfo;


my $TEST_DELAY:shared = 0;
	# delay certain operatios to test progress stuff
	# set this to 1 or 2 seconds to slow things down for testing


our $dbg_session:shared = -1;
our $dbg_packets:shared = -1;
our $dbg_lists:shared = 1;
	# 0 = show lists encountered
	# -1 = show teztToList final hash
our $dbg_commands:shared = 0;
	# 0 = show atomic commands
	# -1 = show command header and return resu;ts
our $dbg_recurse:shared = 0;
	# show recursive command execution (like DELETE)
our $dbg_progress:shared = 1;


my $DEFAULT_TIMEOUT = 15;


BEGIN {
    use Exporter qw( import );
	our @EXPORT = qw (

		$dbg_session
		$dbg_packets
		$dbg_lists
		$dbg_commands
		$dbg_recurse
		$dbg_progress

		$DEFAULT_PORT
		$DEFAULT_HOST

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

	);
}

our $DEFAULT_PORT = 5872;
our $DEFAULT_HOST = "localhost";

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
our $PROTOCOL_ABORT		= "ABORT";
our $PROTOCOL_ABORTED   = "ABORTED";
our $PROTOCOL_PROGRESS  = "PROGRESS";
our $PROTOCOL_DELETE 	= "DELETE";
our $PROTOCOL_XFER 		= "XFER";


# Each thread has a separate SOCK from the Server
#    and getPacket cannot be re-entered by them.
# There can be upto two WX thread per SOCK in each fileClientWindow.
#    One for the main process, which can be protocol, or not,
#    and one for a threadedCommand underway.
# The session ctor from the fileClientWindow passes
#    in the non-zero instance number

my $instance_in_protocol:shared = shared_clone({});
	# re-entrancy protection for fileClientWindows

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
	$params->{TIMEOUT} ||= $DEFAULT_TIMEOUT;
	$params->{INSTANCE} ||= 0;
	my $this = { %$params };

	$instance_in_protocol->{$this->{INSTANCE}} = 0
		if $this->{INSTANCE};

	bless $this,$class;
	return if $this->{PORT} && !$this->{SOCK} && !$this->{IS_REMOTE} && !$this->connect();
	return $this;
}


sub session_error
    # report an error to the user and/or peer
    # server errors are capitalized!
{
    my ($this,$msg) = @_;
	error($msg,1);

    if ($this->{IS_SERVER} && $this->{SOCK})
    {
        $msg = $PROTOCOL_ERROR.$msg;
        $this->sendPacket($msg);
		sleep(0.5);
			# to allow packet to be sent
			# in case we are shutting down
	}

	# if in a WX thread we return the error message
	# otherwise we return blank

	if (getAppFrame() && threads->tid())
	{
		return $PROTOCOL_ERROR.$msg;
	}
	else
	{
		return ''
	}
}

sub textError
{
	my ($this,$text) = @_;
	return $this->session_error($text) if $text =~ s/^$PROTOCOL_ERROR//;
	return ''
}

sub isConnected
{
    my ($this) = @_;
    return $this->{SOCK} ? 1 : 0;
}


sub disconnect
{
    my ($this) = @_;
    display($dbg_session,-1,"$this->{WHO} disconnect()");
    if ($this->{SOCK})
    {
        $this->sendPacket($PROTOCOL_EXIT);
		close $this->{SOCK};
    }
    $this->{SOCK} = undef;
}



sub connect
{
    my ($this) = @_;
	my $host = $this->{HOST};
    my $port = $this->{PORT};
	$this->{SOCK} = undef;

	display($dbg_session+1,-1,"$this->{WHO} connecting to $host:$port");

   $this->{SOCK} = IO::Socket::INET->new(
		PeerAddr => "$host:$port",
        PeerPort => "http($port)",
        Proto    => 'tcp',
		Timeout  => $DEFAULT_TIMEOUT );

    if (!$this->{SOCK})
    {
        error("$this->{WHO} could not connect to PORT $port");
    }
    else
    {
		my $rcv_buf_size = 10240;
		$this->{SOCK}->sockopt(SO_RCVBUF, $rcv_buf_size);
 		display($dbg_session,-1,"$this->{WHO} CONNECTED to PORT $port");
		my $ok = $this->sendPacket($PROTOCOL_HELLO);
		if ($ok)
		{
			my $line = $this->getPacket(1);
			$ok = $line ? 1 : 0;
			if ($ok && $line !~ /^$PROTOCOL_WASSUP/)
			{
	            error("$this->{WHO} unexpected response from server: $line");
				$ok = 0;
			}
		}
		if (!$ok)
		{
			$this->{SOCK}->close();
			$this->{SOCK} = undef;
        }
    }

    return $this->{SOCK} ? 1 : 0;
}



#--------------------------------------------------
# packets
#--------------------------------------------------


sub sendPacket
{
    my ($this,$packet) = @_;
	display($dbg_packets+2,0,"sendPacket()")
		if !$this->{IS_SERVER};
	if ($dbg_packets <= 0)
	{
		if (length($packet) > 100)
		{
			display($dbg_packets,-1,"$this->{WHO} --> ".length($packet)." bytes",1);
		}
		else
		{
			my $show_packet = $packet;
			$show_packet =~ s/\r/\r\n/g;
			display($dbg_packets,-1,"$this->{WHO} --> $show_packet",1);
		}
	}

	my $instance = $this->{INSTANCE};
	if ($instance)
	{
		my $in_protocol = $instance_in_protocol->{$instance};
		if ($in_protocol)
		{
			error("sendPacket() while in_protocol=$in_protocol ".
			  "for instance=$instance");
			return;
		}
	}

    my $sock = $this->{SOCK};
    if (!$sock)
    {
        error("$this->{WHO} no socket in sendPacket");
        return;
    }

    if (!$sock->send($packet."\r\n"))
    {
        $this->{SOCK} = undef;
        error("$this->{WHO} could not write to socket $sock");
        return;
    }

	$sock->flush();
    return 1;
}


sub getPacketInstance
{
	my ($this,$is_protocol) = @_;
	my $instance = $this->{INSTANCE};
	$instance_in_protocol->{$instance}++ if $instance;
    my $packet = $this->getPacket(1);
	$instance_in_protocol->{$instance}-- if $instance;
	return $packet;
}


sub getPacket
	# The protocol passes in $is_protocol, which blocks and prevents other
	# callers from getting packets.  Otherwise, the method does not block.
{
    my ($this,$is_protocol) = @_;
	$is_protocol ||= 0;

	display($dbg_packets-1,0,"getPacket($is_protocol)")		# ,$in_protocol)")
		if !$this->{IS_SERVER} && $is_protocol;

    my $sock = $this->{SOCK};
    if (!$sock)
    {
        error("$this->{WHO} no socket in getPacket");
        return '';
    }


	my $instance = $this->{INSTANCE};
	if ($instance)

	{
		my $in_protocol = $instance_in_protocol->{$instance};
		return if !$is_protocol && $in_protocol;

		if ($is_protocol && $in_protocol > 1)
		{
			error("getPacket(1) while in_protocol=$in_protocol ".
				  "for instance=$instance");
			return '';
		}
	}


	# if !protocol, return immediately
	# if protcol, watch for timeouts

	my $can_read;
	my $packet = '';
	my $started = time();
	my $select = IO::Select->new($sock);
	while (1)
	{
		$can_read = $select->can_read(0.1);
		last if $can_read;
		last if !$is_protocol;
		if (time() > $started + $this->{TIMEOUT})
		{
			error("getPacket timed out");
			last;
		}
	}

	if ($can_read)
	{
		my $CRLF = "\015\012";
		local $/ = $CRLF;

		$packet = <$sock>;
		if (!defined($packet))
		{
			if ($is_protocol)
			{
				$this->{SOCK} = undef;
				error("$this->{WHO} no response from peer");
			}
			$packet = '';
		}
		else
		{
			$packet =~ s/(\r|\n)$//g;
			if (!$packet)
			{
				error("$this->{WHO} empty response from peer");
			}
			else	# debugging only
			{
				if ($dbg_packets <= 0)
				{
					if (length($packet) > 100)
					{
						display($dbg_packets,-1,"$this->{WHO} <-- ".length($packet)." bytes",1);
					}
					else
					{
						my $show_packet = $packet;
						$show_packet =~ s/\r/\r\n/g;
						display($dbg_packets,-1,"$this->{WHO} <-- $show_packet",1);
					}

				}	# debugging only
			}	# non-empty packet
		}	# defined($packet)
	}	# $can_read

	display(0,0,"getPacket() returning")
		if $is_protocol && !$this->{IS_SERVER};
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
	my $err = $this->textError($text);
	return $err if $err;

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



#--------------------------------------------------------
# remote atomic commands
#--------------------------------------------------------

sub _listRemoteDir
{
    my ($this, $dir) = @_;
    display($dbg_commands,0,"_listRemoteDir($dir)");

    my $command = "$PROTOCOL_LIST\t$dir";

    return if !$this->sendPacket($command);
    my $packet = $this->getPacketInstance(1);
    return if (!$packet);

    my $rslt = $this->textToList($packet);
	if (ref($rslt))
	{
		display_hash($dbg_commands+1,1,"_listRemoteDir($dir) returning",$rslt->{entries})
	}
	else
	{
		display($dbg_commands+1,1,"_listRemoteDir($dir}) returning $rslt");
	}
    return $rslt;
}


sub _mkRemoteDir
{
    my ($this, $dir,$subdir) = @_;
    display($dbg_commands,0,"_mkRemoteDir($dir,$subdir)");

    my $command = "$PROTOCOL_MKDIR\t$dir\t$subdir";

    return if !$this->sendPacket($command);
    my $packet = $this->getPacketInstance(1);
    return if (!$packet);

    my $rslt = $this->textToList($packet);
	if (ref($rslt))
	{
		display_hash($dbg_commands+1,1,"_mkRemoteDir($dir) returning",$rslt->{entries})
	}
	else
	{
		display($dbg_commands+1,1,"_mkRemoteDir($dir}) returning $rslt");
	}
    return $rslt;
}


sub _renameRemote
{
    my ($this,$dir,$name1,$name2) = @_;
    display($dbg_commands,0,"_renameRemote($dir,$name1,$name2)");

    my $command = "$PROTOCOL_RENAME\t$dir\t$name1\t$name2";

    return if !$this->sendPacket($command);
    my $packet = $this->getPacketInstance(1);
    return if (!$packet);

    my $rslt = $this->textToList($packet);
	if (ref($rslt))
	{
		display_hash($dbg_commands+1,1,"_renameRemote($dir) returning",$rslt->{entries})
	}
	else
	{
		display($dbg_commands+1,1,"_renameRemote($dir}) returning $rslt");
	}
    return $rslt;
}






sub handleProgress
{
	my ($this,$packet,$progress) = @_;

	if ($packet =~ s/^PROGRESS\t(.*?)\t//)
	{
		my $command = $1;
		$packet =~ s/\s+$//g;
		display($dbg_progress,-1,"handleProgress() PROGRESS($command) $packet");

		# PRH hmm ..
		# these methods are on the fileClientPane for threaded requests
		# which pushes them onto a shared list which is processed by?!?
		# onIdle() ?!?!

		if ($progress)
		{
			my @params = split(/\t/,$packet);
			$progress->addDirsAndFiles($params[0],$params[1])
				if $command eq 'ADD';
			$progress->setDone($params[0])
				if $command eq 'DONE';
			$progress->setEntry($params[0])
				if $command eq 'ENTRY';
		}
		return 1;
	}
	return 0;
}




sub _deleteRemote			# RECURSES!!
{
	my ($this,
		$dir,				# MUST BE FULLY QUALIFIED
		$entries,
		$progress ) = @_;

	if ($dbg_commands < 0)
	{
		my $show_entries = ref($entries) ? '' : $entries;
		display($dbg_commands,0,"_deleteRemote($dir,$show_entries)");
	}

    my $command = "$PROTOCOL_DELETE\t$dir";

	if (!ref($entries))
	{
		$command .= "\t$entries";	# single filename version
	}
	else	# full version
	{
		$command .= "\r";
		for my $entry (sort keys %$entries)
		{
			my $info = $entries->{$entry};
			my $text = $info->to_text();
			display($dbg_commands,1,"entry=$text");
			$command .= "$text\r" if $info;
		}
	}

    return if !$this->sendPacket($command);

	my $instance = $this->{INSTANCE};
	$instance_in_protocol->{$instance}++ if $instance;

	# so here we have the prototype of a progressy remote command
	# note that an abort or any errors currently leaves the client
	# remote listing unchanged

	my $retval = '';
	while (1)
	{
		my $packet = $this->getPacket(1);
		my $err = $this->textError($packet);
		if ($err)
		{
			$retval = $err;
			last;
		}
		if (!$this->handleProgress($packet,$progress))
		{
			$retval = $this->textToList($packet);
			last;
		}
	}

	$instance_in_protocol->{$instance}-- if $instance;
	return $retval;

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
        return $this->session_error("$this->{WHO} could not opendir $dir");
    }
    while (my $entry=readdir(DIR))
    {
        next if ($entry =~ /^(\.|\.\.)$/);
        my $path = makepath($dir,$entry);
        display($dbg_commands+1,1,"entry=$entry");
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
		return $this->session_error("Could not mkdir $path");
	}
	return $this->_listLocalDir($dir);
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
		return $this->session_error("$this->{WHO} file/dir $path1 not found");
	}
	if (-e $path2)
	{
		return $this->session_error("$this->{WHO} file/dir $path2 already exists");
	}
	if (!rename($path1,$path2))
	{
		return $this->session_error("$this->{WHO} Could not rename $path1 to $path2");
	}

	return Pub::FS::FileInfo->new($this,$is_dir,$dir,$name2);
}


sub _deleteLocal			# RECURSES!!
{
	my ($this,
		$dir,				# MUST BE FULLY QUALIFIED
		$entries,
		$progress,
		$level) = @_;

	$level ||= 0;

	display($dbg_recurse,-2-$level,"_deleteLocal($dir,$level)");
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
		display($dbg_recurse,-4-$level,"entry=$entry");
		my $entry_info = $entries->{$entry};
		if ($entry_info->{is_dir})
		{
			my $dir_path = "$dir/$entry";
			my $dir_entries = $entry_info->{entries};

			if (!opendir DIR,$dir_path)
			{
				return $this->session_error("_deleteLocal($level) could not opendir($dir)");
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
			$files->{$entry} = $entry_info;
		}
	}

	$progress->addDirsAndFiles(
		scalar(keys %$subdirs),
		scalar(keys %$files))
		if scalar(keys %$subdirs) || scalar(keys %$files);

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
		sleep($TEST_DELAY) if $TEST_DELAY;
		return $PROTOCOL_ABORTED if $progress && $progress->aborted();

		my $info = $entries->{$entry};
		if (!$info->{is_dir})
		{
			my $path = "$dir/$entry";
			$progress->setEntry($path) if $progress;
			display($dbg_recurse,-5-$level,"$this->{WHO} DELETE local file: $path");
			if (!unlink $path)
			{
				return $this->session_error("$this->{WHO} Could not delete local file $path");
			}
			$progress->setDone(0) if $progress;
		}
	}

	#----------------------------------------------
	# finally, delete the dir itself at level>0
	#----------------------------------------------
	# recursions return 1 upon success

	if ($level)
	{
		sleep($TEST_DELAY) if $TEST_DELAY;
		return $PROTOCOL_ABORTED if $progress && $progress->aborted();

		$progress->setEntry($dir) if $progress;
		display($dbg_recurse,-5-$level,"$this->{WHO} DELETE local dir: $dir");
		if (!rmdir $dir)
		{
			$this->session_error("$this->{WHO} Could not delete local file $dir");
			return;
		}
		$progress->setDone(1) if $progress;
		return 1;
	}

	# level 0 returns a directory listing on success

	return $this->_listLocalDir($dir);
}



#------------------------------------------------------
# doCommand
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

	if ($command eq $PROTOCOL_LIST)				# $dir
	{
		# returns dir_info with entries
		return $local ?
			$this->_listLocalDir($param1) :
			$this->_listRemoteDir($param1);
	}
	elsif ($command eq $PROTOCOL_MKDIR)			# $dir, $subdir
	{
		# returns file_info for the new dir
		return $local ?
			$this->_mkLocalDir($param1,$param2) :
			$this->_mkRemoteDir($param1,$param2);
	}
	elsif ($command eq $PROTOCOL_RENAME)			# $dir, $old_name, $new_name
	{
		# returns file_info for the renamed item
		return $local ?
			$this->_renameLocal($param1,$param2,$param3) :
			$this->_renameRemote($param1,$param2,$param3);
	}

	# for delete, a single filename name or list of entries
	# may be passed in. A local single filename is handled specially.

	elsif ($command eq $PROTOCOL_DELETE)			# $dir, $entries_or_filename, undef, $progress
	{
		# returns new dir_info with entries
		return $this->_deleteRemote($param1,$param2,$progress)
			if !$local;

		# single fully qualified filename is handled specially
		# since _deleteLocal expects a list of entries for recursion

		if (!ref($param2))
		{
			my $path = "$param1/$param2";
			display($dbg_commands,0,"$this->{WHO} DELETE single local file: $path");
			if (!unlink $path)
			{
				return $this->session_error("$this->{WHO} Could not delete single local file $path");
			}
			return $this->_listLocalDir($param1);
		}
		return $this->_deleteLocal($param1,$param2,$progress);
	}

	return $this->session_error("$this->{WHO} unsupported command: $command");
}





1;
