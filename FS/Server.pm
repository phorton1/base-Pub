#-------------------------------------------------
# Pub::FS::Server
#--------------------------------------------------
# Currently limited to a single instance due to many globals
# and use of prefs.
#
# The Server Creates a socket and listens for connections.
# For each connection it accepts it creates a Session by
# calling createSession. By default, the base class uses
# a SocketSession to provide information about, and effect
# changes in the local file system.
#
# Note that I modified Win32::Console.pm to NOT close itself
# on thread/fork destruction.
#
# To use SSL, your application must call Pub::Prefs::initPrefs()
# specifying a prefs file that contains the FS_SSL preferences.


package Pub::FS::Server;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw( sleep );
use IO::Select;
use IO::Socket::INET;
use IO::Socket::SSL;
use Time::HiRes qw(sleep);
use Pub::Utils;
use Pub::Prefs;
use Pub::PortForwarder;
use Pub::FS::FileInfo;
use Pub::FS::SocketSession;
use Pub::FS::ServerSession;


our $dbg_server:shared = 0;
	# 0 for main server startup
	# -1 for forking/threading details
	# -2 null reads
	# -9 for connection waiting loop
our $dbg_notifications = 0;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
		$dbg_server
		$dbg_notifications
		$ACTUAL_SERVER_PORT
		notifyAll
	);
}

our $ACTUAL_SERVER_PORT:shared;


my $USE_FORKING = 0;

my $server_thread;
my $client_thread;
my $connect_num = 0;
my $num_notify_all:shared = 0;
my $notify_all:shared = shared_clone({});
	# a list of packets to asynchronously send to all connected threads.
	# each message has a list of connections that have sent it
	# and the main server thread reaps the ones that done.
my $active_connections = shared_clone({});
my $port_forwarder;





#-------------------------------------------------
# methods
#-------------------------------------------------

sub new
	# Params provided to the ctor will pre-empt preferences.
{
	my ($class,$params) = @_;
	$params ||= {};

	# see docs/prefs.md for list of parameters

	getObjectPref($params,'FS_SSL',0);
	getObjectPref($params,'FS_PORT',$params->{FS_SSL} ? $FS_DEFAULT_SSL_PORT : $FS_DEFAULT_PORT);
	getObjectPref($params,'FS_HOST',undef);

	getObjectPref($params,'FS_DEBUG_SSL',0);
	getObjectPref($params,'FS_SSL_CERT_FILE',undef,!$params->{FS_SSL});
	getObjectPref($params,'FS_SSL_KEY_FILE',undef,!$params->{FS_SSL});

	getObjectPref($params,'FS_FWD_PORT',undef);
	getObjectPref($params,'FS_FWD_USER',undef,!$params->{FS_FWD_PORT});
	getObjectPref($params,'FS_FWD_SERVER',undef,!$params->{FS_FWD_PORT});
	getObjectPref($params,'FS_FWD_SSH_PORT',undef,!$params->{FS_FWD_PORT});
	getObjectPref($params,'FS_FWD_KEYFILE',undef,!$params->{FS_FWD_PORT});

	getObjectPref($params,'FS_DEBUG_PING',undef);
	getObjectPref($params,'FS_FWD_DEBUG_PING',undef,!$params->{FS_FWD_PORT});

	# hardwired portForwarder and FS::ServerSession parameters:

	$params->{FS_FWD_PING_REQUEST} = $PROTOCOL_PING if $params->{FS_FWD_PORT};
	$params->{SEND_EXIT} = 1;
		# whether to send an EXIT on shutdown

	# IO::Socket:SSL::DEBUG gets set to the highest
	# value specified by any packages:

	if ($params->{FS_SSL})
	{
		my $cur = $IO::Socket::SSL::DEBUG || 0;
		my $set = $params->{FS_DEBUG_SSL} || 0;
		$IO::Socket::SSL::DEBUG = $set if $set > $cur;
	}

	display_hash($dbg_server,0,"Server::new()",$params);
	my $this = shared_clone($params);
	$this->{running} = 0;
	$this->{stopping} = 0;
    bless $this,$class;
	$this->start();
	return $this;
}


