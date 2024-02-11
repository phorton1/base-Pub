#!/usr/bin/perl
#-----------------------------------------------------
# Pub::IOT::WSRemote.pm
#-----------------------------------------------------
# WSRemote is an object that handles persistent
# WebSocket connections to remote javascript clients
# over HTTPS/WSS. Control is diverted here from the
# main HTTPS Server on requests to the url /ws.
#
# It works in conjunction with the Devices and
# the WSLocal to channel requests between external
# remote WSS javascript clients and local IOT devics.
#
# Pub::IOT::Server serves webSockets over the same port
# as the HTTPS Server (6902). Any requests to /ws are
# directed here, and after the handshake is negotiated.
# an endless loop keeps the forked or separate threaded
# process open with the $client (socket) handle lasting
# forever or until a WS close frame, or an inactivity
# timeout.
#
# This technique, of course, should NOT be used with a
# non-forked, non-threaded WebServer.

package Pub::IOT::WSRemote;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Prefs;
use Pub::HTTP::Request;
use Pub::HTTP::Response;
use IO::Select;
use Digest::SHA  qw(sha1);
use Protocol::WebSocket::Frame;
use JSON;


my $ws_server_num:shared = 0;
my $remotes:shared = shared_clone({});


my $dbg_wss = 0;
my $dbg_ping = 1;


# start and stop for API compatibility

sub start
{}
sub stop
{}


# handle_request (threaded)

sub handle_request
	# An HTTPS request to /ws has been made.
	# Attempt to promote it to a WSS Websocket
{
    my ($server,$client,$request) = @_;

	display_hash($dbg_wss+1,0,"request",$request);
	display_hash($dbg_wss+1,0,"headers",$request->{headers});
	display_hash($dbg_wss+1,0,"server default_headers",$request->{server}->{default_headers});

	# There are a number of security requirements upon which we should close the connection
	# and not send anything, or send specific replies.

	my $response;
	my $upgrade = $request->{headers}->{upgrade};
	if ($upgrade && $upgrade eq 'websocket')
	{
		my $key = $request->{headers}->{'sec-websocket-key'};
		warning($dbg_wss,-1,"WS_REMOTE: websocket upgrade requested key=$key");

		my $digest = sha1($key."258EAFA5-E914-47DA-95CA-C5AB0DC85B11"		);
		my $reply_key = encode64($digest);
			# concatenate the client's Sec-WebSocket-Key and the string
			# "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" together,
			# take the SHA-1 hash of the result, and return the base64
			# encoding of that hash.
		my $upgrade_response =
			"HTTP/1.1 101 Switching Protocols\r\n".
			"Upgrade: websocket\r\n".
			"Connection: Upgrade\r\n".
			"Sec-WebSocket-Accept: $reply_key\r\n".
			"\r\n";
		display($dbg_wss+1,0,"reply_key='$reply_key'   digest='$digest'");
		$client->write($upgrade_response);

		handleWSRemote($client);
		$response = $RESPONSE_HANDLED;
	}
	else
	{
		$response = Pub::HTTP::Response->new($request,401,'text/plain','not found');
	}

	return $response;
}



sub writeRemote
{
	my ($sock,$server_num,$buf) = @_;
	display($dbg_wss+1,0,"WS_REMOTE($server_num) writeRemote(".length($buf).")");
	my $frame = Protocol::WebSocket::Frame->new(buffer => $buf);
	$sock->write($frame->to_bytes());
}



sub loop
	# for each device with any pending_remotes,
	# shift them off of the device, and loop through
	# all remotes, and for any that have that device as
	# their context, push them onto the remote's pending_out queue
	# Usually there will be very few remotes at any given time,
	# though there are expected to be a number of devices.
{
	my $devices = Pub::IOT::Device::getDevices();
	for my $device (values %$devices)
	{
		if ($device->{pending_remote})
		{
			my $pending = shift @{$device->{pending_remote}};

			while ($pending)
			{
				# display($dbg_wss+2,0,"WS_REMOTE dequeued DEVICE($device->{type}) pending_remote($pending)");
				for my $remote (values %$remotes)
				{
					# display($dbg_wss+2,0,"WS_REMOTE device=$device->{uuid} remote_device=$remote->{device}->{uuid}");
					# For some reason the mere presence of the above display line was giving
					# a "invalid value for shared variable" error in Perl with the spiffs list,
					# So I commented out all display's here for speed too ...

					if ($remote->{device} && $device->{uuid} eq $remote->{device}->{uuid})
					{
						# display($dbg_wss+2,0,"WS_REMOTE($remote->{server_num}) enqueing $pending");
						push @{$remote->{pending_out}},$pending;
					}
				}
				$pending = shift @{$device->{pending_remote}};
			}
		}
	}
}



