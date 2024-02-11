#!/usr/bin/perl
#-----------------------------------------------------
# Pub::HTTP::ServerBase
#-----------------------------------------------------
# Newly based on an example pooled threaded server i found
# at https://github.com/macnod/DcServer which uses Threads::Queue
# to pass the handle_number of the accepted socket to a pool of
# threads
#
# PARAMETERS:
#
#	DEBUG_SERVER => -1..2	optional - see notes below
#	DEBUG_REQUEST => 0..5	optional - see notes below
#	DEBUG_RESPONSE => 0..5	optional - see notes below
#
#	DEBUG_QUIET_RE => '',
#			# if the request matches this RE, the request
#			# and response debug levels will be bumped by 2
#			# so that under normal circumstances, no messages
#			# will show for these.
#	DEBUG_LOUD_RE => ''
#			# This RE can be used to debug particular URIS
#			# by effectively decreawing their debug levels by 2

#   DEBUG_PING => 0/1		optional - shows ping debugging at DEBUG_SERVER level
#
#	PORT					required
#	MAX_THREADS	=> 5		default(10)
#
#	SSL => 1				optional
# 	SSL_cert_file  			required if SSL
# 	SSL_key_file  			required if SSL
#
# 	AUTH_ENCRYPTED => 1		optional if AUTH_FILE
# 	AUTH_FILE      			drives user authentication
# 	AUTH_REALM     			required if AUTH_FILE
#
# 	USE_GZIP_RESPONSES => 1
# 	DEFAULT_HEADERS => {},
#
#	DOCUMENT_ROOT =>$base_dir,
#	DEFAULT_LOCATION => '/index.html'	# used for / requests
#   ALLOW_GET_EXTENSIONS_RE => 'html|js|css|jpg|png|ico',
#	ALLOW_SCRIPT_EXTENSIONS_RE => '',
#		allows scripts to be executed from the HTTP Server
#
#	LOGFILE				  	for HTTP separate logfile of HTTP_LOG calls
#	KEEP_ALIVE				use persistent connections from browsers
#
# IDLE TIMING AND LOCKING
#
#	Changing debug levels was affecting timing.
#	Some debugging made it faster, some made it slower.
#   Finally figured out that I had to rework the server thread vis-a-vis
#   using a quick timeout on the can_read() call, but still slowing it down
#   to a reasonable load level when idle.  Other details included using lock($this)
#   when bumping/decrementing $this->{active}.  It now seems to be working.


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
use Pub::Users;
use Pub::ProcessBody;
use Pub::DebugMem;
use Pub::HTTP::Request;
use Pub::HTTP::Response;
use Pub::HTTP::Message;
use Pub::ProcessBody;
use Pub::DebugMem;


our $dbg_server = 1;
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
my $DEFAULT_MAX_THREADS = 5;
	# If the user doesn't specify
my $DEFAULT_USE_GZIP_RESPONSES = 0;
    # if the client allows them, that is

my $accept_queue = Thread::Queue->new;
my $closed_queue = Thread::Queue->new;


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
	my $dbg_level = $level + $dbg_server - ($this->{DEBUG_SERVER} || 0);
	display($dbg_level,$indent,$msg,$call_level+1,$color);
}



sub HTTP_LOG
{
	my ($this,$indent_level,$msg,$call_level) = @_;
	$call_level ||= 0;
	$this->dbg(-1,$indent_level,$msg,$call_level+1,$UTILS_COLOR_WHITE);

	return if !$this->{LOGFILE};
	return if $SUPPRESS_HTTP_LOG;

	if (open OUTPUT_FILE,">>$this->{LOGFILE}")
	{
		my $tid = threads->tid();;
		my $dt = pad(now(1)." ".$login_name,28);
		my ($indent,$file,$line,$tree) = Pub::Utils::get_indent($call_level+1,0);
		my $header = "($tid,$indent_level)$file\[$line\]";

		$indent = 0 if $indent_level < 0;
		$indent_level = 0 if $indent_level < 0;

		my $full_message = $tree.$dt.pad($header,40 + ($indent+$indent_level) * 4).$msg;

		print OUTPUT_FILE $full_message."\n";
		close OUTPUT_FILE;
	}
}



#-------------------------------------------------
# Constructor, start() and stop()
#-------------------------------------------------


