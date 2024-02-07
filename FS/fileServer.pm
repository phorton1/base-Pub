#!/usr/bin/perl
#-------------------------------------------------------
# fileServer.pm - a simple local file Server application
#-------------------------------------------------------
# Uses $DEFAULT_PORT defined in Session.pm.
#
# For ALLOW_SSL, a preference file will be utilized
# from /base_data/data/fileServer/fileServer.pref,
# which then contains the SSL parameters.
#
# If there is a preference file, then the PORT
# can be overridden in it if desirec.


package Pub::FS::fileServer;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::FS::Server;
use Pub::FS::Session;
use Pub::FS::Server;
use Pub::Utils;
use Pub::Prefs;
use Pub::ServerUtils;
use base qw(Pub::FS::Server);
use sigtrap 'handler', \&onSignal, qw(normal-signals);


my $ALLOW_SSL = 1;

my $file_server;


sub onSignal
{
    my ($sig) = @_;
	warning(0,0,"fileServer.pm terminating on SIG$sig");
	$file_server->stop() if $file_server;
	exit(0);
}


sub new
{
	my ($class,$params) = @_;
	$params ||= {};
	$params->{SEND_EXIT} = 1;
	my $this = $class->SUPER::new($params);
	return if !$this;
    bless $this,$class;
	return $this;
}



#----------------------------------------
# main
#----------------------------------------

setStandardDataDir('fileServer');

Pub::Utils::initUtils(1);
	# AS_SERVICE
Pub::ServerUtils::initServerUtils(1,"$data_dir/fileServer.pid");
	# needs_wifi, unix PID file

# prefs needed for SSL parameters

Pub::Prefs::initPrefs("$data_dir/fileServer.prefs")
	if $ALLOW_SSL;

# create the fileServer

$file_server = Pub::FS::fileServer->new();

# loop forever

while (1)
{
	sleep(1);
}



1;
