#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::ClientSession
#-------------------------------------------------------
# A ClientSession is specifically running a SOCKET
# to a Server of some type.
#
# It overrides the atomoix _XXX methods called by the base
# Session to operate as client to the socket it connects to,
# using the PROTOCOL to communicate with it, and unlike the
# base class, it either returns valid FileInfo objects
# or a text error message (including $PROTOCOL_ABORTED).

package Pub::FS::ClientSession;
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Socket::INET;
use Pub::Utils;
use Pub::FS::FileInfo;
use Pub::FS::SocketSession;
use base qw(Pub::FS::SocketSession);


our $dbg_connect = 0;


BEGIN {
    use Exporter qw( import );
	our @EXPORT = (
		qw (),
	    # forward base class exports
        @Pub::FS::SocketSession::EXPORT,
	);
};



sub new
{
	my ($class, $params) = @_;
	$params ||= {};
	$params->{HOST} ||= $DEFAULT_HOST;
	$params->{PORT} ||= $DEFAULT_PORT;
	$params->{NAME} ||= "ClientSession";
	$params->{IS_CLIENT} = 1;

	my $this = $class->SUPER::new($params);
	$this->{SERVER_ID} = '';
	return if !$this;
	bless $this,$class;

	$this->connect();
		# will try to connect, but may return with !SOCK

	return $this;
}


sub isConnected
{
    my ($this) = @_;
    return $this->{SOCK} ? 1 : 0;
}