sub createSession
	# this method overriden in derived classes
	# to create different kinds of sessions
{
	my ($this,$sock) = @_;
	return Pub::FS::ServerSession->new({
		SOCK => $sock,
		IS_SERVER => 1 });
}


sub inc_running
{
    my ($this) = @_;
	$this->{running}++;
	display($dbg_server+1,0,"inc_running($this->{running})");
}


sub dec_running
{
    my ($this) = @_;
	$this->{running}-- if $this->{running};
	display($dbg_server+1,0,"dec_running($this->{running})");
}


sub stop
{
    my ($this) = @_;
    my $TIMEOUT = 5;
    my $time = time();
    $this->{stopping} = 1;

	Pub::PortForwarder::stop() if $port_forwarder;
	$port_forwarder = undef;

    while ($this->{running} && time() < $time + $TIMEOUT)
    {
        display($dbg_server,0,"waiting for FS::Server on port($this->{FS_PORT}) to stop");
        sleep(0.2);
    }
    if ($this->{running})
    {
        error("FS::Server STOPPED with $this->{running} existing threads");
    }
    else
    {
        LOG(0,"FS::Server STOPPED sucesfully");
    }
}


sub start
{
    my ($this) = @_;
    display($dbg_server,0,ref($this)." STARTING on port($this->{FS_PORT})");
    $this->inc_running();
    $server_thread = threads->create(\&serverThread,$this);
    $server_thread->detach();
    return $this;
}


sub notifyAll
{
	my ($msg) = @_;
	display($dbg_notifications,-2,"notifyAll($msg)");
	my $num = $num_notify_all++;
	$notify_all->{$num} = shared_clone({
		msg => $msg,
		notified => shared_clone({}),
	});
}


#-----------------------------------------------------
# serverThread()
#-----------------------------------------------------

sub serverThread
{
    my ($this) = @_;
    display($dbg_server+1,-2,"serverThread started with PID($$)");

    my $server_socket = IO::Socket::INET->new(
        LocalPort => $this->{FS_PORT},
		LocalHost => $this->{FS_HOST},
        Type => SOCK_STREAM,
        Reuse => 1,
        Listen => 10);

    if (!$server_socket)
    {
        $this->dec_running();
        error("Could not create server socket: $@");
        return;
    }

	if (!$this->{FS_PORT})
	{
		$ACTUAL_SERVER_PORT = $server_socket->sockport();
		$this->{FS_PORT} = $ACTUAL_SERVER_PORT;
		warning($dbg_server,0,"SERVER STARTED ON ACTUAL_PORT($ACTUAL_SERVER_PORT)");
	}

	# forward the Port if asked to
	# Pub::ForwardPort start() is re-entrant

	if ($this->{FS_FWD_PORT})
	{
		# the PortForwarder needs the SSL parameters from preferences
		# so that it can do a standard HTTP PING.
		# Here we duplicate the FS parameters, removing the FS_ prefix
		# so that portForwder can use them.

		my $fwd_params = copyParamsWithout($this,"FS_");
		$port_forwarder = Pub::PortForwarder->new($fwd_params);
		Pub::PortForwarder::start() if $port_forwarder;
	}

    # loop accepting connectons from clients
	# and wait for all threads to stop if stopping

    my $WAIT_ACCEPT = 1;
    display($dbg_server+1,1,'Waiting for connections ...');
    my $select = IO::Select->new($server_socket);
    while ($this->{running}>1 || (
		   $this->{running} && !$this->{stopping}))
    {
        if ($select->can_read($WAIT_ACCEPT))
        {
            $connect_num++;
            my $client_socket = $server_socket->accept();
            binmode $client_socket;

            my $peer_addr = getpeername($client_socket);
            my ($peer_port,$peer_raw_ip) = sockaddr_in($peer_addr);
            my $peer_name = gethostbyaddr($peer_raw_ip,AF_INET);
            my $peer_ip = inet_ntoa($peer_raw_ip);
            $peer_name = '' if (!$peer_name);

            $this->inc_running();

            if ($USE_FORKING)
            {
                display($dbg_server+1,1,"fs_fork($connect_num) ...");
                my $rslt = fork();
                if (!defined($rslt))
                {
                    $this->inc_running(-1);
                    error("FS_FORK($connect_num) FAILED!");
                    next;
                }
                if (!$rslt)
                {
                    display($dbg_server,0,"FS_FORK_START($connect_num) pid=$$");
					$this->sessionThread($connect_num,$client_socket,$peer_ip,$peer_port);
					display($dbg_server,0,"FS_FORK_END($connect_num) pid=$$");
					exit()
                }
                display($dbg_server+1,1,"fs_fork($connect_num) parent continuing");

            }
            else	# !USE_FORKING
            {
                display($dbg_server+1,1,"starting sessionThread");
				$client_thread = threads->create(	# barfs: my $thread = threads->create(
					\&sessionThread,$this,$connect_num,$client_socket,$peer_ip,$peer_port);
				$client_thread->detach(); 			# barfs: $thread->detach();
                display($dbg_server+1,1,"back from starting sessionThread");
            }
        }
        else
        {
            display($dbg_server+2,0,"not can_read()");
        }

		# Server Idle Processing
		# clear any finished pending notifyAll messages

		for my $num (sort keys %$notify_all)
		{
			my $notify = $notify_all->{$num};
			my $got_all = 1;
			for my $c_num (keys %$active_connections)
			{
				if (!$notify->{notified}->{$c_num})
				{
					$got_all = 0;
					last;
				}
			}

			if ($got_all)
			{
				display($dbg_notifications,-1,"Clearing notifyAll: $notify->{msg}");
				delete $notify_all->{$num};
			}
        }
    }

    $server_socket->close();
    LOG(0,"serverThread STOPPED");
	$this->{running} = 0;

}   # serverThread()



