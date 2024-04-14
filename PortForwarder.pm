#!/usr/bin/perl
#-----------------------------------------------------
# Pub::PortForwarder.pm
#-----------------------------------------------------
# See old documentation in My::IOT::PortForwarder.pm
#
# An instance of the object is created for each forwarded port,
# and then the global Pub::PortForwarder::start() method is called
# which starts a thread that connects and monitors the ports.
# Although the API allows for multiple ports to be forwarded,
# in practice, only a single port is forwarded per application,
# and the isThreadRunning() method and shared $thread_runnning
# boolean is synonymous with a port being forwarded.
#
# Requires substantial external setup on a server somewhere.
# Does not use SSH passwords; uses a key file only.
# May need to be run from command line to enter password first time.
#
# Ping is implemented/driven by sending a somewhat standard single
# line requst to the server, typically of the form:
#
#	FWD_PING_REQUEST = GET /PING HTTP/1.1
#
# Any servers that need to stay alive using ping must respond
# to the request line they pass in and return a non-blank response.
#
# In specific cases (myIOTServer running on the rPi) port forwarding
# is considered a critical function and FWD_CRITICAL_RETRIES=20 is
# passed in.  Note that this can result in boot loops if there is
# a problem with the rPi SDCard, or unexpected reboots, for example,
# while listening to music (if HTTP_DO_FORWARD *and* FWD_CRITICAL_RETRIES
# are both turned on). Note also that do not consider the fileServer to
# be a 'critcal' process. If the myIOTServer succeeds in forwarding
# a port we can always reboot the rPi remotely as needed.


package Pub::PortForwarder;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Prefs;
use Pub::ServiceMain;
use LWP::UserAgent;
use IPC::Open3;
use IO::Socket::SSL;
use Symbol qw(gensym);
use POSIX "sys_wait_h";

my $DEBUG_PING_SSL = 0;


my $dbg_fwd = 0;		# -1 for pid, details
my $dbg_kill = 0;
my $dbg_ping:shared = 1;		# ping failures are hard to thoroughly test
	# $dbg_ping must be shared to be set in ctor from thread



# These parameters are generally useful, but available
# via exports if clients want to modify them.

our $FWD_REFRESH_INTERVAL = 1;
	# check status of STATE_STARTING ports every this many seconds
our $FWD_TIMEOUT = 30;
	# STATE_STARTING ports timeout after this many seconds
our $FWD_CHECK_INTERVAL = 15;	   # 60;
	# check pid and/or ping STATE_SUCCESS ports every this many seconds
our $FWD_PING_INTERVAL:shared = 300;
	# Do a ping test every this often seconds
	# has to be shared to be set from ctor in thread
our $FWD_PING_TIMEOUT = 10;
	# how long to wait for ping response
	# set to zero to disable ping testing
	# must be significantly smaller than FWD_CHECK_INTERVAL

# startup times.
# ports are started synchronously, one after another, never asynchronously
# failures schedule a restart according to the following constants

our $FWD_START_TIME_INITIAL = 3;		# initial start after new()
our $FWD_START_TIME_FAIL = 30;			# restart time after a STATE_NONE SSH failure
our $FWD_START_TIME_TIMEOUT = 30;		# restart time after a STATE_STARTING timeout
our $FWD_START_TIME_DIED = 30;			# restart time after a STATE_SUCCESS lost PID
our $FWD_START_TIME_PING_FAIL = 30;		# restart time after a STATE_SUCCESS ping failure



BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

		$FWD_REFRESH_INTERVAL
		$FWD_TIMEOUT
		$FWD_CHECK_INTERVAL
		$FWD_PING_TIMEOUT

		$FWD_START_TIME_INITIAL
		$FWD_START_TIME_FAIL
		$FWD_START_TIME_TIMEOUT
		$FWD_START_TIME_DIED
		$FWD_START_TIME_PING_FAIL

	);
}



my $FWD_STATE_NONE = 0;
my $FWD_STATE_STARTING = 1;
my $FWD_STATE_SUCCESS = 2;
my $FWD_STATE_FAIL = 3;

