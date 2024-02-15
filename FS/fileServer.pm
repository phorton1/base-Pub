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
use Pub::Utils;
use Pub::Prefs;
use Pub::ServerUtils;
use Pub::ServiceMain;
use base qw(Pub::FS::Server);

my $file_server;



sub new
{
	my ($class) = @_;
	my $this = $class->SUPER::new();
	return if !$this;
    bless $this,$class;
	return $this;
}



#----------------------------------------
# main
#----------------------------------------

setStandardTempDir('fileServer');
	# /base_data/temp/fileServer
	# or Cava Packaged $ENV{USERPROFILE}."/AppData/Local/Temp/fileServer"
setStandardDataDir('fileServer');
	# /base_data/data/fileServer
	# or Cava Packaged ENV{USERPROFILE}."/Documents/fileServer"

$logfile = "$temp_dir/fileServer.log";

Pub::Utils::initUtils(1);
	# AS_SERVICE
Pub::ServerUtils::initServerUtils(1,"$temp_dir/fileServer.pid");
	# needs_wifi, unix PID file

# prefs needed for SSL parameters

Pub::Prefs::initPrefs("$data_dir/fileServer.prefs");

# create the fileServer

$file_server = Pub::FS::fileServer->new();

# loop forever

Pub::ServiceMain::main_loop({
	MAIN_LOOP_CONSOLE => 1,
	MAIN_LOOP_SLEEP => 0.2,
	# MAIN_LOOP_CB_TIME => 1,
	# MAIN_LOOP_CB => \&on_loop,
	# MAIN_LOOP_KEY_CB => \&on_console_key,
	# MAIN_LOOP_TERMINATE_CB => \&on_terminate,
});



1;
