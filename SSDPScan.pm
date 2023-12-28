#---------------------------------------
# Pub::SSDPScan
#---------------------------------------
# Usage:
#
#		my $started = Pub::SSDPScan->start($SEARCH_ALL,&callback [,120] );
#			# the optional 3rd parameter is the seconds between refreshes
#			#     which defaults to 30
#			# use $SEARCH_MYIOT to only find myIOT devices
#
#       .... eventually, at end of program
#
#       if ($started)
#          Pub::SSDPScan::stop();
#
# The callback method receives a single parameter, a hash
#     for each device found containing:


package Pub::SSDPScan;
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Select;
use IO::Socket::INET;
use Pub::Utils;

my $dbg_ssdp = 0;
	# 0 = show server startup
	# -1 = show server startup details
my $dbg_send = 1;
	# show MCAST sends
my $dbg_resp = 1;
	# 0 = show response headers
	# 1 = show response fields


BEGIN {
    use Exporter qw( import );
	our @EXPORT = qw (
		$SEARCH_ALL
        $SEARCH_MYIOT
	);
}


our $SEARCH_ALL = "upnp:rootdevice";
our $SEARCH_MYIOT = "urn:myIOTDevice";

my $LOCAL_PORT = 8679;		# arbitrary
my $SSDP_PORT  = 1900;
my $SSDP_GROUP = '239.255.255.250';

my $MX_TIME = 8;
my $DEFAULT_REFRESH_TIME = 30;

my $server_thread;
my $socket;

my $g_callback;
my $g_urn:shared = '';
my $g_running:shared = 0;
my $g_stopping:shared = 0;


sub start
{
    my ($urn,$callback,$refresh_time) = @_;

	$refresh_time ||= $DEFAULT_REFRESH_TIME;

	$g_urn = $urn;
	$g_running = 0;
	$g_stopping = 0;
	$g_callback = $callback;

    display($dbg_ssdp+1,0,"SSDPScan creating socket");

	# socket ctor dies
	# might want try() catch)() around it for better default
	# behavior, esp if it's a service.

    $socket = IO::Socket::INET->new(
        # LocalAddr => $server_ip,
        LocalPort => $LOCAL_PORT,
        PeerPort  => $SSDP_PORT,
        Proto     => 'udp',
        ReuseAddr => 1);

	# There might be a necessary unix fallback to 127.0.0.0 here.
	# See SSDP::Server for similarities

    if (!$socket)
    {
        error("SSDPScan could not create socket: $@");
        return 0;
    }

    # add the socket to the correct IGMP multicast group

    if (!_mcast_add( $socket, $SSDP_GROUP ))
	{
		$socket->close();
		return;
	}

    display($dbg_ssdp+1,0,"SSDPScan starting thread");
	$server_thread = threads->create(\&listenerThread,$refresh_time);
	$server_thread->detach();
    display($dbg_ssdp,0,"SSDPScan started on port($LOCAL_PORT)");
	return 1;
}





sub stop
{
    display($dbg_ssdp,0,"SSDPScan stopping");
    $g_stopping = 1;

	my $TIMEOUT = 3;
	my $time = time();
    while (time() < $time+$TIMEOUT && $g_running)
    {
        display($dbg_ssdp+1,0,"SSDPScan waiting to stop");
        sleep(1);
    }

	if ($g_running)
	{
		error("Could not stop SSDPScan");
	}
	else
	{
	    display($dbg_ssdp,0,"SSDPScan stopped.");
	}
	$g_running = 0;
	$g_stopping = 0;
}



#-------------------------------------------
# utilities
#-------------------------------------------

sub _mcast_add
{
    my ( $sock, $addr ) = @_;
    my $ip_mreq = inet_aton( $addr ) . INADDR_ANY;

    if (!setsockopt(
        $sock,
        getprotobyname('ip') || 0,
        _constant('IP_ADD_MEMBERSHIP'),
        $ip_mreq  ))
    {
        error("SSDPScan Unable to add IGMP membership: $!");
        return 0;
    }
	return 1;
}


