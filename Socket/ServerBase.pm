#-------------------------------------------------
# Pub::Socket::ServerBase
#--------------------------------------------------
# This is an example of a threaded socket server that
# can optionally use SSL and specific trusted certificates.
# It simply writes "HULLO" upon connection, then echos
# any packets it recieves, until the threadedSession is
# ended by the client sending 'EXIT'.
#
# It uses select() and accept() on a regular INET socket,
# and then, if using SSL, upgrades the socket to SSL during
# the sessionThread.
#
# As a server, it always SENDS a public cert to the client which,
# by default, is verfied against a CA (certificate authority) cert
# on the client. This is the typical use of SSL to authenticate
# SERVERS to which a client attaches.
#
# To re-use this example code for an HTTP Server to a regular browser,
# the CA certificate must be installed in the browser CA store somehow,
# and the server must meet all the conditions required by modern browsers
# as they validate certificates, especially including the fact that the
# server must have a valid hostname that is in the certificate's
# list of hostnames.
#
# On the other hand, in my typical usage, I am trying to protect the
# SERVER from unknown clients. This is done by passing SSL_VERIFY_PEER to
# the the socket, in which case the server verifies the client's certificate
# against the server's CA, which is an explicit parameter as well.
#
# All of this effectivly encrypts the communications end-to-end.
# The only thing that is sent in the clear are the public certificates (SSL_cert_file)
# during the SSL handshaking.  These cannot be spoofed because he server and
# client must also have the private keys (SSL_key_file) for SSL to even use
# their public keys.
#
# None of this addresses the next level of security, Users and Passwords,
# which would normally be required in addition to the certificates, esp
# for public facing generic HTTPS servers.  But for limited internal use,
# i.e. in my FS architecture, where I am the only client in possesion of
# the CA's, certificates, AND keys, I feel it is sufficient protection.
#
# Nonetheless, I should make a new CA, not esp32 based, but phorton1 based,
# as per github, and then a specific certificate for the FS system, not
# overlapping or re-using the MBE or myIOT certificates.
#
# If any of the the keys are hacked, the whole system must be brought
# down immediately. Me, as the only client, and ALL SERVERS need to get
# new keys regenerated and placed appropriately and protected on
# every system.


package Pub::Socket::ServerBase;
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Select;
use IO::Socket::INET;
use IO::Socket::SSL;
use Time::HiRes qw( sleep );
use Pub::Utils;
use Pub::Socket::Packet;

my $dbg_server = 0;

my $server_thread;
my $client_thread;
my $connect_num = 0;


#-------------------------------------------------
# methods
#-------------------------------------------------

sub new
	# Parameters:
	#	PORT			optional, will be assigned if not provided
	#	SSL = 1 		optional parameter turns on SSL
	#	SSL_CERT_FILE	public certificate required if SSL
	#	SSL_KEY_FILE	private key required if SSL
	#	SSL_CA_FILE		optional CA public certificate causes server to validate client certs
	#	DEBUG			sets global IO::Socket::SSL debugging level for convenience
	#					and turns on debugging verifyCallback (in Packet.pm)
{
	my ($class,$params) = @_;
	display_hash($dbg_server,0,"ServerBase::new() PID($$)",$params);
	my $this = shared_clone($params);
    bless $this,$class;
	$this->start();
	display($dbg_server,0,"ServerBase::new() returning $this");
	return $this;
}



sub start
{
    my ($this) = @_;
	display($dbg_server,0,"ServerBase::start()");
	$IO::Socket::SSL::DEBUG = $this->{DEBUG} if $this->{DEBUG};
	$server_thread = threads->create(\&serverThread,$this);
	$server_thread->detach();
	display($dbg_server,0,"ServerBase::start() returning $this");
    return $this;
}






#-----------------------------------------------------
# serverThread()
#-----------------------------------------------------

