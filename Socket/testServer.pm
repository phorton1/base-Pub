#!/usr/bin/perl
#-------------------------------------------------------
# Pub::Socket::testServer.pm
#-------------------------------------------------------
# This is an example application wrapped around
# Pub::Socket::ServerBase

package Pub::Socket::testServer;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Socket::ServerBase;
use base qw(Pub::Socket::ServerBase);
use sigtrap 'handler', \&onSignal, qw(normal-signals);

my $ssl_cert_dir = "/dat/private/ssl/esp32";


my $DEFAULT_PORT = 5872;
my $USE_SSL = 1;
my $DEBUG_SSL = 0;
my $SSL_CERT_FILE = "$ssl_cert_dir/myIOT.crt";
my $SSL_KEY_FILE  = "$ssl_cert_dir/myIOT.key";
	# required if USE_SSL
my $SSL_CA_FILE = "$ssl_cert_dir/_myESP32_CA.crt";
	# optional turns on server validation of peer certs



sub new
{
	my ($class) = @_;

	my $params = {
		SSL  => $USE_SSL,
		PORT =>	$DEFAULT_PORT,
	};

	if ($USE_SSL)
	{
		$params->{DEBUG} = $DEBUG_SSL;
		$params->{SSL_CERT_FILE} = $SSL_CERT_FILE;
		$params->{SSL_KEY_FILE}  = $SSL_KEY_FILE;
		$params->{SSL_CA_FILE} = $SSL_CA_FILE;
	}

	my $this = $class->SUPER::new($params);
	return if !$this;
    bless $this,$class;
	return $this;
}



my $server = Pub::Socket::testServer->new();

while (1)
{
	sleep(1);
}


sub onSignal
{
    my ($sig) = @_;
	warning(0,0,"testServer.pm terminating on SIG$sig");
	exit(0);
}


1;
