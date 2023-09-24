#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::Session
#-------------------------------------------------------
# A Session accepts commands and acts upon them.
#
# The base Session acts on commands as follows:
#
# If they are purely local it acts on them directly:
#
# 	It can LIST or MKDIR a single directory at a time,
#     and can RENAME a single file or directory at a time.
# 	It can DELETE a set of local files recursively.
#
# For commands that purely remote, it sends the
#    calls pure
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
#
#-----------------------------------------------------------
#
# Error handling and reporting:
#
# Errors may now be returned by every method including getPacket()
# and sendPacket().  It is upto the Server or main thread of thee
# fileClient to call error to display them and/or forward them
# to the client socket, with the exception of errors in connect()
# which is the only method known to only be called from the main
# thread of the UI.
#
# The default Session is for a vanilla fileServeer


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
our $dbg_packets:shared =  0;
our $dbg_lists:shared = 1;
	# 0 = show lists encountered
	# -1 = show teztToList final hash
our $dbg_commands:shared = 0;
	# 0 = show atomic commands
	# -1 = show command header and return resu;ts
our $dbg_recurse:shared = 1;
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
		$PROTOCOL_GET
	    $PROTOCOL_PUT
	    $PROTOCOL_CONTINUE
	    $PROTOCOL_BASE64

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

our $PROTOCOL_GET       = "GET";
our $PROTOCOL_PUT		= "PUT";
our $PROTOCOL_CONTINUE  = "CONTINUE";
our $PROTOCOL_BASE64	= "BASE64";



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
	# CLIENT will try to connect to HOST:PORT if no SOCK is provided
	# IS_BRIDGED means this Session is connected to a SerialBridge.
	# IS_BRIDGE means that this Session IS a SerialSession.
{
	my ($class, $params, $no_error) = @_;
	$params ||= {};
	$params->{HOST} ||= $DEFAULT_HOST;
	$params->{PORT} ||= $DEFAULT_PORT if !defined($params->{PORT});
	$params->{WHO} ||= $params->{IS_SERVER}?"SERVER":"CLIENT";
	$params->{TIMEOUT} ||= $DEFAULT_TIMEOUT;
	$params->{INSTANCE} ||= 0;
	$params->{IS_BRIDGE} ||= 0;
	$params->{IS_BRIDGED} ||= 0;

	my $this = { %$params };

	$instance_in_protocol->{$this->{INSTANCE}} = 0
		if $this->{INSTANCE};

	bless $this,$class;
	return if !$this->{IS_SERVER} && $this->{PORT} && !$this->{SOCK} && !$this->connect();
	return $this;
}


sub server_error
	# ONLY FOR USE BY SERVER SESSIONS
    # report an error to the user and/or peer
    # server errors are capitalized!
{
    my ($this,$msg) = @_;
	if (!$this->{IS_SERVER})
	{
		my $save_app = getAppFrame();
		setAppFrame(undef);
		error("server_error($msg) called from Client app save_app=$save_app!");
		setAppFrame($save_app);
		return;
	}

	error($msg,1);
    if ($this->{SOCK})
    {
        $msg = $PROTOCOL_ERROR.$msg;
        $this->sendPacket($msg);
		sleep(0.5);
			# to allow packet to be sent
			# in case we are shutting down
	}

	# if in a WX thread we return the error message
	# otherwise we return blank

	return $PROTOCOL_ERROR.$msg;
}



sub textError
{
	my ($this,$text) = @_;
	return $text if $text =~ /^($PROTOCOL_ERROR|$PROTOCOL_ABORTED)/;
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
		# no error checking
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
		my $err = $this->sendPacket($PROTOCOL_HELLO);
		if (!$err)
		{
			my $packet;
			$err = $this->getPacket(\$packet,1);
	        $err = "$this->{WHO} unexpected response from server: $packet"
				if !$err && $packet !~ /^$PROTOCOL_WASSUP/;
		}
		if ($err)
		{
			$err =~ s/^$PROTOCOL_ERROR//;
			error($err);
			$this->{SOCK}->close() if $this->{SOCK};
			$this->{SOCK} = undef;
        }
    }

    return $this->{SOCK} ? 1 : 0;
}



#--------------------------------------------------
# packets
#--------------------------------------------------


sub sendPacket
	# returns an error or '' upon success
{
    my ($this,$packet,$override_protocol) = @_;
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
	if ($instance && !$override_protocol)
	{
		my $in_protocol = $instance_in_protocol->{$instance};
		return reportError("sendPacket() while in_protocol=$in_protocol for instance=$instance")
			if ($in_protocol)
	}

    my $sock = $this->{SOCK};
    return reportError("$this->{WHO} no socket in sendPacket") if !$sock;

    if (!$sock->send($packet."\r\n"))
    {
        $this->{SOCK} = undef;
        return reportError("$this->{WHO} could not write to socket $sock");
    }

	$sock->flush();
    return '';
}


