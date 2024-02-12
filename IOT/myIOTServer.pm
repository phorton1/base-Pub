#!/usr/bin/perl
#-----------------------------------------------------
# Pub::IOT::IOTServer.pm
#-----------------------------------------------------
# The Server for my IOT Server running on the rPi

package Pub::IOT::myIOTServer;
	# continued in Pub::IOT::HTTPServer.pm
use strict;
use warnings;
use threads;
use threads::shared;
use Sys::MemInfo;
use Time::HiRes qw(sleep);
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use Pub::Utils;
use Pub::Prefs;
use Pub::DebugMem;
use Pub::ServerUtils;
use Pub::PortForwarder;
use Pub::HTTP::ServerBase;
use Pub::IOT::Device;
use Pub::IOT::HTTPServer;
use Pub::IOT::Searcher;
use Pub::IOT::Wifi;
use Pub::IOT::WSLocal;
use Pub::IOT::WSRemote;
use base qw(Pub::HTTP::ServerBase);
use sigtrap qw/handler signal_handler normal-signals/;
	# start signal handlers

my $dbg_main = 0;

my $IOT_SERVER_PORT = 6902;


our $do_restart:shared = 0;
our $last_connected = 0;


#--------------------------------------
# HTTPS Server start method
#--------------------------------------

my $https_server;

sub startHTTPS
{
	# because there is a preference file, we do NOT
	# pass in many parameters.  They can explicity
	# be added to $params herer to override anything from
	# the prefs file.

	# Otherwise, we set some defaults here, which can
	# be overriden in the prefs file.

	my $params = {};

	getObjectPref($params,'HTTP_PORT',			$IOT_SERVER_PORT);
	getObjectPref($params,'HTTP_SSL',			1);
	getObjectPref($params,'HTTP_SSL_CERT_FILE',	"/base_data/_ssl/myIOTServer.crt");
	getObjectPref($params,'HTTP_SSL_KEY_FILE',	"/base_data/_ssl/myIOTServer.key");
	getObjectPref($params,'HTTP_AUTH_FILE',		"$data_dir/users.txt");
	getObjectPref($params,'HTTP_AUTH_REALM',	"myIOTServer");
	getObjectPref($params,'HTTP_DOCUMENT_ROOT',	"/base/Pub/IOT/site");

	$https_server = Pub::IOT::myIOTServer->new($params);
	$https_server->start();
}


#------------------------------------------
# start and stop everything
#------------------------------------------

sub stopEverything
{
	LOG(-1,"Stopping Searcher");
	Pub::IOT::Searcher::stop();
	LOG(-1,"Searcher STOPPED");

	if ($https_server)
	{
		LOG(-1,"stopping HTTPS Server");
		$https_server->stop();
		$https_server = undef;
		LOG(-1,"HTTPS Server STOPPED");
	}

	LOG(-1,"Stopping WSRemote");
	Pub::IOT::WSRemote::stop();
	LOG(-1,"WSRemote STOPPED");

	LOG(-1,"Stopping WSRemote");
	Pub::IOT::WSLocal::stop();
	LOG(-1,"WSRemote STOPPED");
}


sub startEverything
{
	Pub::IOT::WSRemote::start();

	# Should be a check on the success of starting the HTTPS server
	# and if it doesn't work, bail and re-schedule the whole thing.

	startHTTPS();
	while (!Pub::IOT::Searcher::start(\&Pub::IOT::Device::add))
	{
		display(0,0,"waiting 3 seconds to restry starting Searcher");
		sleep(3);
	}
}


#-------------
# Begin
#-------------

$login_name = '';

my $program_name = 'myIOTServer';

setStandardTempDir($program_name);
	# /base_data/temp/myIOTServer
setStandardDataDir($program_name);
	# /base_data/data/myIOTServer

$logfile = "$temp_dir/$program_name.log";

Pub::Utils::initUtils(1,0);
	# 1 == AS_SERVICE
	# 0 == QUIET
Pub::ServerUtils::initServerUtils(1,"$temp_dir/$program_name.pid");
	# 1 == NEEDS WIFI
	# '' == LINUX PID FILE

display($dbg_main,0,"----------------------------------------------");
display($dbg_main,0,"$program_name.pm starting");
display($dbg_main,0,"----------------------------------------------");


Pub::Prefs::initPrefs("$data_dir/$program_name.prefs","/base_data/_ssl/PubCryptKey.txt");

LOG(-1,"myIOTServer started ".($AS_SERVICE?"AS_SERVICE":"NO_SERVICE")."  server_ip=$server_ip");

# Start the Wifi Monitor and Wait for Wifi to Start
# This is already done by initServerUtils, but we monitor the wifi

my $wifi_count = 0;
Pub::IOT::Wifi::start();
while (!Pub::IOT::Wifi::connected())
{
	display(0,0,"Waiting for wifi connection ".$wifi_count++);
	sleep(1);
}



#--------------------------------------
# Main
#--------------------------------------
# For good measure there could be PREFERENCES to
# restart and/or reboot the server on a schedule of
# some sort.  Having just put in the PING stuff, I
# am going to see if it now finally stays alive
# for a while.


my $MEMORY_REFRESH = 7200;		# every 2 hours
my $memory_time = 0;


while (1)
{
	if ($last_connected != Pub::IOT::Wifi::connected())
	{
		$last_connected = Pub::IOT::Wifi::connected();
		if ($last_connected)
		{
			sleep(5);
			startEverything();
			debug_memory("at start");
		}
		else
		{
			stopEverything();
			sleep(5);
		}
	}
	elsif ($last_connected)
	{
		# not threaded port forwarder
		# Pub::IOT::PortForwarder::loop()
		Pub::IOT::Device::loop();
		Pub::IOT::WSLocal::loop();
		Pub::IOT::WSRemote::loop();
	}


	my $now = time();
	if ($MEMORY_REFRESH && ($now > $memory_time + $MEMORY_REFRESH))
	{
		$memory_time = $now;
		debug_memory("in loop");
	}

	if ($do_restart && time() > $do_restart + 5)
	{
		$do_restart = 0;
		LOG(0,"RESTARTING SERVICE");
		system("sudo systemctl restart myIOTServer.service");
	}
}



#----------------------------------
# Signal Handler
#----------------------------------
# good candidate for a global method in Pub::ServerUtils

sub signal_handler
{
	my ($sig) = @_;
	my $thread = threads->self();
	my $id = $thread ? $thread->tid() : "undef";

    LOG(-1,"CAUGHT SIGNAL: SIG$sig  THREAD_ID=$id");

	# We catch SIG_PIPE (there's probably a way to know the actual signal instead of using its 'name')
	# on the rPi for the WSLocal connection when a device reboots.  We have to return from the signal
	# or else the server will shut down.

	return if $sig =~ 'PIPE';
	stopEverything();
    LOG(-1,"FINISHED SIGNAL");
	kill 9,$$;	# exit 1;
}


# Never Gets here

LOG(0,"myIOTServer finishing");

1;
