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


# init Pub::Utils
# we do NOT call complicated MBE related init_my_utils()
#
# 2024-02-08 standardize on /base_data/temp/myIOTServer and
# /base_data/data/myIOTServer which will contain myIOTServer.prefs.
# All certificates are now duplicated and reused from in /home/pi/phortonCA
#
$login_name = '';

$temp_dir = "/base_data/temp/myIOTServer";
$data_dir = "/base_data/data/myIOTServer";

$logfile  = "$temp_dir/myIOTServer.log";

display(0,0,"temp_dir=$temp_dir");
display(0,0,"data_dir=$data_dir");


# Constants

# my $SEARCH_URN = "upnp:rootdevice";
my $SEARCH_URN = "urn:myIOTDevice";
my $DO_FORWARD_PORT = 0;
my $IOT_SERVER_PORT = 6902;
my $FILE_SERVER_PORT = 6801;

# Working Variables

my $ssl_cert_dir = "/base_data/_ssl";
my $pid_file = "$temp_dir/myIOTServer.pid";

our $do_restart:shared = 0;
our $last_connected = 0;


#--------------------------------------
# HTTPS Server start method
#--------------------------------------

my $https_server;

sub startHTTPS
{
	$https_server = Pub::IOT::myIOTServer->new({

		DEBUG_SERVER => 0,
		DEBUG_REQUEST => 0,
		DEBUG_RESPONSE => 0,

		DEBUG_QUIET_RE => '',
		DEBUG_LOUD_RE => '',

		PORT => $IOT_SERVER_PORT,
		MAX_THREADS => 5,
		# KEEP_ALIVE => 0,

		SSL => 1,
		SSL_CERT_FILE => "$ssl_cert_dir/myIOT.crt",
		SSL_KEY_FILE  => "$ssl_cert_dir/myIOT.key",

		AUTH_ENCRYPTED => 0,
		AUTH_FILE => "$data_dir/users.txt",
		AUTH_REALM => "myIOTServer",

		DOCUMENT_ROOT => "/base/Pub/IOT/site",
        ALLOW_GET_EXTENSIONS_RE => 'html|js|css|jpg|png|ico',
		DEFAULT_LOCATION => "index.html",

		# USE_GZIP_RESPONSES => 1,
		# DEFAULT_HEADERS => {},
        # ALLOW_SCRIPT_EXTENSIONS_RE => '',

	});

	$https_server->start();
}


#------------------------------------------
# start and stop everything
#------------------------------------------

sub stopEverything
{
	if ($DO_FORWARD_PORT)
	{
		LOG(-1,"Stopping PortForwarder");
		Pub::IOT::PortForwarder::stop();
		LOG(-1,"PortForwarder STOPPED");
	}

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
	while (!Pub::IOT::Searcher::start($SEARCH_URN,\&Pub::IOT::Device::add))
	{
		display(0,0,"waiting 3 seconds to restry starting Searcher");
		sleep(3);
	}

	if ($DO_FORWARD_PORT)
	{
		my $IOT_FORWARD_PORT = getPref('SERVER_FORWARD_PORT');
		Pub::IOT::PortForwarder->new(0,$IOT_SERVER_PORT,$IOT_FORWARD_PORT)
			if $IOT_FORWARD_PORT;
		my $FILE_FORWARD_PORT = getPref('FILE_FORWARD_PORT');
		Pub::IOT::PortForwarder->new(1,$FILE_SERVER_PORT,$FILE_FORWARD_PORT)
			if $FILE_FORWARD_PORT;

		# threaded forwarder

		Pub::IOT::PortForwarder::start()
			if $IOT_FORWARD_PORT || $FILE_FORWARD_PORT;

	}
}


#-------------
# Begin
#-------------

my $program_name = 'myIOTServer';

setStandardTempDir($program_name);
	# /base_data/temp/myIOTServer
	# or Cava Packaged $ENV{USERPROFILE}."/AppData/Local/Temp"
setStandardDataDir($program_name);
	# /base_data/data/myIOTServer
	# or Cava Packaged ENV{USERPROFILE}."/Documents

$logfile = "$temp_dir/$program_name.log";

Pub::Utils::initUtils(1);
	# AS_SERVICE
Pub::ServerUtils::initServerUtils(1,"$temp_dir/$program_name.pid");
	# needs_wifi, unix PID file

# prefs needed for SSL parameters

Pub::Prefs::initPrefs("$data_dir/$program_name.prefs","/base_data/_ssl/PubUtilsEncryptKey.txt");

LOG(-1,"myIOTServer started ".($AS_SERVICE?"AS_SERVICE":"NO_SERVICE")."  server_ip=$server_ip");

# Start the Wifi Monitor and Wait for Wifi to Start

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

my $this_thread = threads->self();
my $this_id:shared = $this_thread ? $this_thread->tid() : "undef";
LOG(0,"MAIN THREAD=$this_id");

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
# WITH NO SIGNAL HANDLING
# Note that I am no longer using Signal Handling
# so, broken pipes and Perl errors may crash the
# server or kill threads for the time being.
#
# TESTED ON WINDOWS (from command line)
# Doubt a windows service would be well behaved.
# The only ramification so far from not having signals is that on
# windows the sockets don't get closed with ^C and so I have to make a new
# session.
#
# It seems to have helped on Windows if I set the environment variable PERL_SIGNALS=safe
# THEY WERE ACTUALLY SET TO unsafe ON MY MACHINE!!!  which caused panics, etc, etc, etc.
# They default to safe without the env variable, so in future I should get rid of it.

sub signal_handler
{
	my $sig_name = $! || 'unknown';
	my $thread = threads->self();
	my $id = $thread ? $thread->tid() : "undef";

    LOG(-1,"CAUGHT SIGNAL: $sig_name  THREAD_ID=$id");

	# We catch SIG_PIPE (there's probably a way to know the actual signal instead of using its 'name')
	# on the rPi for the WSLocal connection when a device reboots.  We have to return from the signal
	# or else the server will shut down.

	return if $sig_name =~ 'Broken pipe';
	stopEverything();
    LOG(-1,"FINISHED SIGNAL");
	kill 6,$$;	# exit 1;
}


# Never Gets here

LOG(0,"myIOTServer finishing");

1;