my $forwards = shared_clone({});

my $pf_thread;
my $fwd_check_time = 0;
my $stopping:shared = 0;
my $thread_running:shared = 0;

my $ssh_stdin;
my $ssh_stdout;
my $ssh_stderr = gensym();
	# these variables are global, but are only passed to the forked
	# ssh run by open3, and so they are not really for our address space.


sub isThreadRunning
	# in practice, this is synonymous with
	# a port being forwarded.
{
	return $thread_running;
}


# on Windows I have a plethora of ssh.exe's to chose from
# the default by path is C:\MinGW\msys\1.0\bin\ssh
# OpenSSL 1.0.0 29 Mar 2010 which does not support the -E (logfile) option
#
# C:\MinGW\msys\1.0\bin 						OpenSSL 1.0.0 29 Mar 2010
# C:\Windows\System32\OpenSSH					OpenSSH_for_Windows_8.1p1, LibreSSL 3.0.2
# C:\Program Files\Git\usr\bin					OpenSSH_8.5p1, OpenSSL 1.1.1k  25 Mar 2021
#
# Plus many other installed by updates, etc
# The one from git seems the most current and supports -E


my $DEFAULT_SSH_PORT = 22;		# standard default SSH port
my $DEFAULT_WIN_SSH_PATH = 'C:\Program Files\Git\usr\bin';


sub new
	# Params:
	#	PORT			 	= the port to be forwarded
	#	FWD_PORT			= the port to forward to
	#	FWD_USER			= user name on host
	#	FWD_SERVER			= host to forward to
	#	FWD_SSH_PORT		= SSH port on host
	#	FWD_KEYFILE			= keyfile for SSH
	#	WIN_SSH_PATH		= path to ssh.exe if is_win()
	#	FWD_PING_REQUEST	= optional "GET /PING HTTP/1.1" or similar
	#	FWD_DEBUG_PING      = optional $dbg_ping value from prefs file
	#
	# Plus if SSL, to do a standard HTTP Ping:
	#	SSLP
	#	SSL_CERT_FILE
	#	SSL_KEY_FILE}
	#	SSL_CA_FILE}
	#	DEBUG_SSL}
	#
	# Critical processes can add
	#
	#	FWD_CRITICAL_RETRIES = 20
	#
	# and the rPi will reboot, or Windows will restart the service
	# after that number of failures
{
	my ($class,$params) = @_;



	display_hash($dbg_fwd+1,0,"PortForwarder::new()",$params);

	$params->{FWD_SSH_PORT} ||= $DEFAULT_SSH_PORT;
	$params->{WIN_SSH_PATH} ||= $DEFAULT_WIN_SSH_PATH;
	$params->{FWD_PING_REQUEST} ||= '';

	if (defined($params->{FWD_DEBUG_PING}))
	{
		display($dbg_fwd,1,"setting dbg_ping to '$params->{FWD_DEBUG_PING}'");
		$dbg_ping = $params->{FWD_DEBUG_PING}
	}
	if (defined($params->{FWD_PING_INTERVAL}))
	{
		display($dbg_fwd,1,"setting PING_INTERVAL to '$params->{FWD_PING_INTERVAL}'");
		$dbg_ping = $params->{FWD_PING_INTERVAL}
	}

	if (!$params->{SSL})
	{
		error("attempt to forward non-SSL port($params->{PORT})");
		return;
	}

	my $this = shared_clone($params);

	$this->{pid} = 0;
	$this->{check_time} = 0;
	$this->{state} = $FWD_STATE_NONE;
	$this->{start_time} = time() + $FWD_START_TIME_INITIAL;
	$this->{ssh_output_file} = "$temp_dir/port.$this->{PORT}.$this->{FWD_PORT}.txt";
	$this->{fail_count} = 0;

	$this->{ssh_exe} = 'ssh';
	if (is_win())
	{
		$this->{ssh_exe} = "\"$this->{WIN_SSH_PATH}\\ssh.exe\"";
		$this->{FWD_KEYFILE} =~ s/\//\\/g;
	}

	bless $this,$class;
	$forwards->{$this->{PORT}} = $this;
	return $this;
}



