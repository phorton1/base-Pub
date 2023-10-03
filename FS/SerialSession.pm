#!/usr/bin/perl -w
#-------------------------------------------------------------------
# Pub::FS::SerialSession
#-------------------------------------------------------------------
# A SerialSession is running in the context of a SerialBridge,
# which is typically running on the same machine as the Client.
#
# It generally receives socket requests from a ClientSession
# and forwards them as serial requests to a SerialServer, and
# returns the results from the SerialServer to the to the
# ClientSession.
#
# Anything that is purely local will be handled by the base Session
# and will never make its way to this SerialSession.
#
# The identity (SERVER_ID) of the SerialServer is assumed
# to be persistent once it is established. The first client
# to successfully connect to the Serial Server will set the
# SERVER_ID and prevent subsequen login attempts.
#
# At this time, the fileClient from buddy dies if there is
# no Serial Server available during startup as there is
# no established SERVER_ID.


package Pub::FS::SerialSession;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::Hires qw(sleep);
use Pub::Utils;
use Pub::FS::FileInfo;
use Pub::FS::SocketSession;
use base qw(Pub::FS::SocketSession);

our $dbg_request:shared = 0;
	# 0 = command, lifetime, and file_reply: and file_reply_end in buddy
	# -1 = command sends in buddy
	# -2 = waiting for reply loop (0.2 secs)

BEGIN {
    use Exporter qw( import );
	our @EXPORT = (
		qw (
			$dbg_request

			$serial_file_request
			%serial_file_reply
		),
	    # forward base class exports
        @Pub::FS::SocketSession::EXPORT,
	);
};

my $CONNECT_TIMEOUT  = 2;
	# timeout for login attempt
my $REMOTE_TIMEOUT = 15;
	# timeout, in seconds, to wait for a file_reply

our $serial_file_request:shared = '';
our %serial_file_reply:shared;

my $com_port_connected:shared = 0;
my $request_number:shared = 1;

my $SERVER_ID:shared = '';

my $dbg_session_num:shared = 0;


sub new
{
    my ($class,$params) = @_;

	my $session_num = $dbg_session_num++;
	$params ||= {};
	$params->{NAME} ||= "SerialSession($session_num)";
	$params->{IS_BRIDGE} = 1;
    my $this = $class->SUPER::new($params);
	return if !$this;
	bless $this,$class;
	$this->connect() if !$SERVER_ID;
	$this->{SERVER_ID} = $SERVER_ID;
	return $this;
}

sub setComPortConnected
	# called by buddy when the COM port goes
	# on or offline.
{
	my ($connected) = @_;
	display($dbg_request+1,-1,"SerialSession::com_port_connected=$connected");
	$com_port_connected = $connected;
}



sub connect
	# The first session possible connects to the teensy
	# Serial Server to get it's SERVER_ID
{
	my ($this) = @_;
	if (!$com_port_connected)
	{
		error("$this->{NAME} remote not connected in connect()");
		return;
	}

	my $req_num = $request_number++;
	my $request = buildSerialRequest('file_command',$req_num,$PROTOCOL_HELLO);
	$serial_file_reply{$req_num} = '';
	$serial_file_request = $request;

    my $timer = time();
	while (!$serial_file_reply{$req_num})
	{
		if (time() - $timer > $CONNECT_TIMEOUT)
		{
			$this->sessionError("$this->{NAME} connect timeout");
			return 0;
		}
	}

	my $reply = $serial_file_reply{$req_num};
	if ($reply !~ /^$PROTOCOL_WASSUP\t(.*)$/)
	{
		$this->sessionError("$this->{NAME} unexpected response from server: $reply");
		return 0;
	}

	$SERVER_ID = $1;
	return 1;

}


sub serialError
	# report an error locall and send it as a packet
	# to the attached ClientSession.
{
	my ($this,$msg) = @_;
	error($msg,1);
	# no error checking
	$this->sendPacket($PROTOCOL_ERROR.$msg);
	return 0;	# stop the loop
}




#========================================================================================
# Command Processor
#========================================================================================
# doSerialRequest() is called from SerialBridge.pm when the Server
#     receives a packet from the socket that initiates a command session.
#     	  LIST, MKDIR, RENAME, DELETE, PUT, FILE, and BASE64
#     doSerialRequest() has no return value.  It orchestrates
#         the entire command session by directly calling sendPacket()
#         as needed to communicate stuff back to th client as needed.


sub buildSerialRequest
{
	my ($kind,$req_num,$packet) = @_;
	$packet =~ s/\s+$//g;
	$packet .= "\r";
	my $len = length($packet);
	return "$kind\t$req_num\t$len\t$packet\n";
}

sub sessionError
{
	my ($this,$msg) = @_;
	error($msg,1);
	$this->sendPacket($PROTOCOL_ERROR.$msg);
}


