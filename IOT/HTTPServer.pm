#!/usr/bin/perl
#-----------------------------------------------------
# Pub::IOT:HTTPServer.pm
#-----------------------------------------------------
# The HTTP Server for my IOT Server running on the rPi

use lib '/base';
	# needed for unix service

package Pub::IOT::myIOTServer;		# continued
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Socket::INET;
use Pub::Utils;
use Pub::Prefs;
use Pub::HTTP::Response;
use Pub::HTTP::ServerBase;
use base qw(Pub::HTTP::ServerBase);


my $dbg_server = 1;
my $dbg_fwd = 0;


#---------------------------------------------------------
# handle_request
#---------------------------------------------------------

sub handle_request
	# At this point they are logged with a valid HTTP basicAuth header that
	# has been confirmed against the user names and passwords in users.txt.
	# Pub::IOT::Serverbase has added "auth_user" and "auth_privs" fields with
	# the "privs" from that user file.
    #
	# $request->{auth_priv}, availalbe for use, is a comma delimited list
	# of pid:level where pid is a program id. The priv *:5 is reserved
	# for me for all programs at security level 5
{
    my ($this,$client,$request) = @_;
	my $uri = $request->{uri};
	my $method = $request->{method};

	my $response;

	# now standard in base_class
	# my $auth_privs = $request->{auth_privs} || '';
	# my $save_login = $login_name;
	# $login_name = $request->{auth_user} || '';

    display($dbg_server,0,"handle_request($method,$uri)");

	#------------------------------------
	# external stuff
	#------------------------------------
	# Handle pass-thru requests to devices

	if ($method eq 'POST' &&
		$uri =~ /^\/(ota_files)/ ||
		$uri =~ /^\/(spiffs_files)/ ||
		$uri =~ /^\/(sdcard_files)/)
	{
		my $kind = $1;
		display_hash($dbg_fwd+1,-1,"headers",$request->{headers});
		my $uuid = $request->{headers}->{'x-myiot-deviceuuid'};
		if (!$uuid)
		{
			error("No UUID header in $kind $request->{method} request");
			return undef;
		}
		$response = forwardRequest($client,$request,$kind,$uuid);
	}
	elsif ($method eq 'GET' &&
		 $uri =~ /^\/(custom)\// ||
		 $uri =~ /^\/(sdcard)\// ||
		 $uri =~ /^\/(spiffs)\//)
	{
		my $kind = $1;
		my $uuid = $request->{uri} =~ s/\?uuid=(.*)$// ? $1 : '';
		if (!$uuid)
		{
			error("No UUID header in $kind $request->{method} request");
			return undef;
		}

		$response = forwardRequest($client,$request,$kind,$uuid);
	}

	#---------------------------------------------
	# HTTP access to basic server functionality
	#---------------------------------------------

	elsif ($uri eq "/reboot")
	{
		LOG(0,"Pub::IOT::Handler rebooting the rPi");
		system("sudo reboot");
		$response = Pub::HTTP::Response->new($request,200,"text/plain",
			"Rebooting Server");
	}
	elsif ($uri eq '/server/restart')
	{
		my $what = $1;
		my $msg = "Pub::IOT::Handler restarting the myIOTServer.service in 5 seconds";
		LOG(0,$msg);
		no warnings 'once';
		$Pub::IOT::myIOTServer::do_restart = time();
		$response = Pub::HTTP::Response->new($request,200,'text/plain',$msg);
	}
	elsif ($uri =~ /^\/file_server\/(.*)$/)
	{
		my $what = $1;
		my $fs_logfile = "/base_data/temp/fileServer.log";
		if ($what eq 'log')
		{
			$response = Pub::HTTP::Response->new($request,200,'text/plain',
				shared_clone({filename=>$fs_logfile}));
		}
		elsif ($what eq 'log/clear')
		{
			unlink $fs_logfile;
			my $save_logfile = $logfile;
			$logfile = $fs_logfile;
			LOG(0,"fs_logfile $fs_logfile cleared");
			$logfile = $save_logfile;
			$response = Pub::HTTP::Response->new($request,200,'text/plain',
				shared_clone({filename=>$fs_logfile}));
		}
		else
		{
			my $msg = "Pub::IOT::Handler $what the fileServer service";
			LOG(0,$msg);
			system("sudo systemctl $what prh-fileserver.service");
			$response = Pub::HTTP::Response->new($request,200,'text/plain',$msg);
		}
	}
	elsif ($uri eq "/log")
	{
		$response = Pub::HTTP::Response->new($request,200,'text/plain',
            shared_clone({filename=>$logfile}));
	}
	elsif ($uri eq "/log/clear")
	{
		if (!(-f $logfile))
		{
			$response = Pub::HTTP::Response->new($request,200,'text/plain',"LOGFILE $logfile does not exist");
		}
		else
		{
			unlink $logfile;
			sleep(1);
			LOG(0,"logfile $logfile cleared");
			sleep(1);
			$response = Pub::HTTP::Response->new($request,200,'text/plain',
				shared_clone({filename=>$logfile}));
		}
	}


	#---------------------------------------------------------
	# Promote the remote request to a WebSocket
	#---------------------------------------------------------

	elsif ($uri eq "/ws")
	{
		$response = Pub::IOT::WSRemote::handle_request($this,$client,$request);
	}


	#------------------------------------
	# Base Class Stuff
	#------------------------------------
	# Let the base class handle regular serving from Pub::IOT::site directory

	else
	{
		$response = Pub::HTTP::ServerBase::handle_request($this,$client,$request);
	}

	# $login_name = $save_login;
	return $response;
}


sub forwardRequest
	# this might be something that is limited by auth_privs
{
	my ($client,$request,$kind,$uuid) = @_;

	# find the device

	my $device = Pub::IOT::Device::findDeviceByUUID($uuid);
	if (!$device)
	{
		error("Could not find device($uuid) in $kind $request->{method} request");
		return undef;
	}
	warning($dbg_fwd,0,"forwarding $kind $request->{method} request to $device->{type} at $device->{ip}:$device->{port}");

	# open the socket

	my $sock = IO::Socket::INET->new("$device->{ip}:$device->{port}");
	if (!$sock)
	{
		error("Could not open connection to $device->{type} at $device->{ip}:$device->{port}");
		return;
	}

	# magic copied from Pub::IOT::Message.pm

    local $/ = Socket::CRLF;
	binmode $sock;
	$sock->autoflush(1);

	# send the headers
	# We send out mimimal headers, however, here's what we received (not in order)
	#
	# accept = '*/*'
	# accept-encoding = 'gzip, deflate, br'
	# accept-language = 'en-US,en;q=0.5'
	# authorization = 'Basic cHJoOnByaDEzNHg='
	# connection = 'keep-alive'
	# content-length = '5271'
	# content-type = 'multipart/form-data; boundary=---------------------------154764450822490360233068143126'
	# dnt = '1'
	# host = 'localhost:6902'
	# origin = 'https://localhost:6902'
	# referer = 'https://localhost:6902/index.html'
	# sec-fetch-dest = 'empty'
	# sec-fetch-mode = 'cors'
	# sec-fetch-site = 'same-origin'
	# user-agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:95.0) Gecko/20100101 Firefox/95.0'
	# x-myiot-deviceuuid = '38323636-4558-4dda-9188-7c9ebd667ddc'

	my $uri = $request->{uri};
	my $headers = $request->{headers};
	my $text = "$request->{method} $uri HTTP/1.1\r\n";
	$text .= "Host: $headers->{host}\r\n";
	$text .= "Content-Type: $headers->{'content-type'}\r\n"
		if $headers->{'content-type'};
	$text .= "Content-Length: $headers->{'content-length'}\r\n"
		if $headers->{'content-length'};
	$text .= "Accept-Encoding: $headers->{'accept-encoding'}\r\n"
		if $headers->{'accept-encoding'};
	$text .= "\r\n";

	display($dbg_fwd+1,0,"Sending HEADERS\n$text");
	$sock->write($text);

	# send the content

	my $content = $request->{content};
	display($dbg_fwd+1,0,"Sending ".length($content)." bytes of CONTENT");
	$sock->write($content);

	# get reply headers nad forward them to the client

	display($dbg_fwd+1,0,"waiting for result");
	my $content_length = 0;
	while (my $line = <$sock>)
	{
		$client->write($line);
		$line =~ s/\s$//g;
		display($dbg_fwd+1,1,"forwarded header_line: $line");
		$content_length = $1 if $line =~ /Content-Length: (\d+)$/;
		last if !$line;
		$line = <$sock>;
	}

	# forward the content, if any, to the client

	if ($content_length)
	{
		display($dbg_fwd,0,"forwarding $content_length bytes of content");

		my $TIMEOUT = 60;

		my $buf;
		my $remain = $content_length;
		my $timeout = time();
		while ($remain)
		{
			if (time() > $timeout + $TIMEOUT)
			{
				error("read timed out");
				last;
			}
			my $to_read = $remain;
			$to_read = 10000 if $to_read > 10000;
			my $got = sysread $sock,$buf,$to_read;
			if ($got != $to_read)
			{
				# we often receive less than we asked for while it still works.
				# warning(0,0,"forwarding read expected $to_read got $got");
				if (!$got)
				{
					error("sysread returned zero");
					last;
				}
				$to_read = $got;
			}

			# write a buffer to the client

			if ($to_read)
			{
				$timeout = time();
				$got = syswrite $client,$buf,$to_read;
				if ($got != $to_read)
				{
					error("forwarding write expected $to_read got $got");
					last;
				}
				$remain -= $to_read;
			}
		}
	}

	display($dbg_fwd,0,"forwardRequest() returning");
	return $RESPONSE_HANDLED;;
}


1;