#----------------------------------------------------------------------
# sessionThread()
#----------------------------------------------------------------------

sub sessionThread
{
    my ($this,$connect_num,$client_socket,$peer_ip,$peer_port) = @_;
	$peer_ip ||= '';
	$peer_port ||= '';
    display($dbg_server+1,-2,"SESSION THREAD($connect_num) FROM $peer_ip:$peer_port WITH PID($$)");

	if ($this->{FS_SSL})
	{
		my $dbg_ssl = $this->{FS_DEBUG_SSL} ? 0 : 1;
		display($dbg_server + $dbg_ssl,1,"starting SSL");

		# Upgrading to SSL requires SSL_CERT_FILE and SSL_KEY_FILE.
		# if SSL_CA_FILE is provided, the server will use SSL_VERIFY_PEER
		# to verify the client certificate agains the CA file.
		# This is HIGHLY RECOMMENDED for any public facing servers.

		my $ok = IO::Socket::SSL->start_SSL($client_socket,
			SSL_server => 1,
			SSL_cert_file 		=> $this->{FS_SSL_CERT_FILE},
			SSL_key_file 		=> $this->{FS_SSL_KEY_FILE},
			SSL_ca_file 		=> $this->{FS_SSL_CA_FILE},
			SSL_client_ca_file 	=> $this->{FS_SSL_CA_FILE},
			SSL_verify_mode 	=> $this->{FS_SSL_CA_FILE} ? SSL_VERIFY_PEER  : SSL_VERIFY_NONE,
			SSL_verify_callback => $this->{FS_DEBUG_SSL} ? \&verifySSLCallback : '',
		);

		if (!$ok)
		{
			error("Could not start SSL socket: ".IO::Socket::SSL::errstr());
			$client_socket->close();
			$this->dec_running();
			return;
		}
		display($dbg_server + $dbg_ssl,1,"SSL STARTED");
	}

	$active_connections->{$connect_num} = 1;

	my $session = $this->createSession($client_socket);

	my $ok = 1;
	my $packet;
	my $err = $session->getPacket(\$packet,1);
	if ($err)
	{
		$ok = 0;
	}
    elsif (!defined($packet) || !$packet)
    {
        error("EMPTY LOGIN");
		$ok = 0;
	}
	elsif ($packet eq $PROTOCOL_PING)
	{
		display($dbg_server+1,0,$PROTOCOL_PING);
		$session->sendPacket($PROTOCOL_PING." ".$PROTOCOL_OK);
		sleep(1);
		goto PING_EXIT;
	}
	elsif ($packet !~ /^$PROTOCOL_HELLO (.*)$/)
	{
        error("BAD LOGIN '$packet'");
		$ok = 0;
	}
	else
	{
		my $client_id = $1;
		$client_id =~ s/\s+$//;
		$session->{CLIENT_ID} = $client_id;
		LOG(-1,"CONNECTION($connect_num) $session->{NAME} FROM $client_id\@$peer_ip:$peer_port");
	}

	# sendPacket reports and returns an error on failure

	my $is_win = "is_win(".(is_win()?1:0).")";

	$packet = "$PROTOCOL_WASSUP\t$is_win\t$session->{SERVER_ID}";
	if ($ok && $session->sendPacket($packet,1))
	{
        error("COULD NOT SEND $PROTOCOL_WASSUP");
		$ok = 0
	}

    #---------------------------------------------
    # process commands until exit
    #---------------------------------------------
    # do not report unknown commands to hackers

    my $rslt = -1;
	my $select = IO::Select->new($client_socket);
    my $got_exit = 0;
    while ($ok && !$this->{stopping})
    {
		if ($select->can_read(0.1))
		{
			# any errors in getPacket will terminate the thread

            last if $session->getPacket(\$packet,1);
			last if $this->{stopping};

			if ($packet =~ /^EXIT/)
			{
				$got_exit = 1;
				last;
			}
			else
			{
				last if !$this->processPacket($session,$packet);
			}
		}

		# exit the session if the socket went away

		if (!$session->{SOCK})
		{
		    display($dbg_server,0,"SESSION THREAD($connect_num) lost it's socket!");
			last;
		}

		# send any pending notifyAll messages
		# a failure to send will end the thread

		for my $num (sort keys %$notify_all)
		{
			my $notify = $notify_all->{$num};
			if (!$notify->{notified}->{$connect_num})
			{
				$notify->{notified}->{$connect_num} = 1;
				display($dbg_notifications,-2,"THREAD($connect_num) sending notify $notify->{msg}");
				if ($session->sendPacket($notify->{msg}))
				{
					$ok = 0;
					last;
				}
			}
		}

	}	# while $ok && !stopping

    display($dbg_server,0,"SESSION THREAD($connect_num) terminating ".
		"SOCK(".($session->{SOCK}?1:0).") SEND_EXIT($this->{SEND_EXIT}) GOT_EXIT($got_exit)");

	if (!$got_exit &&
		$session->{SOCK} &&
		$this->{SEND_EXIT})
	{
		# no error checking
		$session->sendPacket($PROTOCOL_EXIT);
		sleep(0.2);
	}

PING_EXIT:

	delete $active_connections->{$connect_num};

	undef $session->{SOCK};
    $client_socket->close();
    $this->dec_running();

}



