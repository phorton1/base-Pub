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
			%serial_file_reply_ready
		),
	    # forward base class exports
        @Pub::FS::SocketSession::EXPORT,
	);
};


my $REMOTE_TIMEOUT = 15;
	# timeout, in seconds, to wait for a file_reply

our $serial_file_request:shared = '';
our %serial_file_reply:shared;
our %serial_file_reply_ready:shared;

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

sub waitSerialReply
	# return  2 to continue
	# returns 1 on terminal reply
	# returns 0 on an error
{
	my ($this,$req_num) = @_;
	display($dbg_request+1,0,"waitSerialReply($req_num)");
	return $this->serialError("remote not connected in doSerialRequest()")
		if !$com_port_connected;

	my $abort = 0;
	my $packet;
	my $started = time();
	while (!$serial_file_reply_ready{$req_num})
	{
		# check for asynchronous 2nd ABORT packet and send 2nd
		# numbered serial file_command with ABORT message

		my $err = $this->getPacket(\$packet,0);
		return $err if $err;
		warning(0,0,"got packet=$packet") if $packet;
		if ($packet && $packet =~ /^$PROTOCOL_ABORT/)
		{
			my $request = "$PROTOCOL_ABORT";
			my $len = length($request);
			$serial_file_request = "file_message\t$req_num\t$len\t$request\n";
		}

		# waiting for numbered file_server reply continued

		return $this->serialError("remote not connected in doSerialRequest()")
			if !$com_port_connected;
		return $this->serialError("doSerialRequest() timed out")
			if time() > $started + $REMOTE_TIMEOUT;
		display($dbg_request+2,0,"doSerialRequest() waiting for reply ...");
		# sleep(1);	# 0.01);	# 0.2);
	}

	$packet = $serial_file_reply{$req_num};
	return $this->serialError("empty reply in doSerialRequest()")
		if !$packet;

	$packet =~ s/\s+$//g;
	my $err = $this->sendPacket($packet);
	return $err if $err;

	$serial_file_reply{$req_num} = '';
	$serial_file_reply_ready{$req_num} = 0;

	return $packet =~ /^$PROTOCOL_PROGRESS/ ? 2 : 1;
}



sub doSerialRequest
{
	my ($this,$request) = @_;
	if ($dbg_request <= 0)
	{
		if ($request =~ /BASE64/)
		{
			display($dbg_request,0,"doSerialRequest(BASE64) len=".length($request));
		}
		else
		{
			my $show_request = $request;
			$show_request =~ s/\r/\r\n/g;
			display($dbg_request,0,"doSerialRequest($show_request)");
		}
	}

	if ($serial_file_request)
	{
		warning(0,-1,"doSerialRequest blocking while another operation sending request");
		while ($serial_file_request)
		{
			sleep(1);
		}
		warning(0,-2,"doSerialRequest done waiting");
	}

	my $req_num = $request_number++;
	$request .= "\r" if $request !~ /\r$/;
	my $len = length($request);  # the \r is considerd part of the packet
	$request = "file_command\t$req_num\t$len\t$request\n";

	$serial_file_reply{$req_num} = '';
	$serial_file_reply_ready{$req_num} = 0;
	$serial_file_request = $request;

	my $retval = $this->waitSerialReply($req_num);
	while ($retval == 2)
	{
		$retval = $this->waitSerialReply($req_num)
	}

	delete $serial_file_reply{$req_num};
	delete $serial_file_reply_ready{$req_num};

	display($dbg_request,0,"doSerialRequest() returning $retval");
	return $retval;
}



1;