sub getPacketInstance
{
	my ($this,$ppacket) = @_;
	my $instance = $this->{INSTANCE};
	$instance_in_protocol->{$instance}++ if $instance;
    my $err = $this->getPacket($ppacket,1);	# always is_protocol
	$instance_in_protocol->{$instance}-- if $instance;
	return $err;
}

sub incInProtocol
{
	my ($this) = @_;
	my $instance = $this->{INSTANCE};
	$instance_in_protocol->{$instance}++ if $instance;
}
sub decInProtocol
{
	my ($this) = @_;
	my $instance = $this->{INSTANCE};
	$instance_in_protocol->{$instance}-- if $instance;
}



sub getPacket
	# fills in the passed in reference to a packet.
	# returns an error or '' upon success.
	# The protocol passes in $is_protocol, which blocks and prevents other
	# callers from getting packets.  Otherwise, the method does not block.
{
    my ($this,$ppacket,$is_protocol) = @_;
	$$ppacket = '';
	$is_protocol ||= 0;

	display($dbg_packets+1,0,"getPacket($is_protocol)")		# ,$in_protocol)")
		if !$this->{IS_SERVER} && $is_protocol;

    my $sock = $this->{SOCK};
    return reportError("$this->{WHO} no socket in getPacket") if !$sock;

	my $instance = $this->{INSTANCE};
	if ($instance)
	{
		my $in_protocol = $instance_in_protocol->{$instance};
		return '' if !$is_protocol && $in_protocol;
			# case of empty packet with no error
		reportError("getPacket(1) while in_protocol=$in_protocol for instance=$instance")
			if $is_protocol && $in_protocol > 1;
	}


	# if !protocol, return immediately
	# if protcol, watch for timeouts

	my $can_read;
	my $started = time();
	my $select = IO::Select->new($sock);
	while (1)
	{
		$can_read = $select->can_read(0.1);
		last if $can_read;
		return '' if !$is_protocol;
			# case of empty packet with no error
		return reportError("getPacket timed out")
			if time() > $started + $this->{TIMEOUT};
	}

	# can_read is true here

	my $CRLF = "\015\012";
	local $/ = $CRLF;

	$$ppacket = <$sock>;
	if (!defined($$ppacket))
	{
		$$ppacket = '';
		$this->{SOCK} = undef;
		return reportError("$this->{WHO} no response from peer");
	}

	$$ppacket =~ s/(\r|\n)$//g;
	return reportError("$this->{WHO} empty response from peer") if !$$ppacket;

	if ($dbg_packets <= 0)
	{
		if (length($$ppacket) > 100)
		{
			display($dbg_packets,-1,"$this->{WHO} <-- ".length($$ppacket)." bytes",1);
		}
		else
		{
			my $show_packet = $$ppacket;
			$show_packet =~ s/\r/\r\n/g;
			display($dbg_packets,-1,"$this->{WHO} <-- $show_packet",1);
		}
	}	# debugging only

	display($dbg_packets+1,0,"getPacket() returning ok")
		if $is_protocol && !$this->{IS_SERVER};

	return '';	# no error in getPacket()

}	# getPacket()



#--------------------------------------------------
# textToList and listToText
#--------------------------------------------------
# These are flat lists of a directory.
# The first directory is the parent,
# and all files and subdirectories are direct children.