sub serverThread
{
    my ($this) = @_;
	$this->{PORT} ||= '';

	display($dbg_server,0,"serverThread() PID($$) PORT($this->{PORT}) started");

    my @params = (
        Proto => 'tcp',
        LocalPort => $this->{PORT},
		Listen => SOMAXCONN,
        Reuse => 1 );

    my $server_socket = IO::Socket::INET->new(@params);

    if (!$server_socket)
    {
		my $err_msg = $@;
        error("Could not create server_socket on port($this->{PORT}}: $err_msg");
        return;
    }
	if (!$this->{PORT})
	{
		$this->{PORT} = $server_socket->sockport();
		warning($dbg_server,0,"SERVER STARTED ON ACTUAL_PORT($this->{PORT})");
	}

    # loop accepting connectons from clients
	# and wait for all threads to stop if stopping

    my $WAIT_ACCEPT = 1;
    display($dbg_server,0,'serverThread() waiting for connections ...');
    my $select = IO::Select->new($server_socket);
    while (1)
    {
        if ($select->can_read($WAIT_ACCEPT))
        {
            $connect_num++;
			display($dbg_server,0,"New connection($connect_num)");
            my $client_socket = $server_socket->accept();
			display($dbg_server,1,"client_socket="._def($client_socket));

			if (!$client_socket)
			{
				error("no client_socket from server_socket->accept()");
				next;
			}

            binmode $client_socket;

            my $peer_addr = getpeername($client_socket);
            my ($peer_port,$peer_raw_ip) = sockaddr_in($peer_addr);
            my $peer_name = gethostbyaddr($peer_raw_ip,AF_INET);
            my $peer_ip = inet_ntoa($peer_raw_ip);
            $peer_name = '' if (!$peer_name);

			display($dbg_server,1,"peer_ip($peer_ip) peer_port($peer_port)");

			display($dbg_server,1,"starting sessionThread");
			$client_thread = threads->create(	# barfs: my $thread = threads->create(
				\&sessionThread,$this,$connect_num,$client_socket,$peer_ip,$peer_port);
			$client_thread->detach(); 			# barfs: $thread->detach();
			# push @client_threads,$client_thread;
			display($dbg_server,1,"back from starting sessionThread");

		}
        else
        {
            display($dbg_server+1,0,"not can_read()");
        }

    }

    $server_socket->close();
    LOG(0,"serverThread STOPPED");


}   # serverThread()



#----------------------------------------------------------------------
# sessionThread()
#----------------------------------------------------------------------

sub sessionThread
{
    my ($this,$connect_num,$client_socket,$peer_ip,$peer_port) = @_;
    display($dbg_server,0,"SESSION THREAD($connect_num) PID($$)");
    display($dbg_server,1,"client_socket("._def($client_socket).") peer_ip("._def($peer_ip).") peer_port("._def($peer_port).")");

	if ($this->{SSL})
	{
		display($dbg_server,1,"starting SSL");

		# Upgrading to SSL requires SSL_CERT_FILE and SSL_KEY_FILE.
		# if SSL_CA_FILE is provided, the server will use SSL_VERIFY_PEER
		# to verify the client certificate agains the CA file.

		my $ok = IO::Socket::SSL->start_SSL($client_socket,
			SSL_server => 1,
			SSL_cert_file => $this->{SSL_CERT_FILE},
			SSL_key_file => $this->{SSL_KEY_FILE},
			SSL_ca_file => $this->{SSL_CA_FILE},
			SSL_client_ca_file => $this->{SSL_CA_FILE},
			SSL_verify_mode => $this->{SSL_CA_FILE} ? SSL_VERIFY_PEER  : SSL_VERIFY_NONE,
			SSL_verify_callback => $this->{DEBUG} ? \&verifyCallback : '',
		);

		if (!$ok)
		{
			error("Could not start SSL socket: ".IO::Socket::SSL::errstr());
			return;
		}
		display($dbg_server,1,"SSL STARTED");
	}

	sendPacket($client_socket,"HULLO\r\n");

    #---------------------------------------------
    # echo packets until EXIT
    #---------------------------------------------

	my $select = IO::Select->new($client_socket);
    while (1)
    {
		if ($select->can_read(0.1))
		{
			display($dbg_server+1,2,"sessionThread can_read()");

			my $packet = '';
			my $err = getPacket($client_socket,\$packet);

			display($dbg_server,2,"sessionThread got err("._def($err).") packet("._def($packet).")");

			error($err) if $err;
			last if $err;
			last if $packet =~ /^EXIT/;
		}
	}

    display($dbg_server,1,"SESSION THREAD($connect_num) terminating ");
    $client_socket->close();
}




1;
