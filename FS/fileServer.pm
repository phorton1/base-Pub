#!/usr/bin/perl
#-------------------------------------------------------
# fileServer.pm - a local file Server
#-------------------------------------------------------
# Takes a single optional argument for the port,
# where 0 will pick a random port. Otherwise
# uses $DEFAULT_PORT defined in Session.pm

package Pub::FS::fileServer;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::FS::Server;
use Pub::FS::Session;
use Pub::FS::Server;
use Pub::Utils;
use base qw(Pub::FS::Server);
use sigtrap 'handler', \&onSignal, qw(normal-signals);


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



my $file_server = Pub::FS::fileServer->new();

while (1)
{
	sleep(1);
}


sub onSignal
{
    my ($sig) = @_;
	warning(0,0,"fileServer.pm terminating on SIG$sig");
	$file_server->stop() if $file_server;
	exit(0);
}


1;