sub disconnect
{
    my ($this) = @_;
    display($dbg_connect,-1,"$this->{NAME} disconnect()");
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

	display($dbg_connect+1,-1,"$this->{NAME} connecting to $host:$port");

    $this->{SOCK} = IO::Socket::INET->new(
		PeerAddr => "$host:$port",
        PeerPort => "http($port)",
        Proto    => 'tcp',
		Timeout  => $DEFAULT_TIMEOUT );

    if (!$this->{SOCK})
    {
        error("$this->{NAME} could not connect to PORT $port");
    }
    else
    {
		my $rcv_buf_size = 10240;
		$this->{SOCK}->sockopt(SO_RCVBUF, $rcv_buf_size);
 		display($dbg_connect,-1,"$this->{NAME} CONNECTED to PORT $port");
		my $err = $this->sendPacket($PROTOCOL_HELLO);
		if (!$err)
		{
			my $packet;
			$err = $this->getPacket(\$packet,1);
	        $err = "$this->{NAME} unexpected response from server: $packet"
				if !$err && $packet !~ /^$PROTOCOL_WASSUP\t(.*)$/;
			$this->{SERVER_ID} = $1 if !$err;
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


#--------------------------------------------------------
# overriden atomic commands from base Session
#--------------------------------------------------------
# each _method does socket packet protocol

sub sendCommandWithReply
	# returns 1 if $packet is useful
	# otherwise caller should short retun the packet
{
	my ($this,$ppacket,$command) = @_;
	$$ppacket = '';

	$this->incInProtocol();
	my $ok = 1;
    my $err = $this->sendPacket($command);
    if ($err)
	{
		$ok = 0;
		$$ppacket = $err;
	}
	else
	{
		$err = $this->getPacket($ppacket,1);
		if ($err)
		{
			$ok = 0;
			$$ppacket = $err;
		}
		elsif ($$ppacket =~ /^$PROTOCOL_ERROR/)
		{
			$ok = 0;
		}
	}
	$this->decInProtocol();
	return $ok;
}



sub _list
{
    my ($this, $dir) = @_;
    display($dbg_commands,0,"$this->{NAME} _list($dir)");

	my $packet;
    return $packet if !$this->sendCommandWithReply(\$packet,
		"$PROTOCOL_LIST\t$dir");

	my $rslt = textToDirInfo($packet);
	if (isValidInfo($rslt))
	{
		display_hash($dbg_commands+1,1,"$this->{NAME} _list($dir) returning",$rslt->{entries})
	}
	else
	{
		display($dbg_commands+1,1,"$this->{NAME} _list($dir}) returning $rslt");
	}
    return $rslt;
}


sub _mkdir
{
    my ($this,$path,$ts,$may_exist) = @_;
    $may_exist ||= 0;
	display($dbg_commands,0,"$this->{NAME} _mkdir($path,$ts,$may_exist)");

	my $packet;
	return $packet if !$this->sendCommandWithReply(\$packet,
		"$PROTOCOL_MKDIR\t$path\t$ts\t$may_exist");
	return $packet if $may_exist;

	my $rslt = textToDirInfo($packet);
	if (isValidInfo($rslt))
	{
		display_hash($dbg_commands+1,1,"$this->{NAME} _mkdir($path) returning ",$rslt->{entries})
	}
	else
	{
		display($dbg_commands+1,1,"$this->{NAME} _mkdir($path}) returning $rslt");
	}
    return $rslt;
}


sub _rename
{
    my ($this,$dir,$name1,$name2) = @_;
    display($dbg_commands,0,"$this->{NAME} _rename($dir,$name1,$name2)");

	my $packet;
    return $packet if !$this->sendCommandWithReply(\$packet,
		"$PROTOCOL_RENAME\t$dir\t$name1\t$name2");

	my $rslt = Pub::FS::FileInfo->fromText($packet);
	if (isValidInfo($rslt))
	{
		display_hash($dbg_commands+1,1,"$this->{NAME} _rename($dir) returning",$rslt);
	}
	else
	{
		display($dbg_commands+1,1,"$this->{NAME} _rename($dir} returning $rslt");
	}
    return $rslt;
}



#--------------------------------------------------------
# waitTerminalPacket for session-like commands
#--------------------------------------------------------
# This is the guts of the clientSession PROTOCOL

sub waitTerminalPacket
{
	my ($this,$is_command) = @_;

	my $is_put = $is_command eq $PROTOCOL_PUT ? 1 : 0;
	my $is_file = $is_command eq $PROTOCOL_FILE ? 1 : 0;
	my $is_delete = $is_command eq $PROTOCOL_DELETE ? 1 : 0;

	display($dbg_commands,0,"$this->{NAME} waitTerminalPacket($is_command)",
		0,$display_color_light_cyan);

	my $rslt;
	while (1)
	{
		my $packet;
		$rslt = $this->getPacket(\$packet,1);
		last if $rslt;
		$rslt = $packet;

		# overuse $packet as a temporary dbg variable for display

		$packet = "BASE64 total_length=".length($packet)
			if $packet =~ /^$PROTOCOL_BASE64/;
		$packet =~ s/\s$//g;
		$packet =~ s/\r/\r\n/g;
		display($dbg_commands,1,"$this->{NAME} waitTerminalPacket($is_command) got ".dbgPacket($dbg_commands,$packet));

		# PROGRESS packets always call methods and continue

		if ($rslt =~ s/^$PROTOCOL_PROGRESS\t(.*?)\t//)
		{
			my $command = $1;
			$rslt =~ s/\s+$//g;
			display($dbg_commands,-2,"checkPacket() PROGRESS($command) $rslt");
			if ($this->{progress})
			{
				my @params = split(/\t/,$rslt);
				return $PROTOCOL_ABORTED if $command eq 'ADD' &&
					!$this->{progress}->addDirsAndFiles($params[0],$params[1]);
				return $PROTOCOL_ABORTED if $command eq 'DONE' &&
					!$this->{progress}->setDone($params[0]);
				return $PROTOCOL_ABORTED if $command eq 'ENTRY' &&
					!$this->{progress}->setEntry($params[0],$params[1]);
				return $PROTOCOL_ABORTED if $command eq 'BYTES' &&
					!$this->{progress}->setBytes($params[0]);
			}
			next;
		}

		# terminal conditions by command type

		last if $is_delete;
			# PROGRESS is the only continuation for DELETE
		last if $is_put && $rslt =~ /^($PROTOCOL_OK|$PROTOCOL_ERROR|$PROTOCOL_ABORTED)/;
			# end of PUT protocol
		last if $is_file && $rslt =~ /^($PROTOCOL_OK|$PROTOCOL_CONTINUE|$PROTOCOL_ERROR|$PROTOCOL_ABORTED)/;
			# end of PUT protocol

		# process sub-commands from the socket thru
		# the other session's doCommand() method

		if ($rslt =~ /^($PROTOCOL_FILE|$PROTOCOL_BASE64|$PROTOCOL_MKDIR)/)
		{
			my ($command,$param1,$param2,$param3) = split(/\t/,$rslt);
			my $other_session = $this->{other_session};
			my $other_rslt = $other_session->doCommand($command,$param1,$param2,$param3);

			my $err = $this->sendPacket($other_rslt);
			return $err if $err;
		}

		# send any other packets to the other session
		# and terminate the loop except on PUT or FILE CONTINUE

		else
		{
			my $err = $this->sendPacket($rslt);
			return $err if $err;

			next if $is_put;
			next if $is_file && $rslt =~ /^$PROTOCOL_CONTINUE/;
			last;
		}
	}

	display($dbg_commands,0,"$this->{NAME} waitTerminalPacket($is_command) returning ".dbgPacket($dbg_commands,$rslt),
		0,$display_color_light_cyan);
	return $rslt;
}



#---------------------------------------------
# _delete()
#---------------------------------------------

sub _delete
{
	my ($this,
		$dir,				# MUST BE FULLY QUALIFIED
		$entries) = @_;		# single_filename or valid hash of sub-entries

	display($dbg_commands,0,"$this->{NAME} _delete($dir,$entries)");

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
			display($dbg_commands+1,1,"entry=$text");
			$command .= "$text\r";
		}
	}

	$this->incInProtocol();
	my $rslt = $this->sendPacket($command);
	$rslt ||= $this->waitTerminalPacket($PROTOCOL_DELETE);

	$rslt = textToDirInfo($rslt)
		if $rslt !~ /^($PROTOCOL_ERROR|$PROTOCOL_ABORT)/;
	$this->decInProtocol();
	return $rslt;
}


#---------------------------------------------
# _put()
#---------------------------------------------

sub _put
{
	my ($this,
		$dir,
		$target_dir,
		$entries) = @_;

	display($dbg_commands,0,"$this->{NAME} _put($dir,$target_dir,$entries)");

    my $command = "$PROTOCOL_PUT\t$dir\t$target_dir";

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
			display($dbg_commands+1,1,"entry=$text");
			$command .= "$text\r";
		}
	}

	$this->incInProtocol();
	my $rslt = $this->sendPacket($command);
	$rslt ||= $this->waitTerminalPacket($PROTOCOL_PUT);
	$this->decInProtocol();
	return $rslt;
}


#------------------------------------------------------
# _file() && _base64()
#------------------------------------------------------

sub _file
{
	my ($this,
		$size,
		$ts,
		$full_name) = @_;

    display($dbg_commands,0,"$this->{NAME} _file($size,$ts,$full_name)");

    my $command = "$PROTOCOL_FILE\t$size\t$ts\t$full_name";

	$this->incInProtocol();
	my $rslt = $this->sendPacket($command);
	$rslt ||= $this->waitTerminalPacket($PROTOCOL_FILE);
	$this->decInProtocol();
	return $rslt;
}


sub _base64
	# it is not clear what this $progres parameter means
{
	my ($this,
		$offset,
		$bytes,
		$content) = @_;

    display($dbg_commands,0,"$this->{NAME} _base64($offset,$bytes,".length($content)." encoded bytes)");

	my $packet;
    $this->sendCommandWithReply(\$packet,
		"$PROTOCOL_BASE64\t$offset\t$bytes\t$content");
	return $packet;
}



1;
