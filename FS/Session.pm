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
our $dbg_packets:shared = 1;
our $dbg_lists:shared = 1;
	# 0 = show lists encountered
	# -1 = show teztToList final hash
our $dbg_commands:shared = 0;
	# 0 = show atomic commands
	# -1 = show command header
	# -2 = show command details


BEGIN {
    use Exporter qw( import );
	our @EXPORT = qw (

		$dbg_session
		$dbg_packets
		$dbg_lists
		$dbg_commands

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
	# if no SOCK parameter is provided,
	# will try to connect to HOST:PORT
{
	my ($class, $params) = @_;
	$params ||= {};
	my $this = { %$params };
	bless $this,$class;
	return if !$this->{SOCK} && !$this->connect();
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
        $this->send_packet($msg);
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
    display($dbg_session,0,"DISCONNECT");
    if ($this->{SOCK})
    {
        $this->send_packet('EXIT');
        close $this->{SOCK};
    }
    $this->{SOCK} = undef;
}



sub connect
{
    my ($this) = @_;

	$this->{HOST} ||= $DEFAULT_HOST;
	$this->{PORT} ||= $DEFAULT_PORT;
	my $host = $this->{HOST};
    my $port = $this->{PORT};

	display($dbg_session+1,0,"connecting to $host:$port");

    my @psock = (
        PeerAddr => "$host:$port",
        PeerPort => "http($port)",
        Proto    => 'tcp' );
    my $sock = IO::Socket::INET->new(@psock);

    if (!$sock)
    {
        $this->session_error("Could not connect to PORT $port");
    }
    else
    {
 		display($dbg_session,0,"CONNECTED to PORT $port");
        $this->{SOCK} = $sock;

        return if !$this->send_packet("HELLO");
        return if !defined(my $line = $this->get_packet());

        if ($line !~ /^WASSUP/)
        {
            $this->session_error("Unexpected response from server: $line");
            return;
        }
    }

    return $sock ? 1 : 0;
}



#--------------------------------------------------
# packets
#--------------------------------------------------


sub send_packet
{
    my ($this,$packet) = @_;


	print "send_packet ".length($packet)." bytes\n";

    my $sock = $this->{SOCK};
    if (!$sock)
    {
        $this->session_error("no socket in send_packet");
        return;
    }

    if (length($packet) > 100)
    {
        display($dbg_packets,0,"--> ".length($packet)." bytes");
    }
    else
    {
        display($dbg_packets,0,"--> $packet");
    }

    if (!$sock->send($packet."\r\n"))
    {
        $this->{SOCK} = undef;
        $this->session_error("Could not write to socket $sock");
        return;
    }

	$sock->flush();
    return 1;
}



sub get_packet
{
    my ($this) = @_;
    my $sock = $this->{SOCK};
    if (!$sock)
    {
        $this->session_error("no socket in get_packet");
        return;
    }

	my $CRLF = "\015\012";
	local $/ = $CRLF;

    my $packet = <$sock>;
    if (!defined($packet))
    {
        $this->{SOCK} = undef;
        $this->session_error("No response from peer");
        return;
    }

    $packet =~ s/(\r|\n)$//g;

    if (!$packet)
    {
        $this->session_error("Empty response from peer");
        return;
    }

    if (length($packet) > 100)
    {
        display($dbg_packets,0,"<-- ".length($packet)." bytes");
    }
    else
    {
        display($dbg_packets,0,"<-- $packet");
    }

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
    display($dbg_lists,0,"listToText($list->{entry}) ".
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
    display($dbg_lists,0,"textToList() lines=".scalar(@lines));

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

	display_hash($dbg_lists+1,2,"textToList($result->{entry})",$result->{entries});
    return $result;
}



#------------------------------------------------------
# commands
#------------------------------------------------------



sub doCommand
{
    my ($this,
		$command,
        $local,
        $param1,
        $param2,
        $param3) = @_;

	$command ||= '';
	$local ||= 0;
	$param1 ||= '';
	$param2 ||= '';
	$param3 ||= '';

	display($dbg_commands+1,0,"doCommand($command,$local,$param1,$param2,$param3)");

	if ($command eq $SESSION_COMMAND_LIST)
	{
		return $local ?
			$this->_listLocalDir($param1) :
			$this->_listRemoteDir($param1);
	}
	elsif ($command eq $SESSION_COMMAND_MKDIR)
	{
		return $local ?
			$this->_mkLocalDir($param1,$param2) :
			$this->_mkRemoteDir($param1,$param2);
	}
	elsif ($command eq $SESSION_COMMAND_RENAME)
	{
		return $local ?
			$this->_renameLocal($param1,$param2,$param3) :
			$this->_renameRemote($param1,$param2,$param3);
	}
	$this->session_error("unsupported command: $command");
	return;
}




sub _listLocalDir
{
    my ($this, $dir) = @_;
    display($dbg_commands,0,"_listLocalDir($dir)");

    my $dir_info = Pub::FS::FileInfo->new($this,1,$dir);
    return if (!$dir_info);

    if (!opendir(DIR,$dir))
    {
        $this->session_error("could not opendir $dir");
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
{
    my ($this, $dir, $subdir) = @_;
    display($dbg_commands,0,"_mkLocalDir($dir,$subdir)");
    my $path = makepath($dir,$subdir);
	if (!mkdir($path))
	{
		$this->session_error("Could not mkdir $path");
		return;
	}
	return Pub::FS::FileInfo->new($this,1,$dir,$subdir);
}


sub _renameLocal
{
    my ($this, $dir, $name1, $name2) = @_;
    display($dbg_commands,0,"_renameLocal($dir,$name1,$name2)");
    my $path1 = makepath($dir,$name1);
    my $path2 = makepath($dir,$name2);

	my $is_dir = -d $path1;

	if (!-e $path1)
	{
		$this->session_error("file/dir $path1 not found");
		return;
	}
	if (-e $path2)
	{
		$this->session_error("file/dir $path2 already exists");
		return;
	}
	if (!rename($path1,$path2))
	{
		$this->session_error("Could not rename $path1 to $path2");
		return;
	}

	return Pub::FS::FileInfo->new($this,$is_dir,$dir,$name2);
}



1;