sub sendFileMessage
	# sends out-of-band "file_messages" that go to the same
	# teensy fileCommand(req_num) that is already running.
{
	my ($req_num,$packet) = @_;
	my $request = buildSerialRequest('file_message',$req_num,$packet);
	if ($serial_file_request)
	{
		warning($dbg_request,-2,"sendFileMessage blocking while another operation sending request");
		while ($serial_file_request)
		{
			sleep(0.01);
		}
		warning($dbg_request,-2,"sendFileMessage done waiting");
	}
	display($dbg_request,-4,"forwarding file_message packet_len(".length($packet)." total_len(".length($request).")");
	$serial_file_request = $request;
}



sub waitSerialReply
	# This is the workhorse of the Serial PROTOCOL
	# remember that getPacket and sendPacket return errors or ''
{
	my ($this,$req_num,$command) = @_;
	warning($dbg_request,-2,"waitSerialReply($req_num,$command)");

    my $timer = time();
	my $is_put =    $command eq $PROTOCOL_PUT;
	my $is_delete = $command eq $PROTOCOL_DELETE;
	my $is_file   = $command eq $PROTOCOL_FILE;

 	while (1)
	{
		my $client_packet = '';
		return if $this->getPacket(\$client_packet,0);
		my $show_packet = $client_packet =~ /^$PROTOCOL_BASE64/ ?
			"BASE64 full packet length(".length($client_packet).")" :
			$client_packet;
		$show_packet =~ s/\r/\r\n/g;
		display($dbg_request+1,-3,"waitSerialReply($req_num,$command) got packet=$show_packet") if $client_packet;

		if (!$com_port_connected)
		{
			$this->sessionError("remote not connected in waitSerialReply($req_num,$command)");
			return;
		}

		my $serial_reply = '';
		if ($serial_file_reply{$req_num})
		{
			$serial_reply = $serial_file_reply{$req_num};
			$serial_file_reply{$req_num} = '';
			my $show_reply = $serial_reply =~ /^$PROTOCOL_BASE64/ ?
				"BASE64 full packet length(".length($serial_reply).")" :
				$serial_reply;
			$show_reply =~ s/\r/\r\n/g;
			display($dbg_request+1,-3,"waitSerialReply($req_num,$command) got serial_reply=$show_reply") if $show_reply;
			return if $this->sendPacket($serial_reply);
			$timer = time();
		}

		sendFileMessage($req_num,$client_packet)
			if ($client_packet);

		last if $serial_reply && !$is_delete && !$is_put && !$is_file;
			# simple commands always return on a serial reply
		last if $serial_reply =~ /^($PROTOCOL_ERROR|$PROTOCOL_ABORTED)/;
			# all commands terminate on ERROR or ABORTED
		last if $is_put && $client_packet =~ /^($PROTOCOL_ERROR|$PROTOCOL_ABORT)/;
			# teensy PUT protocol bails on any errors or aborts, so we do too
		last if ($is_put || $is_file) && $serial_reply =~ /^$PROTOCOL_OK/;
			# finish of teensy PUT protocol

		next if $serial_reply =~ /^$PROTOCOL_PROGRESS/;
		next if $client_packet =~ /^$PROTOCOL_PROGRESS/;
			# PROGRESS from either  are always continued

		next if $is_file && $serial_reply =~ /^$PROTOCOL_CONTINUE/;
			# FILE command subsession CONTNUES
		last if $serial_reply && $is_delete;
			# PROGRESS is the only continuation for DELETE

		if (time() - $timer > $REMOTE_TIMEOUT)
		{
			$this->sessionError("waitSerialReply($req_num,$command) timeout");
			last;
		}

	}	# while (1)

	warning($dbg_request,-2,"waitSerialReply($req_num,$command) finished");
}



sub doSerialRequest
	# Send a file_command to start a new teesny fileCommand(req_num),
	# and call waitSerialReply() to do the guts of the work
{
	my ($this,$request) = @_;

	if (!$com_port_connected)
	{
		$this->sessionError("$this->{NAME} remote not connected in doSerialRequest()");
		return;
	}

	my $req_num = $request_number++;
	if ($dbg_request <= 0)
	{
		if ($request =~ /BASE64/)
		{
			display($dbg_request,-1,"doSerialRequest($req_num) BASE64) len=".length($request));
		}
		else
		{
			my $show_request = $request;
			$show_request =~ s/\r/\r\n/g;
			display($dbg_request,-1,"doSerialRequest($req_num) ($show_request)");
		}
	}

	if ($serial_file_request)
	{
		warning($dbg_request,-2,"doSerialRequest blocking while another operation sending request");
		while ($serial_file_request)
		{
			sleep(0.01);
		}
		warning($dbg_request,-2,"doSerialRequest done waiting");
	}

	$request =~ s/\s+$//g;
	$request =~ /^(.+)(\t|$)/;
	my ($command) = split(/\t/,$request);

	my $serial_request = buildSerialRequest('file_command',$req_num,$request);

	$serial_file_reply{$req_num} = '';
	$serial_file_request = $serial_request;

	$this->waitSerialReply($req_num,$command);

	delete $serial_file_reply{$req_num};
	display($dbg_request,-1,"doSerialRequest($req_num) finished");

}




1;