sub new
{
    my ($class,$params) = @_;

	display_hash(0,0,"Pub::ServerBase::new()",$params);
    if (!$params->{PORT})
    {
        error("You must provide a PORT for Pub::ServerBase::new()");
        return;
    }

    my $this = shared_clone({});
    mergeHash($this,shared_clone($params));
    bless $this,$class;

    $this->{running} = 0;
    $this->{stopping} = 0;
	$this->{request_num} = 0;
	$this->{active} = 0;

	$this->{DEBUG_SERVER} ||= 0;
	$this->{DEBUG_REQUEST} ||= 0;
	$this->{DEBUG_RESPONSE} ||= 0;
	$this->{DEBUG_QUIET_RE} ||= '';

	$this->{DEBUG_PING} ||= $OVERRIDE_DEBUG_PING;
	$this->{MAX_THREADS} ||= $DEFAULT_MAX_THREADS;
    $this->{DEFAULT_HEADERS} ||= shared_clone({});
    $this->{USE_GZIP_RESPONSES} = $DEFAULT_USE_GZIP_RESPONSES
        if !defined($this->{USE_GZIP_RESPONSES});

    # DEFAULT HEADER LIMITATIONS
    # no cache, no persistent connections
	# KEEP_ALIVE will cause the server to loop on the connection
	# until it times out and seems to work.

    my $def_headers = $this->{DEFAULT_HEADERS};
    $def_headers->{'cache-control'} ||= 'no-cache, no-store, must-revalidate';
    $def_headers->{'pragma'}        ||= 'no-cache';
    $def_headers->{'expires'}       ||= '0';
    $def_headers->{'connection'} 	||= $this->{KEEP_ALIVE} ? 'keep-alive' : 'close';

	# finished, return to caller

    $this->dbg(1,0,"HTTP SERVER CONSTRUCTED");
    return $this;
}



