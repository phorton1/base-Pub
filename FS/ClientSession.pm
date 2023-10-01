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
	$params->{IS_BRIDGED} ||= 0;
		# set by the pane if it gets a PORT on construction

	my $this = $class->SUPER::new($params);
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
        error("$this->{WHO} could not connect to PORT $port");
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

	my $ok = 1;
    my $err = $this->sendPacket($command);
    if ($err)
	{
		$ok = 0;
		$$ppacket = $err;
	}
	else
	{
		$err = $this->getPacketInstance($ppacket,1);
		if ($err)
		{
			$ok = 0;
			$$ppacket = $err;
		}
		elsif ($ppacket =~ /^($PROTOCOL_ERROR)/)
		{
			$ok = 0;
		}
	}
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
		# return OK or ERROR back as result of mkdir(may_exist)

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
# checkPacket() && _delete()
#--------------------------------------------------------

sub checkPacket
{
	my ($this,$ppacket) = @_;

	return $$ppacket if $$ppacket =~ /^($PROTOCOL_ERROR|$PROTOCOL_ABORTED|$PROTOCOL_OK)/;

	if ($$ppacket =~ /^($PROTOCOL_FILE|$PROTOCOL_BASE64|$PROTOCOL_MKDIR)/)
	{
		my ($command,$param1,$param2,$param3) = split(/\t/,$$ppacket);
		display($dbg_commands,-2,show_params("$this->{NAME} checkPacket",$command,$param1,$param2,$param3));

		my $other_session = $this->{other_session};
		my $rslt = $other_session->doCommand($command,$param1,$param2,$param3);

		my $err = $this->sendPacket($rslt,1);
		return $err if $err;
		$$ppacket = '';
	}
	elsif ($$ppacket =~ s/^$PROTOCOL_PROGRESS\t(.*?)\t//)
	{
		my $command = $1;
		$$ppacket =~ s/\s+$//g;
		display($dbg_commands,-2,"checkPacket() PROGRESS($command) $$ppacket");
		if ($this->{progress})
		{
			my @params = split(/\t/,$$ppacket);
			return $PROTOCOL_ABORTED if $command eq 'ADD' &&
				!$this->{progress}->addDirsAndFiles($params[0],$params[1]);
			return $PROTOCOL_ABORTED if $command eq 'DONE' &&
				!$this->{progress}->setDone($params[0]);
			return $PROTOCOL_ABORTED if $command eq 'ENTRY' &&
				!$this->{progress}->setEntry($params[0],$params[1]);
			return $PROTOCOL_ABORTED if $command eq 'BYTES' &&
				!$this->{progress}->setBytes($params[0]);
		}
		$$ppacket = '';
	}
	return '';
}


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

	my $err = $this->sendPacket($command);
	return $err if $err;

	$this->incInProtocol();

	# delete is an asynchronous socket command
	# that allows for progress messages

	my $retval = '';
	while (1)
	{
		my $packet;
		$err = $this->getPacket(\$packet,1);
		$err ||= $this->checkPacket(\$packet);
		if ($err)
		{
			$retval = $err;
			last;
		}
		if ($packet)
		{
			$retval = textToDirInfo($packet);
			last;
		}
	}

	$this->decInProtocol();
	return $retval;
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

	my $err = $this->sendPacket($command);
	return $err if $err;

	$this->incInProtocol();

	# delete is an asynchronous socket command
	# that allows for progress messages

	my $retval = '';
	while (1)
	{
		my $packet;
		$err = $this->getPacket(\$packet,1);
		$err ||= $this->checkPacket(\$packet);
		if ($err)
		{
			$retval = $err;
			last;
		}
		if ($packet)
		{
			$retval = textToDirInfo($packet);
			last;
		}
	}

	$this->decInProtocol();
	return $retval;
}


#------------------------------------------------------
# _file() && _base64()
#------------------------------------------------------
# If IS_BRIDGED the FILE and BASE64 commands are passed
# through the bridge, otherwise they are handled by
# the base class.


sub _file
{
	my ($this,
		$size,
		$ts,
		$full_name) = @_;

	my $rslt;
	if ($this->{IS_BRIDGED})
	{
		$this->sendCommandWithReply(\$rslt,
			"$PROTOCOL_FILE\t$size\t$ts\t$full_name");
	}
	else
	{
		$rslt = $this->SUPER::_file($this,$size,$ts,$full_name);
	}

	return $rslt;
}


sub _base64
	# it is not clear what this $progres parameter means
{
	my ($this,
		$offset,
		$bytes,
		$content) = @_;

	my $rslt;
	if ($this->{IS_BRIDGED})
	{
		$this->sendCommandWithReply(\$rslt,
			"$PROTOCOL_BASE64\t$offset\t$bytes\t$content");
	}
	else
	{
		$rslt = $this->SUPER::_base64($this,$offset,$bytes,$content);
	}

	return $rslt;
}




1;
