#-------------------------------------------------
# Pub::FS::Server
#--------------------------------------------------
# The Server Creates a socket and listens for connections.
#
# The base class uses a base Session per connection
# to provide information about, and effect changes in
# the local file system.
#
# The Server is the base class for the RemoteServer, which uses
# a SessionRemote  o communicate with a Serial remote
#
# A Server knows if it IS_REMOTE when it passes commands
# to the Session.  A regular Server is NOT_REMOTE (it is local)
# but a RemoteServer IS_REMOTE;


package Pub::FS::Server;
use strict;
use warnings;
use threads;
use threads::shared;
use POSIX;
use Time::HiRes qw( sleep usleep );
use IO::Select;
use IO::Socket::INET;
use Time::HiRes qw(sleep);
use Pub::Utils;
use Pub::FS::Session;


our $dbg_server:shared =  0;
	# 0 for main server startup
	# -1 for forking/threading details
	# -2 null reads
	# -9 for connection waiting loop
our $dbg_notifications = 0;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
		$dbg_server
		$dbg_notifications
		$ACTUAL_SERVER_PORT
		notifyAll
	);
}


our $ACTUAL_SERVER_PORT:shared;

my $num_notify_all:shared = 0;
my $notify_all:shared = shared_clone({});
	# a list of packets to asynchronously send to all connected threads
	# simpler said than done.
	# How do we know when all threads have been notified and
	# what prevents the messages from being sent multiple times?

	# one idea:
	#     the entry consists of the message and a hash of connection numbers
	#     that have sent the message, this at least prevents re-sends.
	# then we need second idea
	#     a shared hash of all connection numbers that are still connected
	#     which is cleared when the threads terminate
	# then the main server thread could check if the message can be
	#     deleted by comparing them.
my $active_connections = shared_clone({});

sub notifyAll
{
	my ($msg) = @_;
	display($dbg_notifications,-2,"notifyAll($msg)");
	my $num = $num_notify_all++;
	$notify_all->{$num} = shared_clone({
		msg => $msg,
		notified => shared_clone({}),
	});
}


# FINAL SUMMARY OF FORKING VERSUS THREADING AND VARIOUS OPTIONS in buddy
#
# Forking had a lot of problems in Buddy with, I think, the
# closing of STDIN and STOUT that I could not seem to work around
#
# Threading seems to work perfectly, and I don't need the circular buffer.
#
# Using the circular buffer, when 1, I noticed that even if I
# open more than 10 threads, which would wrap the @client_threads array,
# thus effectively undef'ing them, there didn't seem to be any problems.
# So I tried to use a local $thread handle, and it it barfed.
#
# However, using a single global $thread_handles seems to
# work perfectly and avoids the additional complexity.


my $USE_FORKING = 0;


my $KILL_PID_EXT = 'FS_SERVER_pid';
	# PID files are not currently process (buddy invocation) specific

my $KILL_NONE 		= 0x0000;		# don't use feature
my $KILL_REDIRECT	= 0x0001;		# redirect STDIN and STDOUT locally
my $KILL_WAIT       = 0x0002;		# waitpid on the PID file in the main thread
my $KILL_KILL 		= 0x0004;		# kill the PID file in the main thread
	# the last two are mutuallly exclusive

my $HOW_KILL_FORK = $KILL_REDIRECT;

# following only used if !$USE_FORKING

my $SAVE_CLIENT_THREADS = 0;
	# Setting this to 0 uses single global $thread_handle
	# Setting it to 1 uses circular buffer

# following only used if !$SAVE_CLIENT_THREADS

my $thread_handle;

# following only used if $SAVE_CLIENT_THREADS

my $server_thread = undef;
my @client_threads = (0,0,0,0,0,0,0,0,0,0);
my $client_thread_num = 0;
     # ring buffer to keep threads alive at
     # least until the session gets started


#------------------------
# local variables
#------------------------

