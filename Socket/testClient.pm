#!/usr/bin/perl
#-------------------------------------------------------
# Pub::Socket::testClient
#-------------------------------------------------------
# This is a simple example client that connects to
# the testServer.  The SSL settings must be appropriate
# to the server configuration.


package Pub::Socket::testClient;
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Socket::INET;
use IO::Socket::SSL;
use Pub::Utils;
use Pub::Socket::Packet;
use sigtrap 'handler', \&onSignal, qw(normal-signals);




our $dbg_client = 0;


sub onSignal
{
    my ($sig) = @_;
	warning(0,0,"testClient.pm terminating on SIG$sig");
	exit(0);
}


my $ssl_cert_dir = "/dat/private/ssl/esp32";


my $DEFAULT_PORT = 5872;
my $DEFAULT_HOST = 'localhost';		# '10.237.50.101'

my $USE_SSL = 1;
my $DEBUG_SSL = 0;
my $SSL_CA_FILE   = "$ssl_cert_dir/_myESP32_CA.crt";	# public CA certificate
my $SSL_CERT_FILE = "$ssl_cert_dir/myIOT.crt";			# public certificate
my $SSL_KEY_FILE  = "$ssl_cert_dir/myIOT.key";			# private key


#----------------------------------------------------------------
# Tests to make sure the Server does not accepts other (MBE) certs
# that are not valid by the above _myESP32_CA.crt file.
#
# (1) Our own cert is not valid if a CA is specified and it does
#     not match our cert.

if (0)
{
	$SSL_CA_FILE = "/dat/private/ssl/mbe/_mbeSystems_CA.crt";
}

# (2) The client cert is considered valid, and sent to the server,
#     if there is no client CA, or the client CA matches the cert.
#     So this block, with either option, checks that the server
#     rejects the certficate with "unknown CA".

elsif (1)
{
	1 ? $SSL_CA_FILE = "/dat/private/ssl/mbe/_mbeSystems_CA.crt" :
		$SSL_CA_FILE = '';
	$SSL_CERT_FILE = "/dat/private/ssl/mbe/mbeServer.crt";
	$SSL_KEY_FILE  = "/dat/private/ssl/mbe/mbeServer.key";
}

# end of tests
#--------------------------------------------------------------


# The parameters to connectServer are similar to, but different
# than the IO::Socket::SSL parameters.

my $test_params = {
	SSL  => $USE_SSL,
	HOST => $DEFAULT_HOST,
	PORT =>	$DEFAULT_PORT,
};

if ($USE_SSL)
{
	$test_params->{SSL_CA_FILE} = $SSL_CA_FILE;
	$test_params->{SSL_CERT_FILE} = $SSL_CERT_FILE;
	$test_params->{SSL_KEY_FILE}  = $SSL_KEY_FILE;
	$test_params->{DEBUG_SSL} = $DEBUG_SSL;
}





sub connectServer
{
	my ($prog_params) = @_;
	display_hash($dbg_client,0,"connect()",$prog_params);
	$IO::Socket::SSL::DEBUG = $prog_params->{DEBUG_SSL} if $prog_params->{DEBUG_SSL};

	#-------------------------------------------------------------
	# move prog_params to socket params and create the socket
	#-------------------------------------------------------------

    my @params = (
	 	PeerAddr => "$prog_params->{HOST}:$prog_params->{PORT}",
		PeerPort => "http($prog_params->{PORT})",
        Proto    => 'tcp',
	 	Timeout  => $DEFAULT_TIMEOUT, );

	if ($prog_params->{SSL})
	{
		push @params,(
			SSL_ca_file => $prog_params->{SSL_CA_FILE},
			SSL_cert_file => $prog_params->{SSL_CERT_FILE},
			SSL_key_file => $prog_params->{SSL_KEY_FILE},
			SSL_verify_callback => $prog_params->{DEBUG_SSL} ? \&verifyCallback : '',
		);
	}

    my $sock =  $prog_params->{SSL} ?
		IO::Socket::SSL->new(@params) :
		IO::Socket::INET->new(@params);

    if (!$sock)
    {
		my $msg = $prog_params->{SSL} ? IO::Socket::SSL::errstr() : $@;
        error("could not connect to server: $msg");
    }
    else
    {
		display($dbg_client,0,"connect() returning sock($sock)");
	}

	return $sock;
}




#-----------------------------------
# main
#-----------------------------------
# Echo any received packets and send
# 5 packets, terminating with 'EXIT'

display($dbg_client,0,"testClient.pm started");


my $sock = connectServer($test_params);
if ($sock)
{
	display($dbg_client,0,"testClient sending TEST_HELLO packet");
	sendPacket($sock,"TEST HELLO");
	display($dbg_client,0,"TEST_HELLO packet sent");

	my $count = 0;
	my $last_send = time();

	my $NUM_TEST_SENDS = 5;

	while (1)
	{
		my $packet = '';
		my $err = getPacket($sock,\$packet,0);
		if ($packet)
		{
			display($dbg_client,0,"got packet=$packet");
		}
		else
		{
			if (time() > $last_send)
			{
				$last_send = time();
				$count++;
				display($dbg_client,0,"sending packet($count)");
				my $packet = $count == $NUM_TEST_SENDS ? "EXIT" : "PACKET($count) at AT ".time();
				my $err = sendPacket($sock,$packet);
				last if $err || $count == $NUM_TEST_SENDS;
			}
			else
			{
				display($dbg_client+1,0,"testClient waiting for packets");
				sleep(1);
			}
		}
	}
}




1;
