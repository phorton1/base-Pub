#!/usr/bin/perl
#-----------------------------------------------------
# Pub::HTTP::ServerBase
#-----------------------------------------------------
# Currently limited to a single instance due to many globals
# and use of prefs.
#
# Newly based on an example pooled threaded server i found
# at https://github.com/macnod/DcServer which uses Threads::Queue
# to pass the handle_number of the accepted socket to a pool of
# threads
#
# PARAMETERS from prefs:
#
#	HTTP_SERVER_NAME => 'Artisan Perl",
#			# used for default http 'Server' header
#
#	HTTP_DEBUG_SERVER => -1..2	default(0) - optional - see notes below
#	HTTP_DEBUG_REQUEST => 0..5	default(0) - optional - see notes below
#	HTTP_DEBUG_RESPONSE => 0..5	default(0) - optional - see notes below
#
#	HTTP_DEBUG_QUIET_RE => '',
#			# if the request matches this RE, the request
#			# and response debug levels will be bumped by 2
#			# so that under normal circumstances, no messages
#			# will show for these.
#	HTTP_DEBUG_LOUD_RE => ''
#			# This RE can be used to debug particular URIS
#			# by effectively decreawing their debug levels by 2

#   HTTP_DEBUG_PING 	=> 0/1			default(0) optional - shows ping debugging at DEBUG_SERVER level
#
#	HTTP_PORT			=> number		required
#	HTTP_MAX_THREADS	=> 5			default(10)
#
#	HTTP_SSL 			=> 1			default(0) optional
# 	HTTP_SSL_cert_file  => filename		required if SSL
# 	HTTP_SSL_key_file  	=> filename		required if SSL
#
# 	HTTP_AUTH_ENCRYPTED => 1			optional if AUTH_FILE
# 	HTTP_AUTH_FILE      => filename		drives user authentication
# 	HTTP_AUTH_REALM     => string		required if AUTH_FILE
#
#	HTTP_KEEP_ALIVE			=> 0/1		default(0)	use persistent connections from browsers
# 	HTTP_ZIP_RESPONSES 		=> 1		optional in general
#
#	HTTP_DOCUMENT_ROOT 		=> path				optional, requied for base class to serve files
#	HTTP_DEFAULT_LOCATION 	=> filename			default('index.html') can be set to '' to disable
#	HTTP_FAVICON			=> filename			optional fully qualified (jpg|png|ico) file
#   HTTP_GET_EXT_RE 		=> re				default('html|js|css|jpg|png|ico')
#	HTTP_SCRIPT_EXT_RE 		=> re				default('') example: 'cgi|pm|pl',
#
#	HTML_USE_INCLUDES 		=> 0/1				default(undef) - send max-age instead of no-cache for JS and CSS
#												from html files. requires use of <&$this->includeCSS/JS('blah.js')>
#												NOT REALLY A PREF, BUT AN IMPLEMENTATION DECISION
#	HTTP_MINIFIED_JS		=> 1				default(undef) whether to return minimized JS files if they exist
#	HTTP_MINIFID_CSS		=> 1				default(undef) whether to return minimized CSS files if they exist
#	HTTP_LOGFILE			=> filename	  		for HTTP separate logfile of HTTP_LOG calls
#
# 	HTTP_DEFAULT_HEADERS 		=> {},			see below
#
#   HTTP_ALLOW_REBOOT   	=> 1				linux only
#	HTTP_RESTART_SERVICE  	=> 'artisan'
#	HTTP_GIT_UPDATE       	=> '/base/Pub,/base/apps/artisan'
#
# IDLE TIMING AND LOCKING
#
#	Changing debug levels was affecting timing.
#	Some debugging made it faster, some made it slower.
#   Finally figured out that I had to rework the server thread vis-a-vis
#   using a quick timeout on the can_read() call, but still slowing it down
#   to a reasonable load level when idle.  Other details included using lock($this)
#   when bumping/decrementing $this->{active}.  It now seems to be working.
#
# SUB-THREADS (WEB SOCKETS)
#
#  	handle_request() may return $RESPONSE_STAY_OPEN which indicates
#   that a separate thread has been started to handle the response,
#	freeing the server's thread pool for more requests. This is
#   required for myIOTServer WebSockets that stay open indefinitely.
#   Clients that return $RESPONSE_STAY_OPEN must eventually call
#   endOpenRequest($request) when their threads end.
#
#	This causes the socket to not be added to the closed_queue
#   until some time later
#
# DEFAULT HEADERS
#
#	The headers for all	responses are determined by the default
#   DEFAULT_HEADERS param.
#
#	Client ctors can completely replace the DEFAULT_HEADERS.
#	It is all or none.
#
#	In the preferences file, DEFAULT_HEADERS are given by a non-sparse
#	set of numbered, singular, defines, starting at zero, as a =>
#   delimited pair:
#
#		DEFAULT_HEADER_0 = cache-control => max_age: 604800
#
#	where the special value of 'undef' may be used to delete
#	the header from the ctor/base class defaults.  In the case
#   that headers ARE specified in the prefs file, they will override
#	those from the ctor/base class.
#
#		'cache-control' => 'no-cache, no-store, must-revalidate',
#		'pragma'        => 'no-cache',
#		'expires'       => '0',
#		'connection' 	=> $this->{HTTP_KEEP_ALIVE} ? 'keep-alive' : 'close';
#
#	Any override of the 'cache-control' header will automatically
#	remove the 'pragma' and 'expires' headers as well
#
#	Finally, derived class handle_request() methods can define and
#	remove headers directly from $response->{headers} after the
#	response is created, overriding both the construction params
#	and the preferences file. One useful method for this is
#
#		$response->setAsCached()
#
#	which will set a "cache-control max-age: forever, immutable"
#	header, and remove the 'expires' and 'pragma' headers from
#	the response.
#
# SYSTEM FUNCTIONS (reboot, restart, update_system, update_system_stash)
#
#	These functions have been standardized across Artisan, myIOTServer,
#   and the inventory control services, all of which use Pub::ServiceMain
#   for their main loops.
#
#   For this reason, this base class, by default, includes the
#   Pub::ServiceMain && Pub::ServiceUpdate modules, which are only
#   actually used in the case that the HTTP_RESTART_SERVICE and/or
#	HTTP_GIT_UPDATE values are set, in which case the /restart,
#	/update_system, and /update_system_stash urls are valid.
#
#   The /reboot url is only valid on linux machines
#	if HTTP_ALLOW_REBOOT is set.