my $connect_num = 0;


#-------------------------------------------------
# methods
#-------------------------------------------------

sub new
{
	my ($class,$params) = @_;
	$params ||= {};
	$params->{PORT} = $DEFAULT_PORT if !defined($params->{PORT});
	$params->{HOST} ||= $DEFAULT_HOST;
	$params->{IS_REMOTE} ||= 0;
	my $this = shared_clone($params);
	$this->{running} = 0;
	$this->{stopping} = 0;
    bless $this,$class;
	$this = undef if !$this->start();
	return $this;
}


sub createSession
	# this method overriden in derived classes
	# to create different kinds of sessions
{
	my ($this,$sock) = @_;
	return Pub::FS::Session->new({
		SOCK => $sock,
		IS_SERVER => 1 });
}


sub inc_running
{
    my ($this) = @_;
	$this->{running}++;
	display($dbg_server+1,0,"inc_running($this->{running})");
}


sub dec_running
{
    my ($this) = @_;
	$this->{running}-- if $this->{running};
	display($dbg_server+1,0,"dec_running($this->{running})");
}



sub stop
{
    my ($this) = @_;
    my $TIMEOUT = 5;
    my $time = time();
    $this->{stopping} = 1;
    while ($this->{running} && time() < $time + $TIMEOUT)
    {
        display($dbg_server,0,"waiting for FS::Server on port($this->{PORT}) to stop");
        sleep(1);
    }
    if ($this->{running})
    {
        error("FS::Server STOPPED with $this->{running} existing threads");
    }
    else
    {
        LOG(0,"FS::Server STOPPED sucesfully");
    }
}


sub start
{
    my ($this) = @_;
    display($dbg_server,0,ref($this)." STARTING on port($this->{PORT})");
    $this->inc_running();
    $server_thread = threads->create(\&serverThread,$this);
    $server_thread->detach();
    return $this;
}


#-----------------------------------------------------
# serverThread()
#-----------------------------------------------------