sub listToText
{
    my ($this,$list) = @_;
	return reportError("invalid call to listToText($list)") if !isValidInfo($list);

    display($dbg_lists,0,"$this->{WHO} listToText($list->{entry}) ".
		($list->{is_dir} ? scalar(keys %{$list->{entries}})." entries" : ""));

	my $text = $list->toText()."\n";
	if ($list->{is_dir})
    {
		for my $entry (sort keys %{$list->{entries}})
		{
			my $info = $list->{entries}->{$entry};
			$text .= $info->toText()."\n" if $info;
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
        my $info = Pub::FS::FileInfo->fromText($this,$line);
		if (!isValidInfo($info))
		{
			$result = $info;
			last;
		}
		if (!$result)
		{
			if (!$info->{is_dir})
			{
				$result = reportError("textToList must start with a DIR_ENTRY not the file: $info->{entry}");
				last;
			}
			$result = $info;
		}
		else
		{
			$result->{entries}->{$info->{entry}} = $info;
		}
    }

	if (isValidInfo($result))
	{
		display_hash($dbg_lists+1,2,"$this->{WHO} textToList($result->{entry})",$result->{entries});
	}
	else
	{
		display_hash($dbg_lists+1,2,"$this->{WHO} textToList() returning $result");
	}
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
    my $err = $this->sendPacket($command);
    return $err if $err;

	my $packet;
	$err = $this->getPacketInstance(\$packet,1);
    return $err if $err;

	my $rslt = $this->textToList($packet);
	if (isValidInfo($rslt))
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
    my $err = $this->sendPacket($command);
    return $err if $err;

	my $packet;
	$err = $this->getPacketInstance(\$packet,1);
    return $err if $err;

	my $rslt = $this->textToList($packet);
	if (isValidInfo($rslt))
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
    my $err = $this->sendPacket($command);
    return $err if $err;

	my $packet;
	$err = $this->getPacketInstance(\$packet,1);
    return $err if $err;

	my $rslt = $this->textToList($packet);
	if (isValidInfo($rslt))
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
	my ($this,$pwas_progress,$packet,$progress) = @_;
	if ($packet =~ s/^$PROTOCOL_PROGRESS\t(.*?)\t//)
	{
		my $command = $1;
		$packet =~ s/\s+$//g;
		display($dbg_progress,-2,"handleProgress() PROGRESS($command) $packet");

		if ($progress)
		{
			my @params = split(/\t/,$packet);
			return $PROTOCOL_ABORTED
				if $command eq 'ADD' && !$progress->addDirsAndFiles($params[0],$params[1]);
			return $PROTOCOL_ABORTED
				if $command eq 'DONE' && !$progress->setDone($params[0]);
			return $PROTOCOL_ABORTED
				if $command eq 'ENTRY' && !$progress->setEntry($params[0]);
		}
		$$pwas_progress = 1;
	}
	else
	{
		$pwas_progress = 0;
	}

	return '';
}



sub _deleteRemote
{
	my ($this,
		$dir,				# MUST BE FULLY QUALIFIED
		$entries,
		$progress ) = @_;

	if ($dbg_commands <= 0)
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
			my $text = $info->toText();
			display($dbg_commands-1,1,"entry=$text");
			$command .= "$text\r" if $info;
		}
	}

	my $err = $this->sendPacket($command);
	return $err if $err;

	$this->incInProtocol();

	# so here we have the prototype of a progressy remote command
	# note that an abort or any errors currently leaves the client
	# remote listing unchanged

	my $retval = '';
	while (1)
	{
		my $packet;
		my $was_progress;
		$err = $this->getPacket(\$packet, 1);
		$err ||= $this->textError($packet);
		$err ||= $this->handleProgress(\$was_progress,$packet,$progress);
		if ($err)
		{
			$retval = $err;
			last;
		}
		if (!$was_progress)
		{
			$retval = $this->textToList($packet);
			last;
		}
	}

	$this->decInProtocol();
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
    return $dir_info if !isValidInfo($dir_info);
	return reportError("dir($dir) is not a directory in _listLocalDir")
		if !$dir_info->{is_dir};
	return reportError("$this->{WHO} could not opendir $dir")
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


sub _mkLocalDir
	# $dir must be fully qualified
	# must return defined value upon success
{
    my ($this, $dir, $subdir) = @_;
    display($dbg_commands,0,"$this->{WHO} _mkLocalDir($dir,$subdir)");
    my $path = makepath($dir,$subdir);
	return reportError("Could not mkdir $path") if !mkdir($path);
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

	return reportError("$this->{WHO} file/dir $path1 not found") if !(-e $path1);
	return reportError("$this->{WHO} file/dir $path2 already exists") if -e $path2;
	return reportError("$this->{WHO} Could not rename $path1 to $path2") if !rename($path1,$path2);
	return Pub::FS::FileInfo->new($this,$is_dir,$dir,$name2);
}


sub _deleteLocal			# RECURSES!!
	# recursions return '' or undef on success or
	# an error message on failure
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
		my $entry_info = $entries->{$entry};
		display($dbg_recurse,-4-$level,"entry=$entry is_dir=$entry_info->{is_dir}");
		if ($entry_info->{is_dir})
		{
			my $dir_path = makepath($dir,$entry);
			my $dir_entries = $entry_info->{entries};

			return reportError("_deleteLocal($level) could not opendir($dir_path)") if !opendir(DIR,$dir_path);
			while (my $dir_entry=readdir(DIR))
			{
				next if ($dir_entry =~ /^(\.|\.\.)$/);
				display($dbg_recurse,-4-$level,"dir_entry=$dir_entry");
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
		my $err = $this->_deleteLocal(
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

		display($dbg_recurse,-5-$level,"$this->{WHO} DELETE local file: $path");
		return reportError("$this->{WHO} Could not delete local file $path")
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

		display($dbg_recurse,-5-$level,"$this->{WHO} DELETE local dir: $dir");
		return reportError("$this->{WHO} Could not delete local file $dir")
			if !rmdir($dir);

		return $PROTOCOL_ABORTED if $progress && !$progress->setDone(1);

	}

	# level 0 returns a directory listing on success

	return $this->_listLocalDir($dir) if !$level;
	return '';
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
			return reportError("$this->{WHO} Could not delete single local file $path")
				if !unlink($path);
			return $this->_listLocalDir($param1);
		}
		return $this->_deleteLocal($param1,$param2,$progress);
	}

	# elsif ($command eq $PROTOCOL_XFER)			# $dir, $entries_or_filename, $target_dir, $progress
	# {
	# 	return $this->doXFER($local,$param1,$param2,$param3,$progress);
	# }

	# finished

	return reportError("$this->{WHO} unsupported command: $command");

}	# doCommand()