package Pub::HTTP::ServerBase;
# use bytes;
    # This line was crucial one day with SSL.
    # Without it, Perl was munging binary streams into UNICODE,
    # and we would not deliver binary responses (i.e. gif files).
    # Also necessary are the various "local $/ = undef" calls.
use strict;
use warnings;
use threads;
use threads::shared;
use Thread::Queue;
use Error qw(:try);
use IO::Handle;
use IO::Socket;
use IO::Socket::SSL;
use IO::Select;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use Pub::Crypt;
use Pub::Prefs;
use Pub::Users;
use Pub::ProcessBody;
use Pub::ServiceMain;
use Pub::ServiceUpdate;
use Pub::DebugMem;
use Pub::HTTP::Request;
use Pub::HTTP::Response;
use Pub::HTTP::Message;
use Pub::ProcessBody;
use Pub::DebugMem;

my $dbg_def_headers = 1;
	# debug default headers from prefs file

my $dbg_http_log = 0;
my $dbg_server = 1;
	# works with DEBUG_SERVER param and dbg() and HTTP_LOG() methods
	#
	# server dbg() calls all have a hardwired debug level, usually 0, 1, or 2.
	# HTTP_LOG() is effectively at level -1
	#
	# $dbg_server is nominally set to 1 so that only HTTP_LOG messages
	#     show. Even they can be turned off in the params by passing in
	#     DEBUG==-1.
	#
	# Otherwise DEBUG is relative to $dbg_server, which can be set
	# for debugging sessions without modifying clients, but should be
	# replaced at level 1 in production.
	#
	# Thus, the DEBUG param turns on the usual levels of debugging:
	#
	#	 -1 = nothing
	#	  0 = LOG messages, one per Request and Response
	#	  1 = CONNECT and handle_request header and footers
	#     2 = gruesome details


our $SUPPRESS_HTTP_LOG = 0;
	# set to 1 to suprress the HTTP LOG messages, even if specified
	# by user
our $OVERRIDE_DEBUG_PING = 0;
	# Normally 0, this can be set to one here, or via the parameters
	# for ping specific debugging
my $DEFAULT_MAX_THREADS = 10;
	# If the user doesn't specify


my $accept_queue = Thread::Queue->new;
my $closed_queue = Thread::Queue->new;
my $kept_open_queue:shared = shared_clone({});
	# separate, per-thread queue for $RESPONSE_STAY_OPEN sockets
	# that must be closed by the thread that had them, is a shared
	# hash by thread num and fileno.





sub dbg_queue
{
	my $pending = $accept_queue->pending();
	my $closed = $closed_queue->pending();
	return "pending($pending) closed($closed) ";
}


sub dbg
{
	my ($this,$level,$indent,$msg,$call_level,$color) = @_;
	$call_level ||= 0;
	my $dbg_level = $level + $dbg_server - ($this->{HTTP_DEBUG_SERVER} || 0);
	display($dbg_level,$indent,$msg,$call_level+1,$color);
}


sub HTTP_LOG
{
	my ($this,$request,$indent_level,$msg,$call_level) = @_;

	# display(0,0,"ref(RESPONSE_HANDLED)=".ref($request),0,$UTILS_COLOR_CYAN)
	# 	if ($request && $request eq $RESPONSE_HANDLED);

	my $dbg_level = $dbg_http_log;
	my $extra = ref($request) ? $request->{extra_debug} : 0;
	$dbg_level +=  $extra;

	# display(0,0,"http_log dbg_level($dbg_level) extra($extra) uri($request->{uri}) ref=".ref($request));

	return if $debug_level < $dbg_level;

	$call_level ||= 0;
	display($dbg_level,$indent_level,$msg,$call_level+1,$UTILS_COLOR_WHITE);

	return if !$this->{LOGFILE};
	return if $SUPPRESS_HTTP_LOG;

	if (open OUTPUT_FILE,">>$this->{LOGFILE}")
	{
		my $tid = threads->tid();;
		my $dt = pad(now(0,1)." ".$login_name,28);
		my ($indent,$file,$line,$tree) = Pub::Utils::get_indent($call_level+1,0);
		my $header = "($tid,$indent_level)$file\[$line\]";

		$indent = 0 if $indent_level < 0;
		$indent_level = 0 if $indent_level < 0;

		my $full_message = $tree.$dt.pad($header,40 + ($indent+$indent_level) * 4).$msg;

		print OUTPUT_FILE $full_message."\n";
		close OUTPUT_FILE;
	}
}


sub my_chomp
{
	my ($value) = @_;
	$value |= '';
	$value =~ s/^\s+|\s+$//g;
	return $value;
}