sub serverThread
{
    my ($this) = @_;
    display($dbg_server,-2,"serverThread started with PID($$)");

    my $server_socket = IO::Socket::INET->new(
        LocalPort => $this->{PORT},
        Type => SOCK_STREAM,
        Reuse => 1,
        Listen => 10);

    if (!$server_socket)
    {
        $this->dec_running();
        error("Could not create server socket: $@");
        return;
    }

	if (!$this->{PORT})
	{
		$ACTUAL_SERVER_PORT = $server_socket->sockport();
		$this->{PORT} = $ACTUAL_SERVER_PORT;
		warning($dbg_server,0,"SERVER STARTED ON ACTUAL_PORT($ACTUAL_SERVER_PORT)");
	}

    # loop accepting connectons from clients
	# and wait for all threads to stop if stopping

    my $WAIT_ACCEPT = 1;
    display($dbg_server+1,1,'Waiting for connections ...');
    my $select = IO::Select->new($server_socket);
    while ($this->{running}>1 || (
		   $this->{running} && !$this->{stopping}))
    {
        if ($select->can_read($WAIT_ACCEPT))
        {
            $connect_num++;
            my $client_socket = $server_socket->accept();
            binmode $client_socket;

            my $peer_addr = getpeername($client_socket);
            my ($peer_port,$peer_raw_ip) = sockaddr_in($peer_addr);
            my $peer_name = gethostbyaddr($peer_raw_ip,AF_INET);
            my $peer_ip = inet_ntoa($peer_raw_ip);
            $peer_name = '' if (!$peer_name);

            $this->inc_running();

            if ($USE_FORKING)
            {
                display($dbg_server+1,1,"fs_fork($connect_num) ...");
                my $rslt = fork();
                if (!defined($rslt))
                {
                    $this->inc_running(-1);
                    error("FS_FORK($connect_num) FAILED!");
                    next;
                }

                if (!$rslt)
                {
                    display($dbg_server,0,"FS_FORK_START($connect_num) pid=$$");
                    $this->sessionThread($connect_num,$client_socket,$peer_ip,$peer_port);
					display($dbg_server,0,"FS_FORK_END($connect_num) pid=$$");

					# Nothing I tried seemed to work for $USE_FORKING

					local *STDOUT = $HOW_KILL_FORK & $KILL_REDIRECT ?
						open STDOUT, '>', "/dev/null" :
						'>&STDOUT';

					if ($HOW_KILL_FORK & ($KILL_WAIT | $KILL_KILL))
					{
						open OUT, ">$temp_dir/$$.$KILL_PID_EXT";
						print OUT $$;
						close OUT;
					}

					if ($HOW_KILL_FORK & $KILL_KILL)
					{
						while (1) {sleep 10;}
					}
					# kill 15,$$;
					exit(0)
                }
                display($dbg_server+1,1,"fs_fork($connect_num) parent continuing");

            }
            else
            {
                display($dbg_server+1,1,"starting sessionThread");

				if ($SAVE_CLIENT_THREADS)
				{
					$client_threads[$client_thread_num] = threads->create(
						\&sessionThread,$this,$connect_num,$client_socket,$peer_ip,$peer_port);
					$client_threads[$client_thread_num]->detach();
					$client_thread_num++;
					$client_thread_num = 0 if $client_thread_num > @client_threads-1;
				}
				else
				{
					$thread_handle = threads->create(	# barfs: my $thread = threads->create(
						\&sessionThread,$this,$connect_num,$client_socket,$peer_ip,$peer_port);
					$thread_handle->detach(); 			# barfs: $thread->detach();
				}
                display($dbg_server+1,1,"back from starting sessionThread");
            }
        }
        else
        {
            display($dbg_server+2,0,"not can_read()");
        }

		# Server Idle Processing

		# clear any finished pending notifyAll messages

		for my $num (sort keys %$notify_all)
		{
			my $notify = $notify_all->{$num};
			my $got_all = 1;
			for my $c_num (keys %$active_connections)
			{
				if (!$notify->{notified}->{$c_num})
				{
					$got_all = 0;
					last;
				}
			}

			if ($got_all)
			{
				display($dbg_notifications,-1,"Clearing notifyAll: $notify->{msg}");
				delete $notify_all->{$num};
			}
		}

		# handle any pending FORK PID files

        if ($USE_FORKING && ($HOW_KILL_FORK & ($KILL_WAIT | $KILL_KILL)))
        {
            if (opendir DIR,$temp_dir)
            {
                my @entries = readdir(DIR);
                closedir DIR;
                for my $entry (@entries)
                {
					if ($entry =~ /^((-)*\d+)\.$KILL_PID_EXT/)
                    {
						my $pid = $1;
						if ($HOW_KILL_FORK & $KILL_KILL)
						{
							display($dbg_server,0,"KILLING CHILD PID $pid");
							unlink "$temp_dir/$entry";
							# This attempt to kill child process also,
							# unfortunately, kills the buddy app ..
							kill(15, $pid);		# SIGTERM
						}
						else	# $KILL_WAIT
						{
							display($dbg_server,0,"FS_FORK_WAITPID(pid=$pid)");
							my $got = waitpid($pid,0);  # 0 == WNOHANG
							if ($got && $got ==$pid)
							{
								unlink "$temp_dir/$entry";
							}
						}
                    }
                }
            }
        }


    }

    $server_socket->close();
    LOG(0,"serverThread STOPPED");
    $this->dec_running();

	$this->{running} = 0;

}   # serverThread()



#----------------------------------------------------------------------
# sessionThread()
#----------------------------------------------------------------------