sub start
{
	if ($pf_thread)
	{
		display($dbg_fwd,0,"PortForwarder thread already started");
	}
	else
	{
		display($dbg_fwd,0,"PortForwarder starting thread");
		$pf_thread = threads->create(\&portForwardThread);
		$pf_thread->detach();
	}
	display($dbg_fwd,0,"PortForwarder::start() returning 1");
	return 1;
}


sub stop
{
	if (!$stopping)
	{
		$stopping = 1;
		for my $fwd (values %$forwards)
		{
			if ($fwd->{pid})
			{
				LOG(-1,"Killing fwd($fwd->{PORT} to $fwd->{FWD_PORT}) pid=$fwd->{pid}");
				kill 9, $fwd->{pid};
				undef $fwd;
			}
		}
		$forwards = {};
	}

	if ($thread_running)
	{
		my $STOP_THREAD_TIMEOUT = 3;
		my $time = time();
		while ($thread_running && time() <= $time + $STOP_THREAD_TIMEOUT)
		{
			display($dbg_fwd-1,0,"Waiting for PortForwardThread to stop");
			sleep(1);
		}
		LOG(-1,"PortforwardeThread ".($thread_running?"NOT STOPPED!!":"STOPPED"));
	}
}


sub portForwardThread
{
	$thread_running = 1;
	LOG(-1,"portForwardThread started");
	while (!$stopping)
	{
		threadBody();
		sleep(1);
	}
	$thread_running = 0;
	threads->exit();
}


sub threadBody
{
	return if $stopping;

	# outer timing logic is redundant in threaded version

	my $now = time();
	if ($now > $fwd_check_time + $FWD_REFRESH_INTERVAL)
	{
		$fwd_check_time = $now;

		# check any that are starting
		# this loop gets priority to serialize the starts

		for my $fwd (values %$forwards)
		{
			if ($fwd->{state} == $FWD_STATE_STARTING)
			{
				return if $stopping;
				$fwd->checkStart();
				return;
			}
		}

		# check if any have died

		for my $fwd (values %$forwards)
		{
			if ($fwd->{state} == $FWD_STATE_SUCCESS &&
				$now > $fwd->{check_time} + $FWD_CHECK_INTERVAL)
			{
				$fwd->{check_time} = $now;
				return if $stopping;
				my $rslt = waitpid($fwd->{pid},WNOHANG);
					# returns 0 for still running, the pid if stopped, or -1 on error
				display($dbg_fwd+1,-1,"FWD_PID($fwd->{PORT}:$fwd->{FWD_PORT}) waitpid($fwd->{pid})=$rslt");

				if ($rslt)	# -$rslt == -1 || $rslt == $fwd_pid)
				{
					$fwd->stopSelf("died",$FWD_START_TIME_DIED);
				}

				# If the process appears to be running, try a ping

				elsif ($fwd->{FWD_PING_REQUEST} &&
					   $now > $fwd->{ping_time} + $FWD_PING_INTERVAL)
				{
					return if $stopping;
					$fwd->stopSelf("PING FAILED",$FWD_START_TIME_PING_FAIL)
						if !$fwd->doPing();
					$fwd->{ping_time} = time();
				}
				return;
			}
		}

		# finally if any are ready to start, give those priority

		for my $fwd (values %$forwards)
		{
			if ($fwd->{start_time} && $now > $fwd->{start_time})
			{
				return if $stopping;
				$fwd->startSSH();
				return;
			}
		}
	}
}