sub getDefHeadersPref
	# get non-sparse numbered set of default headers
	# that allow 'undef' and will delete 'pragma' and
	# 'expires' if 'cache-control' is provided
{
	my ($params,$ext) = @_;
	$ext ||= '';		# for main set of prefs
	display($dbg_def_headers,0,"getDefHeadersPref($ext)");

	my $pref_key = "HTTP_DEFAULT_HEADER_";
	my $param_key = "HTTP_DEFAULT_HEADERS";

	$pref_key .= uc($ext)."_" if $ext;
	$param_key .= "_".uc($ext) if $ext;

	my $num = 0;
	my $pref = getPref($pref_key.$num);
	display($dbg_def_headers,1,"checking pref($pref_key$num)="._def($pref));
	while (defined($pref))
	{
		my ($left,$right) = split(/=>/,$pref);
		$left = my_chomp($left);
		$right = my_chomp($right);

		$params->{$param_key} ||= shared_clone({});
		my $headers = $params->{$param_key};

		if (!$ext && $left eq 'cache-control')
		{
			display($dbg_def_headers,2,"removing cache-control for $param_key");
			$headers->delete('pragma');
			$headers->delete('expires');
		}

		if (!$ext && $right eq 'undef')
		{
			display($dbg_def_headers,2,"deleting param $param_key($left)");
			delete $headers->{$left};
		}
		else
		{
			display($dbg_def_headers,2,"param ($param_key($left)='$right'");
			$headers->{$left} = $right;
		}

		$num++;
		$pref = getPref($pref_key.$num);
		display($dbg_def_headers,1,"checking pref($pref_key$num)="._def($pref));
	}

	display_hash(0,0,$param_key,$params->{$param_key})
		if $params->{$param_key};
}




#-------------------------------------------------
# Constructor, start() and stop()
#-------------------------------------------------

sub new
{
    my ($class,$params) = @_;
	$params ||= {};

	getObjectPref($params,'HTTP_SERVER_NAME','ServerBase('.getMachineId().')');

	getObjectPref($params,'HTTP_SSL',0);
	getObjectPref($params,'HTTP_PORT',undef);
	getObjectPref($params,'HTTP_HOST',undef);
	getObjectPref($params,'HTTP_DEBUG_SSL',0,!$params->{HTTP_SSL});
	getObjectPref($params,'HTTP_SSL_CERT_FILE',undef,!$params->{HTTP_SSL});
	getObjectPref($params,'HTTP_SSL_KEY_FILE',undef,!$params->{HTTP_SSL});

	# HTTP_DO_FORWARD triggers forwarding so that
	# the HTTP_FWD_PORT pref can stay unchanged

	getObjectPref($params,'HTTP_DO_FORWARD',undef);

	getObjectPref($params,'HTTP_FWD_PORT',undef);
	getObjectPref($params,'HTTP_FWD_USER',undef);
	getObjectPref($params,'HTTP_FWD_SERVER',undef);
	getObjectPref($params,'HTTP_FWD_SSH_PORT',undef);
	getObjectPref($params,'HTTP_FWD_KEYFILE',undef);
	getObjectPref($params,'HTTP_FWD_PING_REQUEST',undef);

	getObjectPref($params,'HTTP_DEBUG_PING',undef);
	getObjectPref($params,'HTTP_FWD_DEBUG_PING',undef);

	getObjectPref($params,'HTTP_FWD_CRITICAL_RETRIES',undef);
	getObjectPref($params,'HTTP_FWD_TEST_FAILURES',undef);
		# not prefaced with HTTP_, the myIOTServer is the only
		# 'critical' function that will reboot if it fails more
		# than a certain number of times.


	getObjectPref($params,'HTTP_DEBUG_SERVER',0);
	getObjectPref($params,'HTTP_DEBUG_REQUEST',0);
	getObjectPref($params,'HTTP_DEBUG_RESPONSE',0);
	getObjectPref($params,'HTTP_DEBUG_QUIET_RE',undef);
	getObjectPref($params,'HTTP_DEBUG_LOUD_RE',undef);
	getObjectPref($params,'HTTP_LOGFILE',undef);

	getObjectPref($params,'HTTP_AUTH_FILE',undef);
	getObjectPref($params,'HTTP_AUTH_REALM',undef);
	getObjectPref($params,'HTTP_AUTH_ENCRYPTED',undef);

	getObjectPref($params,'HTTP_MAX_THREADS',$DEFAULT_MAX_THREADS);

	getObjectPref($params,'HTTP_DOCUMENT_ROOT','');
	getObjectPref($params,'HTTP_DEFAULT_LOCATION','index.html');
	getObjectPref($params,'HTTP_FAVICON',undef);
	getObjectPref($params,'HTTP_GET_EXT_RE','html|js|css|jpg|png|ico');
	getObjectPref($params,'HTTP_SCRIPT_EXT_RE',undef);

	getObjectPref($params,'HTTP_MINIFIED_JS',undef);
	getObjectPref($params,'HTTP_MINIFIED_CSS',undef);

	getObjectPref($params,'HTTP_KEEP_ALIVE',undef);
	getObjectPref($params,'HTTP_ZIP_RESPONSES',undef);
	getObjectPref($params,'HTTP_AUTH_FILE',undef);

	getObjectPref($params,'HTML_USE_INCLUDES', undef);

	getObjectPref($params,'HTTP_ALLOW_REBOOT', undef);
		# also allows 'shutdown' command
	getObjectPref($params,'HTTP_RESTART_SERVICE', undef);
	getObjectPref($params,'HTTP_GIT_UPDATE', undef);

	display_hash(0,0,"Pub::ServerBase::new()",$params);

	# HTTP_DEFAULT_HEADERS
	# you may override the entire set of default headers
	# by providing them as a shared hash to the ctor.
	# All or nothing. Params may also contain HTTP_DEFAULT_HEADERS_{EXT}
	# for the given extension, which will be applied on a per-file basis
	# for gets from DOCUMENT_ROOT.

	$params->{HTTP_DEFAULT_HEADERS} ||= shared_clone({
		'server' 		 => $params->{HTTP_SERVER_NAME},
		'cache-control'  => 'no-cache, no-store, must-revalidate',
		'pragma'         => 'no-cache',
		'expires'        => '0',
		'connection'  	 => $params->{HTTP_KEEP_ALIVE} ? 'keep-alive' : 'close',
	});

	getDefHeadersPref($params,'');


	# check required parameters

    if (!$params->{HTTP_PORT})
    {
        error("You must provide a PORT for via ctor or prefs for Pub::ServerBase::new()");
        return;
    }

	my $this = shared_clone($params);
    bless $this,$class;

	# required direct defaults of params

	$this->{HTTP_DEBUG_PING} ||= $OVERRIDE_DEBUG_PING;
	$this->{HTTP_MAX_THREADS} ||= $DEFAULT_MAX_THREADS;
	# $this->{HTTP_FWD_PING_REQUEST} = "TODO PING" if $this->{HTTP_FWD_PORT};

    $this->{running} = 0;
    $this->{stopping} = 0;
	$this->{request_num} = 0;
	$this->{active} = 0;

	# finished, return to caller

    $this->dbg(1,0,"HTTP SERVER CONSTRUCTED");
    return $this;
}



