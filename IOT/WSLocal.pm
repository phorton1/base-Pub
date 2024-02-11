#!/usr/bin/perl
#-----------------------------------------------------
# Pub::IOT::WSLocal.pm
#-----------------------------------------------------
# WSLocal is the object that handles persistent
# WebSocket connections to local myIOT devices.
# It works in conjunction with Devices and
# the WSRemote to channel requests between external
# remote WSS javascript clients and local IOT devics.

package Pub::IOT::WSLocal;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Prefs;
use IO::Select;
use Protocol::WebSocket::Client;

my $CLIENT_PING_INTERVAL = 15;
my $CLIENT_PING_TIMEOUT = 7;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
	);
}


my $dbg_local = 0;
my $dbg_ping = 1;

my $client_num = 0;
my $clients = {};

my $stopping:shared = 0;



sub writeSocket
{
	my ($client_num,$msg) = @_;
	display($dbg_local,0,"WS_LOCAL($client_num,$clients->{$client_num}->{device}->{type}) writeSocket($msg)");
	$clients->{$client_num}->write($msg);
	return;
}

sub onWrite
{
	my ($a_client,$buf) = @_;
	display($dbg_local+1,0,"WS_LOCAL($a_client->{client_num},$a_client->{device}->{type}) onWrite() bytes=".length($buf));
	syswrite($a_client->{ws_socket}, $buf);
}

sub onRead
{
    my ($a_client,$buf) = @_;
	if ($buf eq '{"pong":1}')
	{
		display($dbg_ping,0,"WS_LOCAL($a_client->{client_num},$a_client->{device}->{type}) got pong");
		$a_client->{ping_time} = 0;
		$a_client->{pong_time} = time();
		$a_client->{pong_count}++;
		return;
	}
	display($dbg_local+1,0,"WS_LOCAL($a_client->{client_num},$a_client->{device}->{type}) onRead() bytes=".length($buf));
	# print $buf."\n";
	$a_client->{device}->onLocal($buf);
}


sub onConnect
{
	my ($a_client) = @_;
	warning($dbg_local,0,"WS_LOCAL($a_client->{client_num},$a_client->{device}->{type}) onConnect()");

	# send the standard setup requests to the device
	# to build the in-memory read-thru cache

	$a_client->write('{"cmd":"device_info"}');
	$a_client->write('{"cmd":"value_list"}');
	$a_client->write('{"cmd":"spiffs_list"}');
	$a_client->write('{"cmd":"sdcard_list"}');
}


sub onEOF
{
	my ($a_client) = @_;
	error("WS_LOCAL($a_client->{client_num},$a_client->{device}->{type}) onEOF)");
}

sub onError
{
	my ($a_client,$error) = @_;
	error("WS_LOCAL($a_client->{client_num},$a_client->{device}->{type}) onError=$error)");
}



sub open
{
	my ($device) = @_;
	$client_num++;

	my $ip = $device->{ip};
	my $port = $device->{port};

	display($dbg_local,0,"WS_LOCAL::open($client_num) to $device->{type} at $ip:".($port+1));
	$port += 1;

	my $ws_client = Protocol::WebSocket::Client->new(
		url => "ws://#ip:$port");


	if (!$ws_client)
	{
		error("Could not open ws_client(ws:://$ip:$port)");
		$device->onClose();
		return;
	}
	display($dbg_local+2,1,"WS_LOCAL::open($client_num) client_created $ws_client");

	$ws_client->on( write => \&onWrite );
	$ws_client->on( read => \&onRead );
	$ws_client->on( connect => \&onConnect );
	$ws_client->on( eof => \&onEOF );
	$ws_client->on( error => \&onError );

	# open the socket with the protcol in place

	my $ws_socket = IO::Socket::INET->new(
		PeerAddr => $ip,
		PeerPort => "ws($port)",
		Proto => 'tcp',
		Blocking => 1 );

	if (!$ws_socket)
	{
		$device->onClose();
		error("Could not open ws_socket($ip:$port)");
		return;
	}
	display($dbg_local+2,1,"WS_LOCAL::open($client_num) socket opened $ws_socket");

	$ws_client->{ws_socket} = $ws_socket;
	$ws_client->{device} = $device;
	$ws_client->{client_num} = $client_num;
	$ws_client->{pong_time} = time();
	$ws_client->{ping_time} = 0;
	$ws_client->{pong_count} = 0;

	$clients->{$client_num} = $ws_client;

	$device->onOpen($client_num);

	$ws_client->connect();

	display($dbg_local+1,1,"WS_LOCAL($client_num) opened to $device->{type} at $ip:".($port+1));
	# display(0,0,"client=$ws_client");
	return $client_num;
}




sub loop()
{
	return if $stopping;

	my $tm = time();
	my $select = IO::Select->new();
	for my $client (values %$clients)
	{
		# ping timeout

		if ($client->{ping_time} &&
			$tm > $client->{ping_time} + $CLIENT_PING_TIMEOUT)
		{
			warning(0,-1,"WS_LOCAL($client->{client_num},$client->{device}->{type}) PING TIMEOUT after $client->{pong_count} pongs!");
			$client->{ping_time} = 0;
			$client->{pong_count} = 0;

			$client->disconnect();
			$client->{device}->onClose();
			delete $clients->{$client->{client_num}};
			return if $stopping;
			next;
		}

		# send a ping

		elsif (!$stopping &&
			   !$client->{ping_time} &&
			   $tm > $client->{pong_time} + $CLIENT_PING_INTERVAL)
		{
			display($dbg_ping,0,"WS_LOCAL($client->{client_num},$client->{device}->{type}) Sending ping at $tm");
			$client->{ping_time} = $tm;
			$client->write('{"cmd":"ping"}');
		}

		return if $stopping;
		$select->add($client->{ws_socket});
	}

	return if $stopping;

	my @handles = $select->can_read(0.01);
	for my $handle (@handles)
	{
		my $buf;
		my $bytes = sysread $handle, $buf, 16384;
		return if $stopping;
		if ($bytes)
		{
			display($dbg_local+1,0,"got $bytes bytes for handle($handle)");
			for my $client (values %$clients)
			{
				if ($client->{ws_socket} == $handle)
				{
					display($dbg_local+1,0,"dispatching $bytes bytes to webSocket($client->{client_num},$client->{device}->{type})");
					return if $stopping;
					$client->read($buf);
					last;
				}
			}
		}
	}
}



# Trying to solve problem that shutting down the rPi basically
# hangs devices as they cannot send to the websocket.


sub stop()
{
	LOG(0,"Stopping WSLocal ...");
	$stopping = 1;

	for my $ws_num (keys %$clients)
	{
		my $client = $clients->{$ws_num};
		my $name = $client->{device} ? $client->{device}->{type} : 'unknown dewvice';
		LOG(0,"stopping($ws_num) device($name)");
		# display(0,0,"client=$client");
		$client->{device}->onClose(1) if $client->{device};
		undef $client->{device};
		# $client->{ws_socket}->close() if $client->{ws_socket};
		undef $client->{ws_socket};
		undef($client);
		delete $clients->{$ws_num};
	}
	LOG(0,"WSLocal stopped");
	$stopping = 0;
}


1;