sub sessionThread
{
    my ($this,$connect_num,$client_socket,$peer_ip,$peer_port) = @_;
    display($dbg_server,-2,"SESSION THREAD($connect_num) WITH PID($$)");

	$active_connections->{$connect_num} = 1;

	my $session = $this->createSession($client_socket);

	my $ok = 1;
	my $packet = $session->getPacket(1);
    if (!defined($packet) || !$packet)
    {
        $session->session_error("EMPTY LOGIN");
		$ok = 0;
	}
	elsif ($packet !~ /^HELLO/)
	{
        $session->session_error("BAD LOGIN '$packet'");
		$ok = 0;
	}
	if ($ok && !$session->sendPacket("WASSUP"))
	{
        $session->session_error("COULD NOT SEND WASSUP");
		$ok = 0;
	}

    #---------------------------------------------
    # process commands until exit
    #---------------------------------------------
    # do not report unknown commands to hackers

    my $rslt = -1;
	my $select = IO::Select->new($client_socket);
    my $got_exit = 0;
    while ($ok && !$this->{stopping})
    {
		if ($select->can_read(0.1))
		{
            $packet = $session->getPacket();
			last if $this->{stopping};
			if (defined($packet))
			{
				if ($packet =~ /^ABORT/)
				{
					$this->session_error("operation($this->{IS_REMOTE}) ABORTED by remote");
					next;
				}
				elsif ($packet =~ /^EXIT/)
				{
					$got_exit = 1;
					last;
				}
				elsif ($packet)
				{
					my @lines = split(/\n/,$packet);
					my $line = shift @lines;
					my @params = split(/\t/,$line);
						# LIST 		$dir
						# MKDIR 	$dir $dirname
						# RENAME 	$dir $name1 $name2
						# DELETE 	$dir [$singe_filename]
						# XFER      $dir, $local, $target_dir
						# BASE_64   $data
						# PROGRESS  TBD
					my $entries = $params[2];

					# DELETE is passed directly back to the SessionRemote,
					# which also handles PROGRESS and ABORT

					my $rslt;
					if ($this->{IS_REMOTE} && $params[0] eq $SESSION_COMMAND_DELETE)
					{
						$rslt = $session->deleteRemotePacket($packet)
					}

					# XFER and DELETE take $entries from multiple_lines.

					else
					{
						if (@lines)
						{
							$entries = {};
							for my $line (@lines)
							{
								my $info = Pub::FS::FileInfo->from_text($this,$line);
								$entries->{$info->{entry}} = $info;
							}
						}

						$rslt = $session->doCommand($params[0],!$this->{IS_REMOTE},$params[1],$entries,$params[3]);
					}

					# print "SERVER PACKET $packet\n";

					$rslt ||= '';
					my $packet = ref($rslt) ? $session->listToText($rslt) : $rslt;
					last if $packet && !$session->sendPacket($packet);
				}
			}
		}

		# exit the session if the socket went away

		if (!$session->{SOCK})
		{
		    display($dbg_server,0,"SESSION THREAD($connect_num) lost it's socket!");
			last;
		}

		# send any pending notifyAll messages

		for my $num (sort keys %$notify_all)
		{
			my $notify = $notify_all->{$num};
			if (!$notify->{notified}->{$connect_num})
			{
				$notify->{notified}->{$connect_num} = 1;
				display($dbg_notifications,-2,"THREAD($connect_num) sending $notify->{msg}");
				$session->sendPacket($notify->{msg});
			}
		}

	}	# while $ok && !stopping


    display($dbg_server,0,"SESSION THREAD($connect_num) terminating ".
		"SOCK(".($session->{SOCK}?1:0).") SEND_EXIT($this->{SEND_EXIT}) GOT_EXIT($got_exit)");

	if (!$got_exit &&
		$session->{SOCK} &&
		$this->{SEND_EXIT})
	{
		$session->sendPacket("EXIT");
		sleep(0.2);
	}

	# print "past the exit\n";

	delete $active_connections->{$connect_num};

	undef $session->{SOCK};
    $client_socket->close();
    $this->dec_running();

}



1;