sub start
{
    my ($this) = @_;
	$this->dbg(0,0,"serverBase::start($this->{HTTP_MAX_THREADS}) threads");
	my $server_thread = threads->create(\&serverThread,$this);
	$server_thread->detach();
	$this->dbg(2,1,"serverThread detatched");

	for (my $i=0; $i<$this->{HTTP_MAX_THREADS}; $i++)
	{
		my $client_thread = threads->create(\&clientThread,$this,$i);
		$client_thread->detach();
		$this->dbg(2,1,"client_thread($i) detatched");
	}
}



sub stop
{
    my ($this) = @_;
    $this->dbg(0,0,"serverBase::stop()");

	Pub::PortForwarder::stop();
		# benign if no portForwarder was created
		# and/or PortForwarder::start() was not called.

    $this->{stopping} = 1;

	my $TIMEOUT = 3;
	my $time = time();
    while (time() < $time+$TIMEOUT && $this->{running})
    {
        $this->dbg(1,1,"Waiting for serverBase to stop");
        sleep(1);
    }
	$this->{running} = 0;
    $this->dbg(0,1,"serverBase::stop() finished");
}



#-------------------------------------------------------------------------
# serverThread
#-------------------------------------------------------------------------

sub serverThread
{
    my ($this) = @_;
    my $port = $this->{HTTP_PORT};
	my $dbg_ssl = $this->{HTTP_SSL} ? ' SSL' : '';
    $this->HTTP_LOG(undef,-1,"HTTP$dbg_ssl SERVER STARTING ON PORT($port)");

    my @params = (
        Proto => 'tcp',
        LocalPort => $port,
        Listen => SOMAXCONN,
        Reuse => 1,
		# Blocking => 0.
		);

    my $socket = IO::Socket::INET->new(@params);
    if (!$socket)
    {
        error("Could not create$dbg_ssl socket on port $port");
        return;
    }

    binmode $socket;
    my $select = IO::Select->new($socket);

	# forward the Port if asked to
	# Pub::ForwardPort start() is re-entrant

	if ($this->{HTTP_DO_FORWARD})
	{
		# the PortForwarder needs the SSL parameters from preferences
		# so that it can do a standard HTTP PING.
		# Here we duplicate the HTTP parameters, removing the HTTP_ prefix
		# so that portForwder can use them, and call start() if new() works.

		my $fwd_params = copyParamsWithout($this,"HTTP_");
		Pub::PortForwarder::start() if Pub::PortForwarder->new($fwd_params);
	}

    #--------------------------------------
	# LOOP while running && !stopping
    #--------------------------------------
	# Will use SLEEP ACTIVE fast loops when active,
	# but switch to an idle loop after a while.
	# This minimizes load on the server.

	my $IDLE_TIME = 2;
	my $SLEEP_IDLE = 1;
	my $SLEEP_ACTIVE = 0.001;
	my $sleep_time = $SLEEP_IDLE;
	my $last_connect = 0;

    $this->{running} = 1;
	my $open_sockets = {};
    while (!$this->{stopping})
    {
		# display(0,0,"LOOP") if $sleep_time == $SLEEP_IDLE;
        my @can_read  = $select->can_read($sleep_time);
		if (@can_read)
		{
			# RESOLVED PERFORMANCE ISSUES
			#
			# There were two things causing the Windows version to be
			# very slow when hit from the phone in Chrome.  First,
			# the unnessecary lookup of the peer_host, which probably
			# uses DNS, was taking a lot of time.
			#
			# Second, in copy-paste programming from someone else, that
			# I didn't really understand, I had a "if ($sock == $socket)"
			# check arouond the whole block, which *seemed* to cause
			# disconnects.
			#
			# For good measure, third, I changed to a form of accept
			# that returns the peer_addr.

			for my $sock (@can_read)
			{
				my $client_socket;
				my $remote = accept($client_socket, $sock);
				my ($peer_port, $peer_addr) = sockaddr_in($remote);
				my $peer_ip = inet_ntoa($peer_addr);

				if (!$peer_addr)
				{
					error("Could not get peer_addr from connection!");
					close $client_socket;
					next;
				}

				my $dbg_from =  "$peer_ip:$peer_port";

				my $file_handle = fileno($client_socket);
				$open_sockets->{$file_handle} = $client_socket;

				my $request_num = $this->{request_num}++;
				my $active = $this->{active};
				my $dbg_msg = dbg_queue();
				$this->dbg(0,0,"CONNECT($request_num) ".
					"handle($file_handle) active($active) $dbg_msg $dbg_from");

				my $ele = shared_clone({
					file_handle => $file_handle,
					request_num => $request_num,
					peer_ip => $peer_ip,
					peer_port => $peer_port,
					peer_addr => $peer_addr,
					# peer_host => $peer_host,
				});

				$accept_queue->enqueue($ele);

				$last_connect = time();
				$sleep_time = $SLEEP_ACTIVE;

			}	# for my $sock (@can_read)
		}	# @can_read
		else
		{
			my $ele;
			while ($ele = $closed_queue->dequeue_nb())
			{
				my $request_num = $ele->{request_num};
				my $file_handle = $ele->{file_handle};
				my $client_socket = $open_sockets->{$file_handle};

				my $active = $this->{active};
				my $dbg_msg = dbg_queue();
				$this->dbg(0,0,"DISCONNECT($request_num) ".
					"handle($file_handle) active($active) $dbg_msg");

				# $client_socket->shutdown(2);
				$client_socket->close();
				delete $open_sockets->{$file_handle};
			}

			# display(0,0,"check sleep_time($sleep_time}) active($this->{active}) last_connect($last_connect) time=".scalar(time()));

			if ($sleep_time == $SLEEP_ACTIVE &&
				!$this->{active} &&
				time() > $last_connect + $IDLE_TIME)
			{
				$sleep_time = $SLEEP_IDLE;
				# display(0,0,"IDLE");
			}

		}	# !@can_read
    }   # while !$stopping

	$this->{running} = 0;
	$socket->close();
    $this->HTTP_LOG(undef,-1,"HTTP_SERVER STOPPED($this->{stopping},$this->{running})");


}   # serverThread()





