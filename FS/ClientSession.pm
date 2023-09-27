#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::ClientSession
#-------------------------------------------------------
# A ClientSession is specifically running a SOCKET
# to a Server of some type.
#
# This object shouldl likely be moved to FC:: and
# encapsulate the threadedDoCommand.
#
# It completely overrides doCommand() to operate as
# client to the socket it connects to, using the
# PROTOCOL to communicate with it, and unlike the
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
	$params->{RETURN_ERRORS} ||= 1;
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
# remote atomic commands
#--------------------------------------------------------

sub _list
{
    my ($this, $dir) = @_;
    display($dbg_commands,0,"$this->{NAME} _list($dir)");

    my $command = "$PROTOCOL_LIST\t$dir";
    my $err = $this->sendPacket($command);
    return $err if $err;

	my $packet;
	$err = $this->getPacketInstance(\$packet,1);
    return $err if $err;

	return $packet if $packet =~ /^($PROTOCOL_ERROR)/;

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
    my ($this,$dir,$subdir) = @_;
    display($dbg_commands,0,"$this->{NAME} _mkdir($dir,$subdir)");

    my $command = "$PROTOCOL_MKDIR\t$dir\t$subdir";
    my $err = $this->sendPacket($command);
    return $err if $err;

	my $packet;
	$err = $this->getPacketInstance(\$packet,1);
    return $err if $err;

	return $packet if $packet =~ /^($PROTOCOL_ERROR)/;

	my $rslt = textToDirInfo($packet);
	if (isValidInfo($rslt))
	{
		display_hash($dbg_commands+1,1,"$this->{NAME} _mkdir($dir) returning ",$rslt->{entries})
	}
	else
	{
		display($dbg_commands+1,1,"$this->{NAME} _mkdir($dir}) returning $rslt");
	}
    return $rslt;
}


sub _rename
{
    my ($this,$dir,$name1,$name2) = @_;
    display($dbg_commands,0,"$this->{NAME} _rename($dir,$name1,$name2)");

    my $command = "$PROTOCOL_RENAME\t$dir\t$name1\t$name2";
    my $err = $this->sendPacket($command);
    return $err if $err;

	my $packet;
	$err = $this->getPacketInstance(\$packet,1);
    return $err if $err;

	return $packet if $packet =~ /^($PROTOCOL_ERROR)/;

	my $rslt = Pub::FS::FileInfo->fromText($packet);
	if (isValidInfo($rslt))
	{
		display_hash($dbg_commands+1,1,"$this->{NAME} _rename($dir) returning $rslt=".$rslt->toText())
	}
	else
	{
		display($dbg_commands+1,1,"$this->{NAME} _rename($dir}) returning $rslt");
	}
    return $rslt;
}



sub checkPacket
{
	my ($this,$ppacket,$progress) = @_;

	return $$ppacket if $$ppacket =~ /^($PROTOCOL_ERROR|$PROTOCOL_ABORTED)/;

	if ($$ppacket =~ s/^$PROTOCOL_PROGRESS\t(.*?)\t//)
	{
		my $command = $1;
		$$ppacket =~ s/\s+$//g;
		display($dbg_progress,-2,"handleProgress() PROGRESS($command) $$ppacket");
		if ($progress)
		{
			my @params = split(/\t/,$$ppacket);
			return $PROTOCOL_ABORTED
				if $command eq 'ADD' && !$progress->addDirsAndFiles($params[0],$params[1]);
			return $PROTOCOL_ABORTED
				if $command eq 'DONE' && !$progress->setDone($params[0]);
			return $PROTOCOL_ABORTED
				if $command eq 'ENTRY' && !$progress->setEntry($params[0]);
		}
		$$ppacket = '';
	}
	return '';
}



sub _delete
{
	my ($this,
		$dir,				# MUST BE FULLY QUALIFIED
		$entries,			# single_filename or valid hash of sub-entries
		$progress ) = @_;

	if ($dbg_commands <= 0)
	{
		my $show_entries = ref($entries) ? '' : $entries;
		display($dbg_commands,0,"$this->{NAME} _delete($dir,$show_entries)");
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
			display($dbg_commands+1,1,"entry=$text");
			$command .= "$text\r";
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
		$err = $this->getPacket(\$packet, 1);
		$err ||= $this->checkPacket(\$packet,$progress);
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
# doCommand
#------------------------------------------------------

# sub doCommand
# {
#     my ($this,
# 		$command,
#         $param1,
#         $param2,
#         $param3,
# 		$progress,
# 		$caller,
# 		$other_session) = @_;
#
# 	display($dbg_commands+1,0,"$this->{NAME} doCommand($command,$param1,$param2,$param3)");
# 		# ,".ref($progress).",$caller,".ref($other_session).") called");
#
# 	# For these calls param1 MUST BE A FULLY QUALIFIED DIR
#
# 	my $rslt;
# 	if ($command eq $PROTOCOL_LIST)					# $dir
# 	{
# 		$rslt = $this->_list($param1);
# 	}
# 	elsif ($command eq $PROTOCOL_MKDIR)				# $dir, $subdir
# 	{
# 		$rslt = $this->_mkdir($param1,$param2);
# 	}
# 	elsif ($command eq $PROTOCOL_RENAME)			# $dir, $old_name, $new_name
# 	{
# 		$rslt = $this->_rename($param1,$param2,$param3);
# 	}
#
# 	# unlike base class we pass all deletes over the socket
#
# 	elsif ($command eq $PROTOCOL_DELETE)			# $dir, $entries_or_filename, undef, $progress
# 	{
# 		$rslt = $this->_delete($param1,$param2,$progress);
# 	}
#
# 	# error if unsupported command
#
# 	else
# 	{
# 		$rslt = error("$this->{NAME} unsupported command: $command",0,1);
# 	}
#
# 	# finished, unlike base class we don't report the error
#
# 	$rslt ||= error("$this->{NAME} unexpected empty doCommand() rslt",0,1);
#
# 	display($dbg_commands+1,0,"$this->{NAME} doCommand($command) returning $rslt");
# 	return $rslt;
#
# }	# ClientSession::doCommand()
#
#
#


1;