sub handleWSRemote
	# promoted to Websocket, handle comms from remote javascript UI
{
	my ($sock) = @_;
	my $frame = Protocol::WebSocket::Frame->new();
	$ws_server_num++;

	my $server_num = $ws_server_num;
	my $remote = shared_clone({});
	$remote->{server_num} = $server_num;
	$remote->{pending_out} = shared_clone([]);
	$remote->{num_pings} = 0;
	$remotes->{$server_num} = $remote;

	my $select = IO::Select->new();
	$select->add($sock);

	warning($dbg_wss,-1,"WS_REMOTE($server_num) starting");

	# The loop will end under two conditions.
	#
	# (1) a Websocket "close" frame is received, or
	# (2) An inactivity timeout.
	#
	# The javascript MUST implement a heartbeat (i.e. ping) and
	# the INACTIVITY_TIMEOUT must be longer than the javascript interval.
	# And thus, if we don't receive activity every so often, we
	# end the loop and free the socket.

	my $timeout = time();
	my $INACTIVITY_TIMEOUT = 30;
		# currently the javascript client ping time is set to 15 (seconds)

	while (1)
	{
		if (time() > $timeout + $INACTIVITY_TIMEOUT)
		{
			warning($dbg_wss,-1,"==========> WS_REMOTE($server_num) INACTIVITY_TIMEOUT after $remote->{num_pings} pings !!");
			$remote->{num_pings} = 0;
			goto CLOSE_REMOTE;
		}

		if ($select->can_read(0.01))
		{
			my $buf;
			my $bytes = sysread $sock, $buf, 16384;
			if ($bytes)
			{
				$timeout = time();
				display($dbg_wss+1,-1,"WS_REMOTE($server_num) got $bytes bytes");
				$frame->append($buf);

				while (my $data = $frame->next)
				{
					if ($frame->is_close())
					{
						warning($dbg_wss,-1,"==========> WS_REMOTE($server_num) GOT CLOSE FRAME after $remote->{num_pings} pings !!");
						goto CLOSE_REMOTE;
					}

					# ping handled in tight loop

					if ($data eq '{"cmd":"ping"}')
					{
						# ping does not go through writeRemote to hide debugging
						$remote->{num_pings}++;
						display($dbg_ping,-1,"WS_REMOTE($server_num) got ping, sending pong");
						my $out_frame = Protocol::WebSocket::Frame->new(buffer => '{"pong":1}');
						$sock->write($out_frame->to_bytes());
						next;
					}

					# call json processor

					handleRemoteJson($sock,$server_num,$remote,$data);
				}
			}
		}
		elsif (@{$remote->{pending_out}})
		{
			my $pending = shift @{$remote->{pending_out}};
			while ($pending)
			{
				display($dbg_wss+1,0,"WS_REMOTE($remote->{server_num}) dequeing $pending");
				writeRemote($sock,$server_num,$pending);
				$pending = shift @{$remote->{pending_out}};
			}
		}
	}


CLOSE_REMOTE:

	warning($dbg_wss,-1,"WS_REMOTE($server_num) disconnected!!!!");
	delete $remotes->{$server_num};
	$sock->close();
}





sub handleRemoteJson
{
	my ($sock,$server_num,$remote,$json_text) = @_;
	display($dbg_wss,-1,"WS_REMOTE($server_num) handleRemoteJson($json_text) device=" . ($remote->{device} ? $remote->{device}->{type} : "undef"));
	my $json = decode_json($json_text);
	if (!$json)
	{
		error("WS_REMOTE($server_num) could not parse json($json_text)");
		return;
	}

	my $cmd = $json->{cmd} || '';
	if ($cmd eq 'set_context')
	{
		my $uuid = $json->{uuid};
		display($dbg_wss,-1,"WS_REMOTE($server_num) setContext($uuid)");
		my $devices = Pub::IOT::Device::getDevices();
		my $device = $devices->{$uuid};
		if ($device)
		{
			if ($device->{cache})
			{
				$remote->{device} = $device;
				display_hash($dbg_wss,-1,"WS_REMOTE($server_num) reply",$device->{cache});
				my $text = encode_json($device->{cache});
				display($dbg_wss+1,-1,"WS_REMOTE($server_num) device_list sending ".length($text)." bytes");

				writeRemote($sock,$server_num,$text);
			}
			else
			{
				error("WS_REMOTE($server_num) device($device->{type}) has no cache in setContext($uuid)");
			}
		}
		else
		{
			error("WS_REMOTE($server_num) unknown device in setContext($uuid)");
		}
	}
	elsif ($cmd eq 'device_list')
	{
		my $text = '';
		my $devices = Pub::IOT::Device::getDevices();
		for my $device (sort {$a->{type} cmp $b->{type}} values %$devices)
		{
			if ($device->{cache})
			{
				$text .= $text ? ",\n" : "\n";
				$text .= '{"uuid":"' . $device->{uuid} . '"';
				$text .= ',"name":"' . $device->{cache}->{device_name} . '"}';		# should be {cache}->{device_name}
			}
			else
			{
				warning(0,0,"device($device->{type}) has no cache in device_list");
			}
		}
		$text = '{"device_list":[' . $text . ']}';
		writeRemote($sock,$server_num,$text);
	}
	elsif ($remote->{device})
	{
		display($dbg_wss,-1,"WS_REMOTE($server_num) dispatching $json_text to $remote->{device}->{type}");
		$remote->{device}->writeLocal($json_text);
	}
}



1;