sub _mcast_send
{
    my ( $sock, $msg, $addr, $port ) = @_;

    # Set a TTL of 4 as per UPnP spec
    if (!setsockopt(
        $sock,
        getprotobyname('ip') || 0,
        _constant('IP_MULTICAST_TTL'),
        pack 'I', 4 ))
    {
        error("SSDPScan error setting multicast TTL to 4: $!");
        exit 1;
    };

    my $dest_addr = sockaddr_in( $port, inet_aton( $addr ) );
    my $bytes = send( $sock, $msg, 0, $dest_addr );

	$bytes = 0 if !defined($bytes);
		# otherwise in case of undef we get Perl unitialized variable warningds
	if ($bytes != length($msg))
	{
		error("SSDPScan could not _mcast_send() sent $bytes expected ".length($msg));
		return 0;
	}
	return 1;
}


sub _constant
{
    my ($name) = @_;
    my %names = (
        IP_MULTICAST_TTL  => 0,
        IP_ADD_MEMBERSHIP => 1,
        IP_MULTICAST_LOOP => 0,
    );
    my %constants = (
        MSWin32 => [10,12],
        cygwin  => [3,5],
        darwin  => [10,12],
        default => [33,35],
    );

    my $index = $names{$name};
    my $ref = $constants{ $^O } || $constants{default};
    return $ref->[ $index ];
}



sub _sendSearch
{
   my $ssdp_header = <<"SSDP_SEARCH_MSG";
M-SEARCH * HTTP/1.1
Host: $SSDP_GROUP:$SSDP_PORT
Man: "ssdp:discover"
ST: $g_urn
MX: $MX_TIME

SSDP_SEARCH_MSG

    $ssdp_header =~ s/\r//g;
    $ssdp_header =~ s/\n/\r\n/g;


	display($dbg_send,-1,"SSDPScan MCAST_SEND($g_urn)");
    _mcast_send( $socket, $ssdp_header, $SSDP_GROUP, $SSDP_PORT );
}



#-------------------------------------------------
# listener thread
#-------------------------------------------------

sub listenerThread
{
	my ($refresh_time) = @_;
	display($dbg_ssdp+1,0,"SSDPScan listenerThread($refresh_time) started");

	$g_running = 1;
	_sendSearch();
	my $last_time = time();

	while (!$g_stopping)
	{
		if (time() > $last_time + $refresh_time)
		{
			_sendSearch();
			$last_time = time();
		}

		my $sel = IO::Select->new($socket);
		while ( $sel->can_read( 1 ))	# $MX_TIME + 4 ) )
		{
			my $ssdp_res_msg;
			recv ($socket, $ssdp_res_msg, 4096, 0);

			my $rec = {};

			display($dbg_resp,1,"SSDP RESPONSE");
			for my $line (split(/\n/,$ssdp_res_msg))
			{
				$line =~ s/\s*$//g;
				if ($line =~ /^(.*?):(.*)$/)
				{
					my ($left,$right) = ($1,$2);
					$left = uc($left);
					$left =~ s/\s//g;
					$right =~ s/^\s//g;

					display($dbg_resp+1,2,"$left = $right");
					$rec->{$left} = $right;
				}
				else
				{
					display($dbg_resp+1,2,$line) if $line;
				}
			}

			if (!$rec->{LOCATION})
			{
				warning($dbg_resp,0,"No LOCATION in SSDP message");
				next;
			}

			if ($rec->{LOCATION} !~ m/http:\/\/([0-9a-z.]+)[:]*([0-9]*)\/(.*)/i)
			{
				error("Bad LOCATION in SSDP message: $rec->{LOCATION}")
					if $dbg_resp <= 0;
				next;
			}

			$rec->{ip} = $1;
			$rec->{port} = $2;
			$rec->{path} = $3;

			display($dbg_resp+1,2,"ip = $rec->{ip}");
			display($dbg_resp+1,2,"port = $rec->{port}");
			display($dbg_resp+1,2,"path = $rec->{path}");

			if ($g_callback)
			{
				&$g_callback($rec);
			}
		}
    }

	display($dbg_ssdp+1,0,"SSDPScan listenerThread terminated");

	$g_running = 0;
    $socket->close();
	undef($socket);
	threads->exit();
}


1;