sub startSSH
{
	my ($this) = @_;

 	LOG(-1,"FORWARDING $this->{PORT} TO $this->{FWD_SERVER}:port($this->{FWD_PORT})");

	$this->{pid} = 0;
	$this->{start_time} = 0;
	$this->{state} = $FWD_STATE_NONE;

	unlink $this->{ssh_output_file};

	$this->killRemotePort();

	my $use_output_file = $this->{ssh_output_file};
	$use_output_file =~ s/\//\\/g if is_win();

	my $user_at = "$this->{FWD_USER}\@$this->{FWD_SERVER}";

	my @fwd_params;
	push @fwd_params,$this->{ssh_exe};
	push @fwd_params,('-i',$this->{FWD_KEYFILE});
	push @fwd_params,(
		'-v',					# verbose
		'-E',					# output to logfile
		$use_output_file,
		'-N',					# do not execute a command (use for port forwarding)
		'-p',					# port
		$this->{FWD_SSH_PORT},
		'-R',					# forward specification
		"$this->{FWD_PORT}:localhost:$this->{PORT}",
		$user_at				# user@server.com (host name)
	);

	display($dbg_fwd+1,-1,"FWD($this->{PORT}:$this->{FWD_PORT}) command=".join(' ',@fwd_params));

	# $this->{pid} = open3($ssh_stdin, '>&STDOUT', '>&STDERR', @fwd_params);
	# Maybe pipe append STD_ERR to the logfile for windows.
	# $this->{pid} = open3($ssh_stdin, $ssh_stdout, ">>$use_output_file", @fwd_params);
	# You *may* have to accept the host_key manually one time somehow.
	# I do this by turning on debugging, and copying the command line from the logfile/monitor
	# to a windows dosbox and typing "yes" one time ...
	# We don't see the message
	#     This key is not known by any other names
	#     Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
	# in the windows logfile, though after running the command line,
	# we do see (in the logfile)
	# 	Warning: Permanently added '[phorton.net]:6803' (ED25519) to the list of known hosts.
	# and
	#	debug1: Authentication succeeded (publickey).
	# and
	#	Adding new key for [phorton.net]:6803 to /c/Users/Patrick/.ssh/known_hosts: ssh-rsa SHA256:opB3KzsMtPlTGUner0q+JcI0c4h0UmG/IyCwE2NzQ9I
	#   Adding new key for [phorton.net]:6803 to /c/Users/Patrick/.ssh/known_hosts: ecdsa-sha2-nistp256 SHA256:LNWVlIPCtrzbOzh+vI0c2aJY2tVXv3UmAWL2Gly0NhQ

	$this->{pid} = open3($ssh_stdin, $ssh_stdout, $ssh_stderr, @fwd_params);

	if (!$this->{pid})
	{
		error("Could not start FORWARD port: $! - retrying in $FWD_START_TIME_FAIL seconds");
		$this->{start_time} = time() + $FWD_START_TIME_FAIL;
		return;
	}

	display($dbg_fwd+1,-1,"back from IPC::Open3 to $user_at:$this->{FWD_PORT}");
	$this->{initial_time} = time();
	$this->{state} = $FWD_STATE_STARTING;
}


sub checkStart
{
	my ($this) = @_;
	my $text = getTextFile($this->{ssh_output_file});

	display($dbg_fwd,0,"FWD_CHECK_START($this->{PORT}:$this->{FWD_PORT})");
	display($dbg_fwd+1,0,"fwd_text=$text");

	if ($this->{FWD_TEST_FAILURES} ||	# testing failures
		$text =~ /remote port forwarding failed/ ||
		$text =~ /Host key verification failed/)
	{
		error("FWD($this->{PORT} to $this->{FWD_PORT}) not available! restarting in $FWD_START_TIME_FAIL seconds ....");
		LOG(0,"");
		LOG(0,$text);
		LOG(0,"");
		$this->stopSelf("CONNECT FAILURE",$FWD_START_TIME_FAIL);
	}
	elsif ($text =~ /remote forward success/)
	{
		LOG(-1,"FWD($this->{PORT} to $this->{FWD_PORT}) SUCCEEDED");
		$this->{state} = $FWD_STATE_SUCCESS;
		$this->{check_time} = time();
		$this->{ping_time} = time();
	}
	elsif (time() > $this->{initial_time} + $FWD_TIMEOUT)
	{
		$this->stopSelf("CONNECT TIMEOUT",$FWD_START_TIME_TIMEOUT);
	}
}