sub start
{
    my ($this) = @_;
	$this->dbg(0,0,"serverBase::start($this->{MAX_THREADS}) threads");
	my $server_thread = threads->create(\&serverThread,$this);
	$server_thread->detach();
	$this->dbg(2,1,"serverThread detatched");

	for (my $i=0; $i<$this->{MAX_THREADS}; $i++)
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
    my $port = $this->{PORT};
	my $dbg_ssl = $this->{SSL} ? ' SSL' : '';
    $this->HTTP_LOG(-1,"HTTP$dbg_ssl SERVER STARTING ON PORT($port)");

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
			for my $sock (@can_read)
			{
				if ($sock == $socket)
				{
					my $client_socket = $socket->accept();
					my $file_handle = fileno($client_socket);
					$open_sockets->{$file_handle} = $client_socket;

					my $peer_addr = $client_socket->peeraddr();
					my $peer_host = gethostbyaddr($peer_addr,AF_INET) || $client_socket->peerhost();
					my $peer_ip = inet_ntoa($peer_addr);
					my $peer_port = $client_socket->peerport();
					my $dbg_from =  "$peer_ip<$peer_host>:$peer_port";

					my $request_num = $this->{request_num}++;
					my $active = $this->{active};
					my $dbg_msg = dbg_queue();
					$this->dbg(0,0,"CONNECT($request_num) handle($file_handle) active($active) $dbg_msg $dbg_from");

					my $ele = shared_clone({
						file_handle => $file_handle,
						request_num => $request_num,
						peer_ip => $peer_ip,
						peer_port => $peer_port,
						peer_addr => $peer_addr,
						peer_host => $peer_host });

					$accept_queue->enqueue($ele);

					$last_connect = time();
					$sleep_time = $SLEEP_ACTIVE;

				}	# if ($sock == $socket)
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
				$this->dbg(0,0,"DISCONNECT($request_num) handle($file_handle) active($active) $dbg_msg");

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
    $this->HTTP_LOG(-1,"HTTP_SERVER STOPPED($this->{stopping},$this->{running})");


}   # serverThread()





#-------------------------------------------------------------------------
# clientThread() and clientRequest()
#-------------------------------------------------------------------------


sub checkStop
{
	my ($this,$request) = @_;
    if ($this->{stopping} || !$this->{running})
    {
        $this->dbg(1,0,"HTTP_SERVER request($request->{request_num} STOPPING ($this->{stopping},$this->{running})");
		return 1;
    }
}


sub clientThread
{
    my ($this,$thread_num) = @_;
    $this->dbg(1,0,"clientThread($thread_num) started");
	while (!$this->{stopping})
	{
		my $ele = $accept_queue->dequeue();
		if ($ele)
		{
			{
				lock($this);
				$this->{active}++;
			}
			clientRequest($this,$thread_num,$ele);
			{
				lock($this);
				$this->{active}--;
			}
			$closed_queue->enqueue($ele);
		}
	}

	$this->dbg(1,0,"clientThread($thread_num) finished");
}



sub clientRequest
{
	my ($this,$thread_num,$ele) = @_;

	my $request_num = $ele->{request_num};
	my $dbg_from = "from $ele->{peer_ip}:$ele->{peer_port}";
	my $file_handle = $ele->{file_handle};

	$this->dbg(1,0,"clientRequest($request_num) file_handle($file_handle) $dbg_from");

	my $request = Pub::HTTP::Request->new($this,{
		request_num =>	$ele->{request_num},
		peer_ip   => 	$ele->{peer_ip},
		peer_port => 	$ele->{peer_port},
		peer_host => 	$ele->{peer_host},
		peer_addr => 	$ele->{peer_addr} });

	my $client;
	if (!open($client, '+<&=' . $file_handle))
	{
		error("clientRequest($request_num) Could not create $client 'socket' file_handle($file_handle) $dbg_from: $!");
		return;
	}

    # UPGRADE SSL SOCKET

    if ($this->{SSL})
    {
        if (!IO::Socket::SSL->start_SSL($client,
                SSL_server => 1,
                SSL_cert_file => $this->{SSL_CERT_FILE},
                SSL_key_file => $this->{SSL_KEY_FILE}))
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

		if ($uri eq '/' && $this->{DEFAULT_LOCATION})
		{
			$uri = $this->{DEFAULT_LOCATION};
			$request->{uri} = $uri;
		}

		# detect pings, and log/debug the request

		my $is_ping = $method eq 'PING' || ($method =~ /get/i && $uri eq "/PING") ? 1 : 0;
		$this->HTTP_LOG(0,"request($request_num) $method $uri $dbg_from")
			if !$is_ping || $$this->{DEBUG_PING};

		# prep the socket

		binmode $client,':raw';
		# $client->blocking(0);

		# PINGS do not require authorization

		my $response;
		$response = Pub::HTTP::Response->new($request,200,"text/plain","PING OK\n\n")
			if $is_ping;

		# CHECK FOR AUTHORIZATION
		# and set the request auth_user and auth_privs fields
		# for use by implementation dependent servers

		if (!$response && $this->{AUTH_FILE})
		{
			$response = $this->checkAuthorization(
				$request,
				$this->{AUTH_FILE},
				$this->{AUTH_ENCRYPTED});
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
				$this->dbg(0,1,"WARNING: no response from handle_request($request_num) $request->{method} $request->{uri} $dbg_from");
				$response = http_error($request,"ERROR(404)\n\nThe uri($request->{uri}) was not found on this server");
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

		if ($response ne $RESPONSE_HANDLED)
		{
			my $dbg_to = $dbg_from;
			$dbg_to =~ s/from /to /;
			my $dbg_content = ref($response->{content}) ?
					"FILE($response->{content}->{filename})" :
				defined($response->{content}) ?
					"content_bytes(".length($response->{content}).")" : '';

			$this->HTTP_LOG(1,"response($request_num) $response->{status_line} ".
				"$response->{headers}->{'content-type'} ".
				"$dbg_content $dbg_to")
				if !$is_ping || $this->{DEBUG_PING};

			$response->send_client($client);
				# all error reporting is done in send_client
				# and we don't care if it worked, or not
		}

		my $quit_now =
			!$response ||
			$response eq $RESPONSE_HANDLED ||
			$response->{CLOSE_CONNECTION};
		undef($response);

		last if $quit_now;
		last if $is_ping;
		last if !$this->{KEEP_ALIVE};
		last if $this->{stopping};

		$request->init_for_re_read();
			# clear the request {headers}, {content}, etc
			# in preparation for another read
	}

END_REQUEST:

	$client->close();
	$this->dbg(1,1,"requestThread($request_num) finished");

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
            $this->HTTP_LOG(0,"accepted($user->{privs}) credentials for user $uid $dbg_from");
        }
        else
        {
            $this->HTTP_LOG(-1,"ERROR: Bad Credentials('"._def($user)."','"._def($pass)."') $dbg_from");
        }
    }
    else
    {
        $this->HTTP_LOG(-1,"ERROR: No Credentials presented $dbg_from");
    }

    my $response= undef;
    if (!$auth_ok)
    {
        $response = Pub::HTTP::Response->new($request,401,
            "text/plain","Authorization Required");
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


sub handle_request
{
    my ($this,$client,$request) = @_;
	my $doc_root = $this->{DOCUMENT_ROOT};
	return if !$doc_root;

	my $dbg_num = "$request->{request_num}/".($this->{running}-1);
	my $uri = $request->{uri};
	my $method = $request->{method};
	$this->dbg(1,0,"Pub::ServerBase::handle_request($dbg_num) $method $uri");

    # don't allow .. addressing

    if ($uri =~ /\.\./)
    {
        $this->HTTP_LOG(-1,"ERROR: request($dbg_num) - No relative (../) urls allowed: $uri");
        return;
    }

    # Strip of # anchors which are only used by browser

    $uri =~ s/#.*$//;

	# ABSOLUTE RELATIVE to DOCUMENT_ROOT
	# should be absolute requests from /
	# we give a warning if it's relative
	# and strip the / in any case

	if ($uri !~ s/^\///)
	{
		$this->dbg(0,1,"WARNING: relative uri: $uri");
	}

	my $filename = "$doc_root/$uri";
	$filename =~ s/\?.*$//;
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
        $this->{ALLOW_GET_EXTENSIONS_RE} &&
		$uri =~ /($this->{ALLOW_GET_EXTENSIONS_RE})/)
	{
		$this->dbg(2,0,"getting $filename");
		my $text = getTextFile($filename,1);
		$text = processBody($text,$request,$this,$doc_root) if $uri =~ /\.html$/;
		return Pub::HTTP::Response->new($request,200,$mime_type,$text);
	}

	#----------------------------
	# PERL CGI REQUESTS
	#----------------------------
    # Requires ALLOW_SCRIPT_EXTENSIONS_RE
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
        $this->{ALLOW_SCRIPT_EXTENSIONS_RE} &&
		$uri =~ /.*\.($this->{ALLOW_SCRIPT_EXTENSIONS_RE})(\?.*)*$/)
	{
		$global_server = $this;
		$global_request = $request;

		$this->HTTP_LOG(1,"Calling do($filename)");
		my $rslt;

		try
		{
			$rslt = do($filename);
		}
		catch Error with
		{
			my $ex = shift;
			$this->HTTP_LOG(-1,"ERROR in Pub::ServerBase::handle_request($dbg_num) do($filename): $ex");
		};


		# display(0,1,"do($filename) returned '"._def($rslt)."'");
        if (!defined($rslt))
        {
             $this->HTTP_LOG(-1,"ERROR: no rslt in Pub::ServerBase::handle_request($dbg_num) do($filename): "._def($!)." ~~ "._def($@));
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


#-------------------------------------------------
# Utilities for use by handle_request methods
# to capture output and obtain a database handle
#-------------------------------------------------
# this is thread safe to the degree that we use
# a global variable for the output buffer which
# will be different in different threads.


sub startCaptureOutput
	# start capturing the output
	# LOG, display(), etc, to a buffer
{
	my ($this) = @_;
	$this->{capture_buffer} = '';
	Pub::Utils::setOutputListener($this);
}


sub endCaptureOutput
	# returns the html for the captured output
	# and clear the buffer.
{
	my ($this) = @_;
	Pub::Utils::setOutputListener(undef);
	my $rslt = $this->{capture_buffer};
	$this->{capture_buffer} = '';
	return $rslt;
}


sub onUtilsOutput
{
	my ($this,$full_message,$utils_color) = @_;

	my $hex_color = $utils_color_to_rgb->{$utils_color} || 0;
	my $html_color = sprintf("#%06X",$hex_color);

	$full_message =~ s/\n/<br>\n/g;
	$full_message =~ s/ /&nbsp;/g;

	$this->{capture_buffer} .= "<font color='$html_color'>$full_message</font><br>\n";
}


1;