#----------------------------------------------------------------
# doXFER
#----------------------------------------------------------------
# Note that HANDLING a PUT is different than doing one.


my $BUFFER_SIZE = 10240;
	# The actual buffer will be 4 bytes longer to include the checksum,


sub doXFER
{
	my ($this,$local,$dir,$entries,$target_dir,$progress) = @_;
	$this->incInProtocol();

	my $retval = '';
	if (!ref($entries))
	{
		# $entries is a single_filename
		# guaranteed by caller to not be a directory

		$retval = $local ?
			$this->doPut($dir,$entries,$target_dir,$progress,1) :
			$this->doGet($dir,$entries,$target_dir,$progress,1);
	}

	$this->decInProtcol();
	return $retval;
}


sub doGet
{
	my ($this,$dir,$filename,$target_dir,$progress,$single) = @_;
	my $packet = "GET\t$dir\$filename"
}


sub doPut
	# CLIENT --> PUT \t dir \r FILE_ENTRY \r\n
{
	my ($this,$dir,$filename,$target_dir,$progress,$single) = @_;
	my $info = FS::FileInfo::new($this,0,$dir,$filename);
	return $info if !isValidInfo($info);
	my $size = $info->{size};

	# Create the file_info

	my $path = makepath($dir,$filename);
	my $file;
	return reportError("Could not open file $path for reading")
		if !open($file,"<$path");

	# $progress setXXX methods return $progress->aborted()

	return $PROTOCOL_ABORTED if $progress && !$progress->setEntry($dir);
	return $PROTOCOL_ABORTED if $progress && !$progress->setSubRange($size,$filename);

	# CLIENT --> PUT dir (FILE_ENTRY)

	my $packet = "PUT\t$target_dir\n".$info->toText();
	if ($this->sendPacket($packet))
	{
		# could not send the packet, local error has already been reported
		$file->close();
		return '';
	}

	#------------------------------------------------
	# send buffers
	#------------------------------------------------
	# CLIENT --> BASE64	offset bytes content

	my $offset = 0;
	while (1)
	{
		# CLIENT <-- CONTINUE
		# To allow zero sized files, CLIENT can return the fileinfo

		my $err = $this->getPacket(\$packet,1);
		if ($err || !$packet)
		{
			# could not get a packet, local error already reported
			$file->close();
			return '';
		}

		if ($packet !~ /^$PROTOCOL_CONTINUE/)
		{
			$file->close();

			# $packet may contain the terminating FILE_ENTRY for zero length files

			return FS::FileInfo->fromText($packet)
				if !$size && $packet !~ /^($PROTOCOL_ERROR|$PROTOCOL_ABORTED)/;

			# otherwise it likely contains a ERROR -

			return $packet;
		}


		# CLIENT --> BASE64	offset bytes content

		my $buffer;
		my $checksum = 0;
		my $bytes = $size - $offset;
		$bytes = $BUFFER_SIZE if $bytes > $BUFFER_SIZE;
		my $got = sysread($file,$buffer,$bytes,$offset);
		if ($got != $bytes)
		{
			$file->close();
			return reportError("Could not read $bytes bytes at offset $offset from $path; got $got bytes");
		}
		for (my $i=0; $i<$bytes; $i++)
		{
			$checksum += ord(substr($buffer,$i,1));
		}
		my $lsb_first = $checksum;
		for (my $i=0; $i<4; $i++)
		{
			$buffer .= chr($lsb_first && 0xff);
			$lsb_first >>= 8;
		}
		my $encoded = encode64($buffer);
		$packet = "BASE64\t$offset\t$bytes";
		if ($this->sendPacket($packet))
		{
			# could not send the packet, local error has already been reported
			$file->close();
			return '';
		}

		$offset += $bytes;
		last if $offset >= $size;
	}

	# expecting a FILE_ENTRY return, but in any
	# case we return whatever getPacket() returns

	$file->close();
	my $err = $this->getPacket(\$packet,1);
	return $err || $packet;
}
























1;