#-------------------------------------------------------------------------
# clientThread() and clientRequest()
#-------------------------------------------------------------------------


sub checkStop
{
	my ($this,$request) = @_;
    if ($this->{stopping} || !$this->{running})
    {
        $this->dbg(1,0,"HTTP_SERVER request($request->{request_num}) ".
			"STOPPING($this->{stopping},$this->{running})");
		return 1;
    }
}



sub endOpenRequest
{
	my ($request) = @_;

	my $thread_num = $request->{thread_num};
	my $request_num = $request->{request_num};
	my $ele = $request->{ele};
	my $file_handle = $ele->{file_handle};

	$request->{server}->HTTP_LOG($request,-1,"END_OPEN_REQUEST($request_num) ".
		"thread_num($thread_num) file_handle($file_handle)");
	$kept_open_queue->{$thread_num}->{$file_handle} = $ele;
}


sub clientThread
{
    my ($this,$thread_num) = @_;
    $this->dbg(1,0,"clientThread($thread_num) started");

	my $keep_sockets = {};
	$kept_open_queue->{$thread_num} = shared_clone({});
		# hash by fileno of $keep_sockets returned by clientRequest

	while (!$this->{stopping})
	{
		# my $ele = $accept_queue->dequeue();
		my $ele = $accept_queue->dequeue_timed(1);

		# display(0,0,"loop ele="._def($ele));

		if ($ele)
		{
			{
				lock($this);
				$this->{active}++;
			}
			my $keep_sock = clientRequest($this,$thread_num,$ele);
			{
				lock($this);
				$this->{active}--;
			}

			if ($keep_sock)
			{
				my $file_handle = $ele->{file_handle};
				my $request_num = $ele->{request_num};
				$this->dbg(1,1,"REQUEST($request_num) ".
					"thread($thread_num} KEEPING SOCKET($keep_sock) file_handle=$file_handle",
					0,$UTILS_COLOR_CYAN);
				$keep_sockets->{$file_handle} = $keep_sock;
			}
			else
			{
				$closed_queue->enqueue($ele)
			}
		}

		# check every second for 'keep_open' sockets
		# that need to be closed

		else
		{
			my $this_kept_queue = $kept_open_queue->{$thread_num};
			my @closers = (keys %$this_kept_queue);
			for my $file_handle (@closers)
			{
				my $ele = $this_kept_queue->{$file_handle};
				my $sock = $keep_sockets->{$file_handle};
				$this->dbg(1,0,"REQUEST($ele->{request_num}) ".
					"CLOSING KEEP_SOCKET($sock) file_handle($file_handle)",
					0,$UTILS_COLOR_CYAN);
				# $sock->close();
				delete $this_kept_queue->{$file_handle};
				$closed_queue->enqueue($ele);
			}
		}
	}

	$this->dbg(1,0,"clientThread($thread_num) finished");
}



