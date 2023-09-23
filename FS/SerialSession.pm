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
# For XFER requests it receives from the ClientSession, it will
# work with the remote SerialServer to actually do the XFER,
# and will merely return PROGESS messages and the final result
# back to the ClientSession, thus minimize traffic over the socket.

package Pub::FS::SerialSession;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::Hires qw(sleep);
use Pub::Utils;
use Pub::FS::FileInfo;
use Pub::FS::Session;
use base qw(Pub::FS::Session);

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
        @Pub::FS::Session::EXPORT,
	);
};


my $REMOTE_TIMEOUT = 15;
	# timeout, in seconds, to wait for a file_reply

my $com_port_connected:shared = 0;


my $request_number:shared = 0;
our $serial_file_request:shared = '';
our %serial_file_reply:shared;
our %serial_file_reply_ready:shared;




sub new
{
    my ($class,$params) = @_;
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


#========================================================================================
# Command Processor
#========================================================================================

sub waitReply
{
	my ($this,$req_num) = @_;
	display($dbg_request+1,0,"waitReply($req_num)");
	if (!$com_port_connected)
	{
		return $this->session_error("remote not connected in doSerialRequest()");
	}

	my $abort = 0;
	my $started = time();
	while (!$serial_file_reply_ready{$req_num})
	{
		# check for asynchronous 2nd ABORT packet and send 2nd
		# numbered serial file_command with ABORT message

		my $packet2 = $this->getPacket(0);
		if ($packet2 && $packet2 =~ /^$PROTOCOL_ABORT/)
		{
			my $request = "$req_num\t$PROTOCOL_ABORT";
			my $len = length($request);
			$serial_file_request = "file_command\t$len\t$request\n";
		}

		# waiting for numbered file_server reply continued

		if (!$com_port_connected)
		{
			return $this->session_error("remote not connected in doSerialRequest()");
		}
		if (time() > $started + $REMOTE_TIMEOUT)
		{
			return $this->session_error("doSerialRequest() timed out");
		}
		display($dbg_request+2,0,"doSerialRequest() waiting for reply ...");
		sleep(0.2);
	}

	my $packet = $serial_file_reply{$req_num};
	if (!$packet)
	{
		return $this->session_error("empty reply doSerialRequest()");
	}

	$packet =~ s/\s+$//g;
	$this->sendPacket($packet);
	$serial_file_reply{$req_num} = '';
	$serial_file_reply_ready{$req_num} = 0;

	return $packet;
}



sub doSerialRequest
	# weirdly, these want to be thread specific as it is easy
	# to imagine being in the middle of one when another one happens.
	# The C++ side is safe cuz it can only do one at a time, but
	# there are thread re-entrancy issues here.  What we will do,
	# instead, is have another timer loop while $in_remote_server.
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
	$request = "$req_num\t$request";
	my $len = length($request);
	$request = "file_command\t$len\t$request\n";

	$serial_file_reply{$req_num} = '';
	$serial_file_reply_ready{$req_num} = 0;
	$serial_file_request = $request;

	my $packet = $this->waitReply($req_num);
	while ($packet && $packet =~ /^PROGRESS/)
	{
		$packet = $this->waitReply($req_num);
	}


	delete $serial_file_reply_ready{$req_num};
	delete $serial_file_reply{$req_num};

	my $retval = $packet ? 1 : 0;
	display($dbg_request,0,"doSerialRequest() returning $retval");
	return $retval;
}



1;
