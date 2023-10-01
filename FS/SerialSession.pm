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


my $REMOTE_TIMEOUT = 15;
	# timeout, in seconds, to wait for a file_reply

our $serial_file_request:shared = '';
our %serial_file_reply:shared;

my $com_port_connected:shared = 0;
my $request_number:shared = 1;


sub new
{
    my ($class,$params) = @_;
	$params ||= {};
	$params->{NAME} ||= 'SerialSession';
    my $this = $class->SUPER::new($params);
	return if !$this;
	bless $this,$class;
	return $this;
}

sub setComPortConnected
{
	my ($connected) = @_;
	display($dbg_request+1,-1,"SerialSession::com_port_connected=$connected");
	$com_port_connected = $connected;
}

sub serialError
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
#     	  LIST, MKDIR, RENAME, DELETE, PUT, FILE, BASE64, or MKDIR-may_exist
#     doSerialRequest() has no return value.  It orchestrates
#         the entire command session by directly calling sendPacket()
#         as needed to communicate stuff back to th client as needed.
#
# doSerialRequest then checks if the COM port is open, and
#     sends an ERROR packet and returns if if it not.
# doSerialRequest then sends the serial_file_command
#     and calls waitSerialReply(), the workhorse method.
#
# Any failures to send a packet() are fatal, report a local
#     error and return immediately.
#
# waitSerialReply() loops waiting for a serial_reply with a
#     TIMEOUT that causes it to send an ERROR packet to the
#     client and exit if there's no reply in a reasonable
#     amount of time.
#
# In the simple cases of LIST, MKDIR, and RENAME, only a single
#     serial_reply is expected (and no further packets from the socket
#     are expected), so waitSerialReply() any serial reply it gets
#     is sent back to the client as a packet, and waitSerialReply
#     returns.
#
# For DELETE, the SerialServer (teensy) may send PROGRESS serial_replies,
#     and, as well, the client may asynchronously send ABORT packets.
#
#     So, while waiting for the 'terminal serial_reply' from the
#     SerialServer that is executing the DELETE command, it
#     knows that any PROGRESS messages are NOT terminal messages,
#     and continues looping.
#
#     At the same time, it polls the client with getPacket(),
#     and if it gets an ABORT packet from the client, it sends
#     a same-req-num 'file_message' to the SerialServer (teensy)
#     with the ABORT.  If the teensy gets the file_message in
#     in time, it will return a serial_reply of ABORTED, or if
#     not, it will return a DIR_LIST or an ERROR when the DELETE
#     is done.
#
# The next simplest session-like commands are FILE, BASE64, and
#     MKDIR-may_exist sent from the cient via packets as it itself
#     doing a PUT command.  These are almost the same as DELETE,
#     in that the teensy may return PROGRESS messages, and/or
#     the client may send ABORT packets. The slight difference
#     is that the teensy may return 'terminal' CONTINUE and OK
#     serial_replies in addition to the usual ERROR or ABORTED
#     serial_replies.
#
# The final case is when the client issues a session-like PUT
#     command to the teensy.  In this case, the serial_replies
#     of FILE, BASE64, and MKDIR-may_exist are sent to the client,
#     causing it to recurse and execute the FILE, BASE64, and MKDIR
#     commands, and we forward any OK, CONTINUE, ABORTED, or ERROR
#     packets as serial_messags to the teensy until finally the
#     teensy sends a terminal OK, ABORTED, or ERROR.
#
# NOTE: as of now PUT must issue a terminal OK, ABORTED, or ERROR
#     message.


my $TERMINAL_REPLY = "1";


sub sendFileMessage
{
	my ($req_num,$packet) = @_;
	$packet =~ s/\s+$//g;
	$packet .= "\r";
	my $len = length($packet);
	while ($serial_file_request)
	{
		warning($dbg_request+2,-1,"waiting for !serial_file_request");
		sleep(0.01);
	}
	display($dbg_request,-4,"forwarding file_message len($len)");
	$serial_file_request = "file_message\t$req_num\t$len\t$packet\n";
}



sub waitSerialReply
	# remember that getPacket and sendPacket return errors or ''
{
	my ($this,$req_num,$command) = @_;
	warning($dbg_request,-2,"waitSerialReply($req_num,$command)");

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
			$this->serialError("remote not connected in waitSerialReply($req_num,$command)");
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
			return if $this->sendPacket($serial_reply,1);
		}

		sendFileMessage($req_num,$client_packet)
			if ($client_packet);

		last if $serial_reply && !$is_delete && !$is_put && !$is_file;
			# simple commands always return on a serial reply
		last if $serial_reply =~ /^($PROTOCOL_ERROR|$PROTOCOL_ABORTED)/;
			# all commands terminate on ERROR or ABORTED
		last if $is_put && $client_packet =~ /^($PROTOCOL_ERROR|$PROTOCOL_ABORT)/;
			# teensy PUT protocol bails on any errors or aborts
		last if ($is_put || $is_file) && $serial_reply =~ /^$PROTOCOL_OK/;
			# finish of teensy PUT protocol

		next if $serial_reply =~ /^$PROTOCOL_PROGRESS/;
		next if $client_packet =~ /^$PROTOCOL_PROGRESS/;
			# PROGRESS from either  are always continued

		next if $is_file && $serial_reply =~ /^$PROTOCOL_CONTINUE/;
			# FILE command subsession CONTNUES
		last if $serial_reply && $is_delete;
			# and PROGRESS is the only continuation for DELETE

	}	# while (1)

	warning($dbg_request,-2,"waitSerialReply($req_num,$command) finished");
}



sub doSerialRequest
{
	my ($this,$request) = @_;
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
			sleep(1);
		}
		warning($dbg_request,-2,"doSerialRequest done waiting");
	}

	$request =~ s/\s+$//g;
	$request =~ /^(.+)(\t|$)/;
	my ($command) = split(/\t/,$request);

	$request .= "\r";
	my $len = length($request);  # the \r is considerd part of the packet
	$request = "file_command\t$req_num\t$len\t$request\n";

	$serial_file_reply{$req_num} = '';
	$serial_file_request = $request;

	$this->waitSerialReply($req_num,$command);

	delete $serial_file_reply{$req_num};
	display($dbg_request,-1,"doSerialRequest($req_num) finished");

}



1;
