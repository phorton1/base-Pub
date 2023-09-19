#!/usr/bin/perl -w
#-------------------------------------------------------------------
# Pub::FS::SessionRemote
#-------------------------------------------------------------------
# A SessionRemote is running in the context of a RemoteServer,
# which is actually running on the same machine as the Client.
#
# It generally receives socket requests from a SessionClient
# and forwards them as serial requests to a Serial Server, and
# returns the results from the Serial Server to the to the
# SessionClient.
#
# Anything that is purely local will be handled by the SessionClient
# and will never make its way to this Session.
#
# For purely remote requests, the Session Client will send the socket
# request to this object.  Since we know that
# these requests are NOT actually local requests,

# When the Client makes requests to ITS SessionClient, any requsts
# that are purely local will be handled directly by the base Session
# class, and will never get passed to this Session.
# those that are 'remote', it will, in turn, send the command
# out over the socket, where it will be received by THIS session.
#
# Since the base Session doCommand() method thinks IT is local,
# when we receive a command that


package Pub::FS::SessionRemote;
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
			setRemoteSessionConnected

			$in_remote_request
			$file_server_request
			@file_server_replies
		),
	    # forward base class exports
        @Pub::FS::Session::EXPORT,
	);
};


my $REMOTE_TIMEOUT = 15;
	# timeout, in seconds, to wait for a file_reply

our $remote_connected:shared = 0;

our $in_remote_request:shared = 0;
our $file_server_request:shared = '';
our @file_server_replies:shared = '';



sub new
{
    my ($class,$params) = @_;
    my $this = $class->SUPER::new($params);
	return if !$this;
	bless $this,$class;
	return $this;
}

sub setRemoteSessionConnected
{
	my ($connected) = @_;
	display($dbg_request,-1,"setRemoteSessionConnected($connected)");
	$remote_connected = $connected;
}


#========================================================================================
# Command Processor
#========================================================================================

sub waitReply
{
	my ($this) = @_;
	display($dbg_request+1,0,"waitReply()");
	if (!$remote_connected)
	{
		$this->session_error("remote not connected in doRemoteRequest()");
		return '';
	}

	my $started = time();
	while (!@file_server_replies)
	{
		if (!$remote_connected)
		{
			$this->session_error("remote not connected in doRemoteRequest()");
			return '';
		}
		if (time() > $started + $REMOTE_TIMEOUT)
		{
			$this->session_error("doRemoteRequest() timed out");
			return '';
		}
		display($dbg_request+2,0,"doRemoteRequest() waiting for reply ...");
		sleep(0.2);
	}

	my $packet = shift @file_server_replies;
	if (!$packet)
	{
		$this->session_error("empty reply doRemoteRequest()");
		return '';
	}

	$packet =~ s/\s+$//g;
	$this->sendPacket($packet);
	return $packet;
}



sub doRemoteRequest
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
			display($dbg_request,0,"doRemoteRequest(BASE64) len=".length($request));
		}
		else
		{
			my $show_request = $request;
			$show_request =~ s/\r/\r\n/g;
			display($dbg_request,0,"doRemoteRequest($show_request)");
		}
	}

	if ($in_remote_request)
	{
		warning(0,-1,"doRemoteRequest blocking while another operation in progress");
		while ($in_remote_request)
		{
			sleep(1);
		}
		warning(0,-2,"doRemoteRequest done waiting");
	}


	@file_server_replies = ();
	$file_server_request = $request;
	$in_remote_request = 1;

	my $packet = $this->waitReply();
	while ($packet && $packet =~ /^PROGRESS/)
	{
		$packet = $this->waitReply();
	}

	$in_remote_request = 0;
	my $retval = $packet ? 1 : 0;
	display($dbg_request,0,"doRemoteRequest() returning $retval");
	return $retval;
}



sub _listRemoteDir
{
    my ($this, $dir) = @_;
    display($dbg_commands,0,"_listRemoteDir($dir)");
	$this->doRemoteRequest("file_command:$SESSION_COMMAND_LIST\t$dir");
	return '';
}


sub _mkRemoteDir
{
    my ($this, $dir, $name) = @_;
    display($dbg_commands,0,"_mkRemoteDir($dir)");
	$this->doRemoteRequest("file_command:$SESSION_COMMAND_MKDIR\t$dir\t$name");
	return '';
}


sub _renameRemote
{
    my ($this, $dir, $name1, $name2) = @_;
    display($dbg_commands,0,"_renameRemote($dir)");
	$this->doRemoteRequestdoRemoteRequest("file_command:$SESSION_COMMAND_RENAME\t$dir\t$name1\t$name2");
	return '';
}


# deleteRemotePacket() is called specifically for this
# SessionRemote, because all we really want to do is send the
# packet and monitor replies.  We may to sit in a loop and
# monitor for PROGRESS MESSAGES PRH

sub deleteRemotePacket
{
	my ($this,
		$packet,				# MUST BE FULLY QUALIFIED
		$entries ) = @_;
	if ($dbg_commands <= 0)
	{
		my $show_packet = $packet;
		$show_packet =~ s/\r/\r\n/g;
		display($dbg_commands,0,"deleteRemotePacket($show_packet)");
	}
	$this->doRemoteRequest("file_command:$packet");
	return '';
}



1;
