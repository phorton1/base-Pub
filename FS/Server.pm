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


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
		$dbg_server
	);
}



my $USE_FORKING = 1;
my $KILL_FORK_ON_PID = 1;

my $server_thread = undef;
my @client_threads = (0,0,0,0,0,0,0,0,0,0);
my $client_thread_num = 0;
     # ring buffer to keep threads alive at
     # least until the session gets started

my $connect_num = 0;



sub new
{
	my ($class,$params) = @_;
	$params ||= {};
	my $this = shared_clone($params);
	$this->{PORT} ||= $DEFAULT_PORT;
	$this->{HOST} ||= $DEFAULT_HOST;
	$this->{IS_REMOTE} ||= 0;
	$this->{running} = 0;
	$this->{stopping} = 0;
    bless $this,$class;
	$this->start();
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
        display($dbg_server,0,"waiting for file server on port($this->{PORT}) to stop");
        sleep(1);
    }
    if ($this->{running})
    {
        error("STOPPED with $this->{running} existing threads");
    }
    else
    {
        LOG(0,"STOPPED sucesfully");
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



sub serverThread
{
    my ($this) = @_;

    display($dbg_server+1,0,"serverThread started");

    my $server_socket = IO::Socket::INET->new(
        LocalPort => $this->{PORT},
        Type => SOCK_STREAM,
        Reuse => 1,
        Listen => 10);

    if (!$server_socket)
    {
        $this->dec_running();
        error("Could not create server socket on port $this->{PORT}: $@");
        return;
    }

    # loop accepting connectons from clients

    my $WAIT_ACCEPT = 1;
    display($dbg_server+1,1,'Waiting for connections ...');
    my $select = IO::Select->new($server_socket);
    while ($this->{running} && !$this->{stopping})
    {
        if ($USE_FORKING)
        {
            if (opendir DIR,$temp_dir)
            {
                my @entries = readdir(DIR);
                closedir DIR;
                for my $entry (@entries)
                {
                    if ($entry =~ /^((-|\d)+)\.pfs_pid/)
                    {
                        my $pid = $1;

						if ($KILL_FORK_ON_PID)
						{
							display($dbg_server+1,0,"KILLING CHILD PID $pid");
							unlink "$temp_dir/$entry";
							kill(15, $pid);		# SIGTERM
						}
						else
						{
							display($dbg_server+1,0,"FS_FORK_WAITPID(pid=$pid)");
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
                    display($dbg_server+1,0,"FS_FORK_START($connect_num) pid=$$");

                    $this->sessionThread($client_socket,$peer_ip,$peer_port);

                    display($dbg_server+1,0,"FS_FORK_END($connect_num) pid=$$");

					if (!$KILL_FORK_ON_PID)
					{
						open OUT, ">$temp_dir/$$.pfs_pid";
						print OUT $$;
						close OUT;
					}

                    exit(0);
                }
                display($dbg_server+1,1,"fs_fork($connect_num) parent continuing");

            }
            else
            {
                display($dbg_server+1,1,"starting sessionThread");
                $client_threads[$client_thread_num] = threads->create(
                    \&sessionThread,$this,$client_socket,$peer_ip,$peer_port);
                $client_threads[$client_thread_num]->detach();
                $client_thread_num++;
                $client_thread_num = 0 if $client_thread_num > @client_threads-1;
                display($dbg_server+1,1,"back from starting sessionThread");
            }
        }
        else
        {
            display($dbg_server+2,0,"not can_read()");
        }
    }

    $server_socket->close();
    LOG(0,"serverThread STOPPED");
    $this->dec_running();

}   # serverThread()




sub sessionThread
{
    my ($this,$client_socket,$peer_ip,$peer_port) = @_;
    display($dbg_server+1,0,"FILE SESSION THREAD");

	my $session = $this->createSession($client_socket);

	my $ok = 1;
	my $packet = $session->get_packet();
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

	if ($ok && !$session->send_packet("WASSUP"))
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
    while ($ok && !$this->{stopping})
    {
		if ($select->can_read(1))
		{
            $packet = $session->get_packet();
			last if $this->{stopping};
			last if !$packet;

			my @params = split(/\t/,$packet);

			if ($params[0] eq 'ABORT')
			{
				next;
			}
			elsif ($params[0] eq 'EXIT')
			{
				last;
			}
			else
			{
				$session->doCommand($params[0],!$this->{IS_REMOTE},$params[1],$params[2],$params[3]);
			}
		}
    }

	undef $session->{sock};
    $client_socket->close();
    $this->dec_running();

	if (!$KILL_FORK_ON_PID)
	{
		open OUT, ">$temp_dir/$$.pfs_pid";
		print OUT $$;
		close OUT;
	}

	while (1) { sleep(10); }

	# return;
	# exit(0);
}



1;
