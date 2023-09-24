#-------------------------------------------------------
# fileServer.pm - a local file Server
#-------------------------------------------------------
# Takes a single optional argument for the port,
# where 0 will pick a random port. Otherwise
# uses $DEFAULT_PORT defined in Session.pm

package Pub::FC::fileServer;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::FS::Server;
use Pub::FS::Session;
use Pub::FS::Server;
use Pub::Utils;
use base qw(Pub::FS::Server);


sub new
{
	my ($class,$params) = @_;
	$params ||= {};
	$params->{PORT} = $ARGV[0];
	$params->{SEND_EXIT} = 1;
	my $this = $class->SUPER::new($params);
	return if !$this;
    bless $this,$class;
	return $this;
}



my $file_server = Pub::FC::fileServer->new();

while (1)
{
	sleep(10);
}

1;