sub clientRequest
{
	my ($this,$thread_num,$ele) = @_;

	my $keep_open = 0;
	my $request_num = $ele->{request_num};
	my $dbg_from = "from $ele->{peer_ip}:$ele->{peer_port}";
	my $file_handle = $ele->{file_handle};

	$this->dbg(1,0,"clientRequest($request_num) file_handle($file_handle) $dbg_from");

	my $request = Pub::HTTP::Request->new($this,{
		request_num => $ele->{request_num},
		peer_ip   	=> $ele->{peer_ip},
		peer_port 	=> $ele->{peer_port},
		peer_host 	=> $ele->{peer_host},
		peer_addr 	=> $ele->{peer_addr},
		thread_num 	=> $thread_num,
		ele 		=> $ele,
	});

	my $client;
	if (!open($client, '+<&=' . $file_handle))
	{
		error("clientRequest($request_num) Could not create $client 'socket' file_handle($file_handle) $dbg_from: $!");
		return;
	}

    # UPGRADE SSL SOCKET

    if ($this->{HTTP_SSL})
    {
        if (!IO::Socket::SSL->start_SSL($client,
                SSL_server => 1,
                SSL_cert_file => $this->{HTTP_SSL_CERT_FILE},
                SSL_key_file => $this->{HTTP_SSL_KEY_FILE}))
        {
            error("clientRequest($request_num) Could not start_SSL() file_handle($file_handle) $dbg_from: $! ~~~ $@");
	        goto END_REQUEST;
        }
        $this->dbg(1,1,"socket($request_num) upgraded to SSL client=$client");
    }


	# READ THE REQUEST
	# if the default headers 'connection' == 'keep-alive',
	# we will loop until the connection times out in Message.pm

	$request->{read_count} = 0;

	while (1)
	{
		my $ok = $request->read($client);
		goto END_REQUEST if !$ok;

		$request->{read_count}++;

		my $method = $request->{method} || '';
		my $uri = $request->{uri} || '';

		# detect pings, and log/debug the request

		my $is_ping = $method eq 'PING' || ($method =~ /get/i && $uri eq "/PING") ? 1 : 0;
		$this->HTTP_LOG($request,0,"request($request_num) $method $uri $dbg_from")
			if !$is_ping || $this->{HTTP_DEBUG_PING};

		# prep the socket

		binmode $client,':raw';
		# $client->blocking(0);

		# PINGS do not require authorization

		my $response;
		$response = http_ok($request,"PING OK")
			if $is_ping;

		# CHECK FOR AUTHORIZATION
		# and set the request auth_user and auth_privs fields
		# for use by implementation dependent servers

		if (!$response && $this->{HTTP_AUTH_FILE})
		{
			$response = $this->checkAuthorization(
				$request,
				$this->{HTTP_AUTH_FILE},
				$this->{HTTP_AUTH_ENCRYPTED});
		}

		goto END_REQUEST if $this->checkStop($client,$request);

		#-----------------------------------------------------
		# Process the request
		#-----------------------------------------------------
		# If not already a PING or 'Authorization Required' response

		if (!$response)
		{
			try
			{
				$response = $this->handle_request($client,$request);
			}
			catch Error with
			{
				my $ex = shift;
				error($ex);
			};

			$this->dbg(1,1,"Back from handle_request($request_num) response="._def($response));

			# provide a default 404 response

			if (!$response)
			{
				$this->dbg(0,1,"WARNING: no response from handle_request($request_num) ".
					"$request->{method} $request->{uri} $dbg_from");
				$response = http_error($request,"ERROR(404)\n\nThe uri($request->{uri}) ".
					"was not found on this server");
			}
		}


		#----------------------------------
		# return the response
		#----------------------------------
		# Check if we're stopping one more time
		# The mysterious local $/=undef is needed for binary files

		goto END_REQUEST if $this->checkStop($client,$request);

		# my $crlf = Socket::CRLF;
		# local $/ = undef;

		$keep_open = $response eq $RESPONSE_STAY_OPEN ? 1 : 0;

		my $is_handled =
			$response eq $RESPONSE_HANDLED ||
			$response eq $RESPONSE_STAY_OPEN ? 1 : 0;

		my $dbg_to = $dbg_from;
		$dbg_to =~ s/from /to /;

		my $content = ref($response) ? $response->{content} : '';
		my $len = length($content);
		my $dbg_content =
			$is_handled ? $response :
			ref($content) ? "FILE($content->{filename})" :
			defined($content) ? "content_bytes($len)" : '';
		my $dbg_resp = $is_handled ? '' :
			"$response->{status_line} ".
			"$response->{headers}->{'content-type'} ";

		$this->dbg(1,0,"response($request_num) $dbg_resp$dbg_content $dbg_to")
			if !$is_ping || $this->{HTTP_DEBUG_PING};

		$response->send_client($client) if !$is_handled;
			# all error reporting is done in send_client
			# and we don't care if it worked, or not

		undef($response);

		last if $is_ping;
		last if $is_handled;
		last if !$this->{HTTP_KEEP_ALIVE};
		last if $response->{CLOSE_CONNECTION};
		last if $this->{stopping};

		$request->init_for_re_read();
			# clear the request {headers}, {content}, etc
			# in preparation for another read
	}

END_REQUEST:

	close($client) if !$keep_open;
	$this->dbg(1,1,"requestThread($request_num) finished");
	return $keep_open ? $client : 0;

}   # requestThread()



#------------------------------------------
# checkAuthorization()
#-------------------------------------------

sub checkAuthorization
    # Check a request authorization versus a user file.
    #
    # Public method to allow clients to implement authorization
    # per directory, etc, over and above the hard wired "entire-site"
    # authorization scheme baked into ServerBase.
    #
    # Returns a 401 response if not authorized.
{
    my ($this,$request,$auth_file,$auth_encrypted) = @_;
    my $dbg_from = "from $request->{peer_ip}:$request->{peer_port}";

    my $auth_ok = 0;
    my $credentials = $request->{headers}->{authorization};
    if ($credentials)
    {
        $credentials =~ s/^\s*basic\s+//i;
        my $decoded = decode64($credentials);
        my ($uid,$pass) = split(/:/,$decoded,2);
        $this->dbg(1,1,"checking credentials($uid:_pass_)=$credentials");

        my $pss = my_encrypt($pass);
        my $user = getValidUser(
                $auth_encrypted,
                $auth_file,
                $uid,
                $pss);

        # privs, by convention, is a comma delimited list of pid:level
        # where pid is a program id, and level is an integer, BUT NOTE
        # that this base Pub::HTTP::ServerBase.pm does NOT ENFORCE
        # or check it in any way before passing it the higher level
        # derived HTTPS server ...

        if ($user)
        {
            $auth_ok = 1;
            $request->{auth_user} = $uid;
            $request->{auth_privs} = $user->{privs};
            $this->HTTP_LOG($request,0,"accepted($user->{privs}) credentials for user $uid $dbg_from");
        }
        else
        {
            $this->HTTP_LOG(undef,-1,"ERROR: Bad Credentials('"._def($user)."','"._def($pass)."') $dbg_from");
        }
    }
    else
    {
        $this->HTTP_LOG(undef,-1,"ERROR: No Credentials presented $dbg_from");
    }

    my $response= undef;
    if (!$auth_ok)
    {
        $response = Pub::HTTP::Response->new($request,
			"Authorization Required",401,'text/plain');
    }
    return $response;
}



