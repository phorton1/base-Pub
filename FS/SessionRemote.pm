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

BEGIN {
    use Exporter qw( import );
	our @EXPORT = (
		qw (
			$dbg_request
			$file_server_request
			$file_server_reply
			$file_reply_pending
		),
	    # forward base class exports
        @Pub::FS::Session::EXPORT,
	);
};


our $file_server_request:shared = '';
our $file_server_reply:shared = '';
our $file_reply_pending:shared = 0;


sub new
{
    my ($class,$params) = @_;
    my $this = $class->SUPER::new($params);
	return $this;
}




#========================================================================================
# Command Processor
#========================================================================================


sub doRemoteRequest
{
	my ($request) = @_;
	if ($request =~ /BASE64/)
	{
		display($dbg_request,0,"doRemoteRequest(BASE64) len=".length($request));
	}
	else
	{
		display($dbg_request,0,"doRemoteRequest($request)");
	}
	$file_server_reply = '';
	$file_server_request = $request;
	$file_reply_pending = 1;

	while ($file_reply_pending)
	{
		display($dbg_request+1,0,"doRemoteRequest() waiting for reply ...");
		sleep(0.2);
	}

	display($dbg_request+1,0,"doRemoteRequest() got reply: '$file_server_reply'");
	display($dbg_request,0,"doRemoteRequest() returning ".length($file_server_reply)." bytes");
}





sub _listRemoteDir
{
    my ($this, $dir) = @_;
    display($dbg_commands,0,"_listRemoteDir($dir)");
	doRemoteRequest("file_command:$SESSION_COMMAND_LIST\t$dir");
	if (!$file_server_reply)
	{
		$this->session_error("_listRemoteDir() - empty reply - returning undef");
		return undef;
	}
    $this->send_packet($file_server_reply);
    display($dbg_commands,0,"_listRemoteDir($dir) returning after send_packet(".length($file_server_reply).")");
	return '';
}

sub _mkRemoteDir
{
    my ($this, $dir, $name) = @_;
    display($dbg_commands,0,"_mkRemoteDir($dir)");
	doRemoteRequest("file_command:$SESSION_COMMAND_MKDIR\t$dir\t$name");
	if (!$file_server_reply)
	{
		$this->session_error("_mkRemoteDir() - empty reply - returning undef");
		return undef;
	}
    $this->send_packet($file_server_reply);
	return '';
}

sub _renameRemote
{
    my ($this, $dir, $name1, $name2) = @_;
    display($dbg_commands,0,"_renameRemote($dir)");
	doRemoteRequest("file_command:$SESSION_COMMAND_RENAME\t$dir\t$name1\t$name2");
	if (!$file_server_reply)
	{
		$this->session_error("_renameRemote() - empty reply - returning undef");
		return undef;
	}
    $this->send_packet($file_server_reply);
	return '';
}




1;
