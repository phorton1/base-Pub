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
use Pub::FS::ServerSession;
use Pub::Utils;
use Pub::Prefs;
use Pub::ServerUtils;
use Pub::PortForwarder;
use base qw(Pub::FS::Server);
use sigtrap 'handler', \&onSignal, qw(normal-signals);


my $file_server;
my $port_forwarder;


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
	$params->{SEND_EXIT} 	 = 1;
	$params->{SSL} 			 = getPref('SSL') || 0;
	$params->{PORT} 		 = getPref('PORT') || ($params->{SSL} ? $DEFAULT_SSL_PORT : $DEFAULT_PORT);
	$params->{DEBUG_SSL} 	 = getPref('DEBUG_SSL') || 0;
	$params->{SSL_CERT_FILE} = getPref('SSL_CERT_FILE');	# required public certificate
	$params->{SSL_KEY_FILE}  = getPref('SSL_KEY_FILE');		# required private key
	$params->{SSL_CA_FILE}   = getPref('SSL_CA_FILE');		# optional public CA certificate

	my $this = $class->SUPER::new($params);
	return if !$this;
    bless $this,$class;

	if (getPref('FWD_PORT'))
	{
		my $fwd_params = {};
		$fwd_params->{PORT}		      = $params->{PORT};
		$fwd_params->{FWD_PORT} 	  = getPref('FWD_PORT');
		$fwd_params->{FWD_USER} 	  = getPref('FWD_USER');
		$fwd_params->{FWD_SERVER} 	  = getPref('FWD_SERVER');
		$fwd_params->{FWD_SSH_PORT}   = getPref('FWD_SSH_PORT');
		$fwd_params->{FWD_KEYFILE}    = getPref('FWD_KEYFILE');
		$fwd_params->{IS_FILE_SERVER} = 1;

		$port_forwarder = Pub::PortForwarder->new($fwd_params);
		Pub::PortForwarder::start();
	}

	return $this;
}



#----------------------------------------
# main
#----------------------------------------
# I am standardizing on /base_data/data as the location of persistent configuration files
# I need to try restricting the rights on these directories and files
#
# base_data/_ssl
#	phortonCA.crt
#   fileServer.crt
#	fileServer.key
#   phorton.net.crt
#	phorton.net.key
#
# base_data/data
#	fileServer/
#		fileServer.prefs
#	myIOTServer/
#		myIOTServer.prefs
#		users.txt
#	buddy/  (windows only)
#		fileClient.prefs
#		fileClient.ini
#	gitUI/  (windows only)
#		gitUI.ini
#
# base_data/temp
#	fileServer.log - the OLD fileServer (6801) log file
#	artisan/
#		artisan.pid (unix only)
#		artisan.log
#		semi persistant caching of artisan state
#	fileServer/
#		fileServer.pid (unix only)
#		fileServer.log (new - 5872/3 logfile)
#	myIOTServer/
#		myIOTServer.pid (unix only)
#		myIOTServer.log
#	gitUI/
#		cache of github repo json requests
#	Rhapsody/
#		google translate built-in cache
#		inventory.log


setStandardTempDir('fileServer');
	# /base_data/temp
	# or Cava Packaged $ENV{USERPROFILE}."/AppData/Local/Temp"
setStandardDataDir('fileServer');
	# /base_data/data
	# or Cava Packaged ENV{USERPROFILE}."/Documents

# $logfile = "$temp_dir/fileServer.log";

Pub::Utils::initUtils(1);
	# AS_SERVICE
Pub::ServerUtils::initServerUtils(1,"$temp_dir/fileServer.pid");
	# needs_wifi, unix PID file

# prefs needed for SSL parameters

Pub::Prefs::initPrefs("$data_dir/fileServer.prefs");

# create the fileServer

$file_server = Pub::FS::fileServer->new();

# loop forever

while (1)
{
	sleep(1);
}



1;