sub processPacket
	# Returns 1 upon success and 0 upon failure.
	# 0 terminates the sessionThread and session.
	#
	# This base class calls $session->doCommand()
	# with the local file system as the context,
	# and sends the result from it back over the
	# socket connection to the client.
{
	my ($this,$session,$packet) = @_;
	$packet =~ s/\s+$//g;
	my @lines = split(/\r/,$packet);
	my $line = shift @lines;

	my ($command,
		$param1,
		$param2,
		$param3) = split(/\t/,$line);

	display($dbg_server,0,show_params("processPacket",$command,$param1,$param2,$param3)." lines=".scalar(@lines));

	my $new_param2 = $param2;
	my $new_param3 = $param3;
	my $pentries = $command eq "PUT" ? \$new_param3 : \$new_param2;
	if (@lines)
	{
		$$pentries = {};
		for my $line (@lines)
		{
			my $info = Pub::FS::FileInfo->fromText($line,1);
			if (isValidInfo($info))
			{
				$$pentries->{$info->{entry}} = $info;
			}
			else
			{
				error($info);
			}
		}
	}

	# The local file system is the context for command requests
	# received by this base Server.

	$session->{progress} = $session;
	my $rslt = $session->doCommand($command,$param1,$new_param2,$new_param3);
	$rslt ||= '';

	# Stops the thread/session if it can't send the packet

	my $retval = 1;
	my $new_packet = isValidInfo($rslt) ? $session->listToText($rslt) : $rslt;
	$retval = 0 if $new_packet && $session->sendPacket($new_packet);
	return $retval;
}



1;
