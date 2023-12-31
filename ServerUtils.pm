#---------------------------------------
# Pub::ServerUtils.pm
#---------------------------------------
# Provides common initialization routine for programs
# that run as Services and/or require Wifi.
#
# This is run after of Pub::Utils::init_utils() which already
# knows to not output anything to STDOUT if $AS_SERVICE.
#
# init_server_utils($requires_wifi,$pid_file)
#
#	For linix fully qualified name of $pid_file must be provided.
#   This method will first daemonize the process by ensuring that
#   STDOUT, STDIN, and STDERR are properly redirected, writing the
#   PID file, and forking.
#
#   On either platform, if $requires_wifi, it will then start a
#   thread to 'monitor' the wifi state, setting $wifi_connected
#   and $server_ip when it is connected.
#
#   It is generally assumed that these servers run on a fixed IP
#   address, so $server_ip is not cleared when the device goes
#   offline, but it COULD theoretically change on subsquent
#   connections.  A later version of this *might* provide a
#   onWifiChanged() callback method.
#
# startWifiThread()
#
#	This method *could* be called separately.


package Pub::ServerUtils;
use strict;
use warnings;
use POSIX qw(setsid);
use Pub::Utils;


my $dbg_su = 0;
my $dbg_wifi = 0;


my $REPORT_RSSI = 1;
	# report RSSI on linux every $RSSI_REPORT_TIME seconds
my $WIFI_REFRESH_TIME_INIT = 1;
my $WIFI_REFRESH_TIME_NORMAL = 15;
my $RSSI_REPORT_TIME = 900;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
	    $server_ip
		$wifi_connected
	);
}



our $server_ip:shared = '';
our $wifi_connected:shared = 0;



sub initServerUtils
{
	my ($requires_wifi, $pid_file) = @_;
	LOG(-1,"initServerUtils($requires_wifi,$pid_file");

	start_unix_service($pid_file) if $AS_SERVICE && !is_win();
	if ($requires_wifi)
	{
		my $wifi_count = 0;
		startWifiThread();
		while (!$wifi_connected)
		{
			display(0,0,"Waiting for wifi connection ".$wifi_count++);
			sleep(1);
		}
		display(0,0,"wifi Connected at $server_ip");
	}

	display($dbg_su,0,"initServerUtils() returning");
}



#--------------------------------------
# daemonize for unix servers
#--------------------------------------

sub myDie
{
	my ($msg) = @_;
	error("myDie($msg)");
	exit (0);
}



sub start_unix_service
{
	my ($pid_file) = @_;
	
    LOG(0,"start_unix_service($pid_file) pid=$$");

    # otherwise child process hang around
    # as defunct after the exit if MULTI_THREADED

	$SIG{CHLD} = 'IGNORE';

    # remove pid file if it already exists
    # more correct behavior might be to die

    if (-e $pid_file)
    {
        display($dbg_su,1,"Warning: pid file $pid_file already exists ... unlinking");
        unlink $pid_file;
    }

    # do stuff necessary for daemone

    chdir '/' or myDie "Can't chdir to /: $!";
    open STDIN, '/dev/null'  or myDie "Can't open STDIN to /dev/null: $!";
	open STDOUT,">>$logfile" or myDie "Can't open STDOUT to >> $logfile: $!";
	open STDERR,">>$logfile" or myDie "Can't open STDERR to >> $logfile: $!";

    # fork off the child process

    display($dbg_su,1,"about to fork(1)");
  	if (fork())
	{
        display($dbg_su,1,"inside first fork");
        while (!(-e $pid_file))
        {
            display($dbg_su,1,"inside fork(1) - parent $$ waiting for pid file");
            sleep(1);
        }
        display($dbg_su,1,"parent $$ got pid file, exiting");
    	exit;
  	}
    LOG(1,"after fork(1) child=$$");

    # continuing child

	my $PIDFILE;
    display($dbg_su,1,"opening PID file($pid_file)");
    if (!open($PIDFILE,">$pid_file"))
	{
		error("Could not open PIDFILE $pid_file");
		exit 1;
	}
    print $PIDFILE $$."\n";
    close $PIDFILE;
    display($dbg_su,1,"PID file opened");

    # finish up, setsid and umask

	if (!setsid())
	{
		error("Can't start a new session: $!");
		exit 1;
	}

    umask 0;
    LOG(1,"child Process($$) started");

}


sub finish_unix_service
{
	my ($pid_file) = @_;
    LOG(-1,"finish_unix_service($pid_file)");
    unlink $pid_file;
}



sub startWifiThread
{
    LOG(-1,"startWifiThread()");
	my $wifi_thread = threads->create(\&wifiThread);
	$wifi_thread->detach();
	display($dbg_su,0,"startWifiThread() returning");
}



sub wifiThread
{
    display($dbg_su,0,"wifiThread() started");
    my $last_check = 0;
    my $last_report = 0;
	my $wifi_rssi = 0;

    while (1)
    {
        my $now = time();
		my $use_interval = $server_ip ?
			$WIFI_REFRESH_TIME_NORMAL :
			$WIFI_REFRESH_TIME_INIT;

        if ($now > $last_check + $use_interval)
        {
            $last_check = $now;
            my $got_connected = 0;
            display($dbg_wifi+1,0,"checking wifi ...");
            if (is_win())
            {
                my $text = `ipconfig /all`;
                my @parts = split(/Wireless LAN adapter Wi-Fi:/,$text);
                if (@parts > 1)
                {
                    if ($parts[1] =~ /IPv4 Address.*:\s*(\d+\.\d+\.\d+\.\d+)/)
                    {
                        $server_ip = $1;
                        display($dbg_wifi+1,-1,"win wifi connected with ip=$server_ip");
                        $got_connected = 1;
                    }
                    else
                    {
                        warning($dbg_wifi+1,-1,"win wifi disconnected!");
                    }
                }
            }
            else    # rPi
            {
				my $text = `ifconfig`;
				my @parts = split(/wlan0:/,$text);
                if (@parts > 1)
                {
                    if ($parts[1] =~ /inet\s*(\d+\.\d+\.\d+\.\d+)\s+/)
                    {
                        $server_ip = $1;
                        display($dbg_wifi+1,-1,"linux wifi connected with ip=$server_ip");
                        $got_connected = 1;
                    }
                    else
                    {
                        warning($dbg_wifi+1,-1,"linux wifi disconnected!");
                    }
				}
			}

			if (!is_win() && $got_connected &&
				$now > $last_report + $RSSI_REPORT_TIME)
			{
				$last_report = $now;
	            my $text = `iwconfig wlan0`;
                my $wifi_ssid = $text =~ /ESSID:"(.*?)"/ ? $1 : 'unknown';
				if ($text =~ /Signal level=(-\d+)/)
				{
					my $rssi = $1;
					$wifi_rssi = $rssi if abs($wifi_rssi - $rssi) > 4;
				}
				LOG(-1,"SSID=$wifi_ssid RSSI=$wifi_rssi");
			}

            if ($got_connected != $wifi_connected)
            {
                LOG(-1,"=============== WIFI ".($got_connected?"CONNECTED($server_ip)":"DISCONNECTED")." ===============");
                $wifi_connected = $got_connected;
                $wifi_rssi = 0 if !$got_connected;
            }
        }

		sleep(1);

    }	# endless loop
}



1;
