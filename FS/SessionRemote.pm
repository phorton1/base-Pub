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

my $REMOTE_TIMEOUT = 15;
	# timeout, in seconds, to wait for a file_reply

BEGIN {
    use Exporter qw( import );
	our @EXPORT = (
		qw (
			$dbg_request
			setRemoteSessionConnected
			$file_server_request
			$file_server_reply
			$file_reply_pending
		),
	    # forward base class exports
        @Pub::FS::Session::EXPORT,
	);
};


our $remote_connected:shared = 0;

our $file_server_request:shared = '';
our $file_server_reply:shared = '';
our $file_reply_pending:shared = 0;


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
	if (!$remote_connected)
	{
		$this->session_error("remote not connected in doRemoteRequest()");
		return 0;
	}

	$file_server_reply = '';
	$file_reply_pending = 1;

	my $started = time();
	while ($file_reply_pending)
	{
		my $ok = 1;
		if (!$remote_connected)
		{
			$this->session_error("remote not connected in doRemoteRequest()");
			$ok = 0;;
		}
		if ($ok && time() > $started + $REMOTE_TIMEOUT)
		{
			$this->session_error("doRemoteRequest() timed out");
			$ok = 0;;
		}
		if (!$ok)
		{
			$file_server_request = '';
			$file_server_reply = '';
			$file_reply_pending = 0;
			return 0;
		}
		display($dbg_request+1,0,"doRemoteRequest() waiting for reply ...");
		sleep(0.2);
	}

	if (!$file_server_reply)
	{
		$file_server_request = '';
		$file_server_reply = '';
		$file_reply_pending = 0;
		$this->session_error("empty reply doRemoteRequest()") if !$file_server_reply;
		return 0;
	}

	$file_server_request = '';
	$file_server_reply =~ s/\s+$//g;
	$this->sendPacket($file_server_reply);
	return 1;
}



sub doRemoteRequest
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

	$file_server_request = $request;
	return if !$this->waitReply();

	while ($file_server_reply =~ /^PROGRESS/)
	{
		return if !$this->waitReply();
	}
	return 1;
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