#----------------------------------
# base class handle_request
#----------------------------------
# Base class serves from DOCUMENT_ROOT if provided,
# with CGI like interface to perl pm, pl, and cgi files.

my $global_server;
my $global_request;
my $global_response;

sub get_server
{
	return $global_server;
}
sub get_request
{
	return $global_request;
}
sub set_response
{
	my ($response) = @_;
	$global_response = $response;
}


sub getMinifiedUri
{
	my ($this,$puri,$ext) = @_;

	if (($ext eq 'js' && $this->{HTTP_MINIFIED_JS}) ||
		($ext eq 'css' && $this->{HTTP_MINIFIED_CSS}))
	{
		my $uri = $$puri;
		$uri =~ s/$ext$/min.$ext/;
		my $filename = makePath($this->{HTTP_DOCUMENT_ROOT},$uri);
		display(5,0,"checking MIN: $filename");
		if (-f "$filename")
		{
			$this->dbg(-1,1,"serving MIN: $filename");
			$$puri = $uri;
		}
		return 1;
	}
}



sub handle_request
{
    my ($this,$client,$request) = @_;
	my $doc_root = $this->{HTTP_DOCUMENT_ROOT};
	return if !$doc_root;

	my $dbg_num = "$request->{request_num}/".($this->{running}-1);
	my $uri = $request->{uri};
	my $method = $request->{method};
	$this->dbg(1,0,"Pub::ServerBase::handle_request($dbg_num) $method $uri");

	# SPECIFIC URLS

	if ($uri =~ /^\/(favicon.ico)/ &&
		$this->{HTTP_FAVICON})
	{
		my $filename = makePath(
			$this->{HTTP_DOCUMENT_ROOT},
			$this->{HTTP_FAVICON});
		return Pub::HTTP::Response->new($request,
			{filename => $filename } );
	}

	# debug_output now handled by base class
	# needs to be removed from all derived classes

	elsif ($uri =~ s/^\/debug_output\///)
	{
		my $msg = $uri . " ". ($request->{param_str} || '');
		my $color = $msg =~ /ERROR/ ?
			$DISPLAY_COLOR_ERROR :
			$UTILS_COLOR_LIGHT_GREEN;
		display(0,-1,"REMOTE: ".url_decode($msg),0,$color);

		# Pub::Utils::_setColor($color);
		# print "REMOTE: ".url_decode($msg)."\n";
		# Pub::Utils::_setColor($DISPLAY_COLOR_NONE);
		return http_ok($request,"");
	}

	elsif ($uri eq "/shutdown_system" && !is_win() && $this->{HTTP_ALLOW_REBOOT})
	{
		LOG(0,"Shutting down the rPi");
		system("sudo shutdown");
		return html_ok($request,"Shutting down the Server");
	}
	elsif ($uri eq "/reboot" && !is_win() && $this->{HTTP_ALLOW_REBOOT})
	{
		LOG(0,"Rebooting the rPi");
		system("sudo reboot");
		return html_ok($request,"Rebooting Server");
	}
	elsif ($uri eq '/restart_service' && $AS_SERVICE && $this->{HTTP_RESTART_SERVICE} )
	{
		# this url should ONLY be hit if the JS has the as_service variable set.
		# there is no error checking.

		LOG(0,"Artisan restarting service in 5 seconds");
		restartService( $this->{HTTP_RESTART_SERVICE});
		return html_ok($request,"Restarting Service");
	}
	elsif ($uri =~ /update_system(_stash)*/ && $this->{HTTP_GIT_UPDATE})
	{
		my $do_stash = $1 ? 1 : 0;
		LOG(0,"Updating system source($this->{HTTP_GIT_UPDATE}) stash($do_stash)");
		my $text = '';
		my $rslt = Pub::ServiceUpdate::doSystemUpdate(
			\$text,
			$do_stash,
			[split(/,/,$this->{HTTP_GIT_UPDATE})]);
		my $line1 = git_result_to_text($rslt);
		$text =~ s/\n/<br>/g;
		if ($rslt == $GIT_UPDATE_DONE &&
			$AS_SERVICE && $this->{HTTP_RESTART_SERVICE})
		{
			$line1 .= "<br>Restarting service in 1 second";
			restartService( $this->{HTTP_RESTART_SERVICE});
		}
		return html_ok($request,$line1."<br>".$text);
	}
	elsif ($uri eq "/log")
	{
		return Pub::HTTP::Response->new($request,
            shared_clone({filename=>$logfile}),
			200,'text/plain');
	}
	elsif ($uri eq "/log/clear")
	{
		if (!(-f $logfile))
		{
			return http_ok($request,"LOGFILE $logfile does not exist");
		}
		else
		{
			unlink $logfile;
			sleep(1);
			LOG(-1,"logfile $logfile cleared");
			sleep(1);
			return Pub::HTTP::Response->new($request,
				shared_clone({filename=>$logfile}),
				200,'text/plain');
		}
	}

	# PORT FORWARDING TOGGLE

	elsif ($uri =~ /^\/forward_(start|stop)/)
	{
		# Handled as a modification to the prefs followed by a service restart
		# The HTTP_FWD_PORT is stored persistently in pref IOT_USE_FWD_PORT

		my $port = '';
		my $command = $1;
		my $is_forwarded = Pub::PortForwarder::isThreadRunning();

		LOG(0,"FORWARD_COMMAND($command) is_forwarded($is_forwarded)");

		return http_error($request,"PortForwarder is already running")
			if $command eq 'start' && $is_forwarded;
		return http_error($request,"PortForwarder is not running")
			if $command eq 'stop' && !$is_forwarded;

		setPref('HTTP_DO_FORWARD',$command eq 'start' ? 1 : 0);
		writePrefs();

		# service will be restarted only $AS_SERVICE
		# must be restarted manually for testing from command lline

		restartService( $this->{HTTP_RESTART_SERVICE});
		return html_ok($request,"$uri restarting Service");
	}


	# FALL THROUGH TO GENERIC FILE REQUESTS
    # don't allow .. addressing

    if ($uri =~ /\.\./)
    {
        $this->HTTP_LOG(undef,-1,"ERROR: request($dbg_num) - No relative (../) urls allowed: $uri");
        return;
    }

	# Strip leading '/' if present and see if the file exists

	$uri =~ s/^\///;
	my $filename = "$doc_root/$uri";
    if (!-f $filename)
	{
		error("request($dbg_num) $method $filename FILE DOES NOT EXIST");
		return;
	}


	#----------------------------
	# STATIC GET REQUESTS
	#----------------------------
    # We allow any type with a known Mime Type here
    # subject to client's ALLOW_GET_EXTENSIONS_RE
	# $uri =~ /.*\.(html|htm|js|css|jpg|gif|png|ico|pdf|txt)$/)

	my $mime_type = myMimeType($uri);

	if ($mime_type &&
        $method eq 'GET' &&
        $this->{HTTP_GET_EXT_RE} &&
		$uri =~ /\.($this->{HTTP_GET_EXT_RE})$/)
	{
		my $ext = $1;
		$filename = "$doc_root/$uri"
			if $this->getMinifiedUri(\$uri,$ext);

		$this->dbg(2,0,"getting $filename");

		my $text = getTextFile($filename,1);
		$text = processBody($text,$request,$this,$doc_root)
			if $ext eq 'html';

		my $ext_headers = $this->{"HTTP_DEFAULT_HEADERS_".uc($ext)};
		my $response = Pub::HTTP::Response->new($request,$text,200,$mime_type,$ext_headers);
		$response->setAsCached() if
			$ext =~ /js|css/ &&
			$this->{HTML_USE_INCLUDES};

		return $response;
	}

	#----------------------------
	# PERL CGI REQUESTS
	#----------------------------
    # Requires HTTP_SCRIPT_EXT_RE
	#	$uri =~ /.*\.(pm|pl|cgi)(\?.*)*$/)
    #
	# Perl scripts are run in the context of the
	# current Perl interpeter.  Code gets the request
	# using Pub::HTTP::ServerBase::get_request(), and
	# returns the result using set_response().
	#
	# These methods use a non-shared global variable
	# which will be private to each request.

	if ($method =~ /^(GET|POST)$/ &&
        $this->{HTTP_SCRIPT_EXT_RE} &&
		$uri =~ /.*\.($this->{HTTP_SCRIPT_EXT_RE})(\?.*)*$/)
	{
		my $ext = $1;
		$global_server = $this;
		$global_request = $request;

		$this->HTTP_LOG($request,1,"Calling do($filename)");
		my $rslt;

		try
		{
			$rslt = do($filename);
		}
		catch Error with
		{
			my $ex = shift;
			$this->HTTP_LOG(undef,-1,"ERROR in Pub::ServerBase::handle_request($dbg_num) do($filename): $ex");
		};

		# display(0,1,"do($filename) returned '"._def($rslt)."'");
        if (!defined($rslt))
        {
             $this->HTTP_LOG(undef,-1,"ERROR: no rslt in Pub::ServerBase::handle_request($dbg_num) do($filename): "._def($!)." ~~ "._def($@));
        }
        else
        {
            $this->dbg(1,1,"do($filename) returned '"._def($rslt)."'");
        }

		my $response = $global_response;
		$global_request = undef;
		$global_response = undef;
		$global_server = undef;

		display(0,1,"do($filename) returning response="._def($response));
		$this->dbg(1,1,"do_response($method $uri)=$response->{headers}->{'content-type'}") if $response;
		return $response if $response;
	}

	return; # null return
}



#----------------------------------------------
# methods for browser caching
#----------------------------------------------
# These are called back from processBody()
# to include CSS and JS with ?792390747 dt stamps
# for the HTML_USE_INCLUDES scheme.


sub includeJS
{
	my ($this,$path) = @_;
	my $uri = $path;
	$this->getMinifiedUri(\$uri,'js');
	my $filename = makePath($this->{HTTP_DOCUMENT_ROOT},$uri);
    my $mtime = getFileTime($filename);
	$this->dbg(0,0,"includeJS($path)=$mtime");
    return "<script type=\"text/javascript\" src=\"$path?$mtime\"></script>";
}



sub includeCSS
{
	my ($this,$path) = @_;
	my $uri = $path;
	$this->getMinifiedUri(\$uri,'css');
	my $filename = makePath($this->{HTTP_DOCUMENT_ROOT},$uri);
    my $mtime = getFileTime($filename);
	$this->dbg(0,0,"includeCSS($path)=$mtime");
	return "<link rel=\"stylesheet\" type=\"text/css\" href=\"$path?$mtime\" />";
}


1;
