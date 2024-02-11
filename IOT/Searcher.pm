#---------------------------------------
# Pub::SSDP::Searcher.pm
#---------------------------------------
# NOTE THIS DOES NOT HANDLE BROADCAST NOTIFY SSDP MESSAGES.
# Would need separate loop (or at least Select() call) to
# monitor the actual SSDP broadcast IP:port.  The code currently
# exists in SSDP::Server.

package Pub::IOT::Searcher;
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Select;
use IO::Socket::INET;
use Pub::Utils;
use Pub::IOT::Wifi;


my $dbg_searcher = 0;

my $MX_TIME = 8;
my $REFRSH_TIME = 30;

my $server_thread;
my $socket;

my $g_callback;
my $g_urn:shared = '';
my $g_running:shared = 0;
my $g_stopping:shared = 0;


sub start
{
    my ($urn,$callback) = @_;

	$g_urn = $urn;
	$g_running = 0;
	$g_stopping = 0;
	$g_callback = $callback;

    display($dbg_searcher,0,"Searcher::start() creating socket");

	# socket ctor dies
	# might want try() catch)() around it for better default
	# behavior, esp if it's a service.

    $socket = IO::Socket::INET->new(
        # LocalAddr => $server_ip,
        LocalPort => 8679,
        PeerPort  => $SSDP_PORT,
        Proto     => 'udp',
        ReuseAddr => 1);

	# There might be a necessary unix fallback to 127.0.0.0 here.
	# See SSDP::Server for similarities

    if (!$socket)
    {
        error("SSDP::Searcher::start() could not create socket: $@");
        return 0;
    }

    # add the socket to the correct IGMP multicast group

    if (!_mcast_add( $socket, $SSDP_GROUP ))
	{
		$socket->close();
		return;
	}

    display($dbg_searcher,0,"Searcher starting thread");
	$server_thread = threads->create(\&listenerThread);
	$server_thread->detach();
    display($dbg_searcher,0,"SSDP::Searcher::start() returning 1");
	return 1;
}





sub stop
{
    display($dbg_searcher,0,"Searcher::stop() called");
    $g_stopping = 1;

	my $TIMEOUT = 3;
	my $time = time();
    while (time() < $time+$TIMEOUT && $g_running)
    {
        display($dbg_searcher+1,0,"Waiting for SSDP::Searcher to stop");
        sleep(1);
    }

	error("Could not stop SSDP::Searcher") if $g_running;
	$g_running = 0;
	$g_stopping = 0;
    display($dbg_searcher,0,"Searcher::stop() finished");
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
        error("Unable to add IGMP membership: $!");
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
        error("Error setting multicast TTL to 4: $!");
        exit 1;
    };

    my $dest_addr = sockaddr_in( $port, inet_aton( $addr ) );
    my $bytes = send( $sock, $msg, 0, $dest_addr );

	$bytes = 0 if !defined($bytes);
		# otherwise in case of undef we get Perl unitialized variable warningds
	if ($bytes != length($msg))
	{
		error("Could not _mcast_send() sent $bytes expected ".length($msg));
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

    display($dbg_searcher+1,0,"sendSearch($g_urn)");
    _mcast_send( $socket, $ssdp_header, $SSDP_GROUP, $SSDP_PORT );
}



#-------------------------------------------------
# listener thread
#-------------------------------------------------

sub listenerThread
{
	display($dbg_searcher,0,"Searcher::listenerThread() started");

	$g_running = 1;
	_sendSearch();
	my $last_time = time();

	while (Pub::IOT::Wifi::connected() && !$g_stopping)
	{
		if (time() > $last_time + $REFRSH_TIME)
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

			display($dbg_searcher+2,2,"SSDP RESPONSE");
			for my $line (split(/\n/,$ssdp_res_msg))
			{
				$line =~ s/\s*$//g;
				if ($line =~ /^(.*?):(.*)$/)
				{
					my ($left,$right) = ($1,$2);
					$left = uc($left);
					$left =~ s/\s//g;
					$right =~ s/^\s//g;

					display($dbg_searcher+2,3,"$left = $right");
					$rec->{$left} = $right;
				}
				else
				{
					display($dbg_searcher+2,3,$line);
				}
			}

			if (!$rec->{LOCATION})
			{
				warning(0,0,"No LOCATION in SSDP message");
				next;
			}

			if ($rec->{LOCATION} !~ m/http:\/\/([0-9a-z.]+)[:]*([0-9]*)\/(.*)/i)
			{
				error("Bad LOCATION in SSDP message: $rec->{LOCATION}");
				next;
			}

			$rec->{ip} = $1;
			$rec->{port} = $2;
			$rec->{path} = $3;

			if ($g_callback)
			{
				&$g_callback($rec);
			}
		}
    }

	LOG(-1,"Searcher listenerThread terminated");

	$g_running = 0;
    $socket->close();
	undef($socket);
	threads->exit();
}


1;