sub stopSelf
{
	my ($this,$msg,$restart_time) = @_;
	error("FWD($this->{PORT} to $this->{FWD_PORT}) $msg!! restarting in $restart_time seconds");
	kill 9, $this->{pid};	# JIC it's still running

	if ($this->{FWD_CRITICAL_RETRIES})
	{
		$this->{fail_count}++;
		if ($this->{fail_count} >= $this->{FWD_CRITICAL_RETRIES})
		{
			error("FWD_CRITICAL_RETRIES($this->{fail_count}) - Rebooting or Restarting Service");
			Pub::ServiceMain::doRebootMachine();
			while (1) { sleep(1) };
		}
	}

	$this->{pid} = 0;
	$this->{state} = $FWD_STATE_FAIL;
	$this->{start_time} = time() + $restart_time;
}


sub killRemotePort
	# this is called before forwarding,
	# to clear any dangling ports on the server
{
	my ($this) = @_;

	display($dbg_kill,-1,"PortForwarder::killRemotePort($this->{FWD_PORT}) called");
	my $command = "$this->{ssh_exe} ";
	$command .= "-i $this->{FWD_KEYFILE} ";
	$command .= "-f -p $this->{FWD_SSH_PORT} ";
	$command .= "$this->{FWD_USER}\@$this->{FWD_SERVER} ";
	$command .= "/home/$this->{FWD_USER}/kill_ports.pm $this->{FWD_PORT}";

	display($dbg_kill+1,-2,"killRemotePort() command=$command");
	my $rslt = `$command`;
	$rslt =~ s/\s+$//;
	display($dbg_kill,-2,"killRemotePort() rslt=$rslt");
	sleep(1);
}


sub doPing
	# Do a ping, synchronously, using user supplied
	# FWD_PING_REQUEST and SSL params if provided.
	# Returns 1 or 0.
{
	my ($this) = @_;
	my $line = '';
	my $host = $this->{FWD_SERVER};
    my $port = $this->{FWD_PORT};
	my $host_port = "$host:$port";
	display($dbg_ping,0,"doPing($host_port) request($this->{FWD_PING_REQUEST})");

	$this->{in_ping} = 1;
	my $save_debug = $IO::Socket::SSL::DEBUG;

	my @params = (
		PeerAddr => $host_port,
        PeerPort => "http($port)",
        Proto    => 'tcp',
		Timeout  => $FWD_PING_TIMEOUT );

	if ($this->{SSL})
	{
		# turn off SSL debugging
		# turn offf SSL verifying
		# but still send cert
		# note that we cannot turn off server SSL debugging
		# which is in another thread ...

		$IO::Socket::SSL::DEBUG = $DEBUG_PING_SSL;
		push @params, (
			SSL_cert_file => $this->{SSL_CERT_FILE},
			SSL_key_file => $this->{SSL_KEY_FILE},
			# SSL_ca_file => $this->{SSL_CA_FILE},
			# SSL_verify_mode => $this->{SSL_CA_FILE} ? SSL_VERIFY_PEER  : SSL_VERIFY_NONE,
			SSL_verify_mode => SSL_VERIFY_NONE,
		);
	}

    my $sock = $this->{SSL} ?
		IO::Socket::SSL->new(@params) :
		IO::Socket::INET->new(@params);

    if (!$sock)
    {
        error("doPing() could not connect to $host_port");
		goto END_PING;
    }

	my $packet = $this->{FWD_PING_REQUEST}."\r\n\r\n";
	my $len = length($packet);
	my $bytes = syswrite($sock,$packet);
	if ($bytes != $len)
	{
		$this->{in_ping} = 0;
        error("doPing() could only write($bytes/$len) bytes to $host_port");
		$sock->close();
		goto END_PING;
	}

	$sock->flush();
	display($dbg_ping+1,0,"getting line from $host_port");
	$line = <$sock> || '';
	$line =~ s/\s+$//;
	$sock->close();

	# The reply *should* contain 'OK'
	# But we accept any response from the server

	display($dbg_ping,0,"doPing($host_port) got '$line'");

END_PING:

	undef $sock;

	$IO::Socket::SSL::DEBUG = $save_debug
		if $this->{SSL};

	$this->{in_ping} = 0;
	return $line;
}



1;
