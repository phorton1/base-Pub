#!/usr/bin/perl
#---------------------------------------
# HTTPServer.pm
#---------------------------------------
# intended to be generalizable to Pub::HTTPServer

package Pub::HTTPServer;
use strict;
use warnings;
use threads;
use threads::shared;
# use Fcntl;
# use Socket;
use IO::Socket;
use IO::Select;
use Pub::Utils;
use Pub::httpUtils;
use Pub::ServerUtils;
use Win32::OLE;


Win32::OLE::prhSetThreadNum(1);


# our $SINGLE_THREAD = 0;
	# 0 requires the use of Win32::OLE::prhSetThreadNum(1)



my $dbg_http = 0;
	#  0 == lifecycle
my $dbg_post = 1;
	#  0 == show POST data
my $dbg_connect = 1;
	#  0 == show individual connections
	# -1 == rarely used to show pending connnections in case there is
	#       more than one at a time or to debug $FH closing at end
my $dbg_hdr = 1;
	#  0 == show actual request header lines
my $dbg_request = 0;
	#  0 == show a header for every request
	# -1 == show request headers for same
my $dbg_response = 1;
	#  0 = show header
	#  1 = show first line
	#  2 = show headers
	#  3 = show entire response
my $dbg_minjs = 0;
	# show if sending minified js/css
my $dbg_html = 1;
	# debug processHTML



sub start_webserver
	# this is a separate thread, even if $SINGLE_THREAD
{
	my ($params) = @_;

	# My::Utils::setOutputToSTDERR();
	# My::Utils::set_alt_output(1);

	display($dbg_http,0,"HTTPServer starting ...");

	my $socket;
	my $select = IO::Select->new();

	my @sock_params = (
		Proto => 'tcp',
		LocalPort => $params->{SERVER_PORT},
		Listen => SOMAXCONN,
		Reuse => 1 );
	$socket = IO::Socket::INET->new(@sock_params);
	if (!$socket)
	{
		error("Could not create socket on port $params->{SERVER_PORT}");
		return;
	}
	binmode $socket;
	$select->add($socket);

    LOG(0,"HTTPServer started on $server_ip:$params->{SERVER_PORT}");
	while (1)
	{
		my @connections_pending = $select->can_read($params->{SINGLE_THREAD}?1:60);
		display($dbg_connect+1,0,"accepted ".scalar(@connections_pending)." pending connections")
			if (@connections_pending);
		for my $connection (@connections_pending)
		{
			my $client;
			my $remote = accept($client, $connection);
			my ($peer_port, $peer_addr) = sockaddr_in($remote);
			my $peer_ip = inet_ntoa($peer_addr);

			if ($params->{SINGLE_THREAD})
			{
				handle_connection( $client, $peer_ip, $peer_port, $params);
			}
			else
			{
				my $thread = threads->create(\&handle_connection, $client, $peer_ip, $peer_port, $params);
				$thread->detach();
			}
		}
	}
}



sub handle_connection
{
	my ($client,$peer_ip,$peer_port,$params) = @_;
	binmode($client);

	# My::Utils::setOutputToSTDERR();
	# My::Utils::set_alt_output(1) if (!$SINGLE_THREAD);

	display($dbg_connect,0,"HTTP connect from $peer_ip:$peer_port");

	#=================================
	# parse http request header
	#=================================

	my $request_method;
	my $request_path;
	my %request_headers = ();

	my $first_line;
	my $request_line = <$client>;
	display($dbg_hdr,0,"ACTUAL HEADERS");
	while (defined($request_line) && $request_line ne "\r\n")
	{
		# next if !$request_line;
		$request_line =~ s/\r\n//g;
		chomp($request_line);

		display($dbg_hdr,1,$request_line);

		if (!$first_line)
		{
			$first_line = $request_line;
			my @parts = split(' ', $request_line);
			close $client if @parts != 3;
			$request_method = $parts[0];
			$request_path = $parts[1];
			my $http_version = $parts[2];
		}
		else
		{
			my ($name, $value) = split(':', $request_line, 2);
			$name =~ s/-/_/g;
			$name = uc($name);
			$value =~ s/^\s//g;
			$request_headers{$name} = $value;
		}
		$request_line = <$client>;
	}

	# if we got no request line,
	# then it is an unrecoverable error

	if (!$first_line ||
		!defined($request_method) ||
		!defined($request_path))
	{
		error("Unable to parse HTTP from $peer_ip:$peer_port line="._def($first_line));
		my $response = http_header({
			status_code   => 501,
			content_type => 'text/plain' });
		print $client $response;
		close($client);
		return 0;
	}

	display($dbg_request,0,"$request_method $request_path from $peer_ip:$peer_port")
		if !$params->{NODEBUG} || $request_path !~ $params->{NODEBUG};
	for my $key (keys %request_headers)
	{
		display($dbg_request+1,1,"$key=$request_headers{$key}");
	}

	#=================================
    # Get POST/NOTIFY data
	#=================================
	# NOTIFY is currently unused, but needed to support
	# remoteLibrary::subscribe()

	my $post_data = '';
	if ($request_method eq "POST" ||
		$request_method eq "NOTIFY" )
	{
		my $content_length = $request_headers{CONTENT_LENGTH};
		if (defined($content_length) && length($content_length) > 0)
		{
			display($dbg_post,1,"Reading $content_length bytes for POSTDATA");
			read($client, $post_data, $content_length);
		}
		else
		{
			display($dbg_post,1,"Reading content until  cr-lf for POSTDATA");
			my $line = <$client>;
			while ($line && $line ne "\r\n")
			{
				$post_data .= $line;
				$line = <$client>;
			}
		}
		display($dbg_post,1,"POSTDATA: $post_data");
	}


	#===============================================================
	# Handle the requests
	#===============================================================

	my $response;

	$request_path = $params->{DEFAULT_LOCATION}
		if $request_path eq '/' && $params->{DEFAULT_LOCATION};

	if ($request_path eq '/favicon.ico')
	{
		my $icon = $params->{FAVICON};
		if ($icon && -f $icon)
		{
			display($dbg_html,1,"favicon = $icon");
			my $mime_type = myMimeType($icon);
			$response = http_header({ content_type => $mime_type });
			$response .= getTextFile($icon,1);
			$response .= "\r\n";
		}
	}

	elsif ($params->{HANDLER})
	{
		$response = &{$params->{HANDLER}}(
			$request_path,
			$request_method,
			$post_data,
			$client,
			$params,
			\%request_headers,
			$peer_ip,
			$peer_port);
	}

	if (!$response &&
		$params->{DOCUMENT_ROOT} &&
		$request_path =~ /^((.*\.)($params->{ALLOW_GET_EXTENSIONS_RE}))$/)
	{
		my ($filename,$ext) = ($1,$3);
		$response = localFile($params,$filename,$ext);
	}

	if (!$response)
	{
		error("Unsupported request $request_method $request_path from $peer_ip:$peer_port");
		$response = http_header({ status_code => 501 });
	}


    #===========================================================
    # send response to client
    #===========================================================

	display($dbg_response,1,"Sending ".length($response)." byte response");

	if ($dbg_response < 0)
	{
		my $first_line = '';
		my $content_type = '';
		my $content_len  = '';

		# run through the headers

		my $in_body = 0;
		my $started = 0;
		my @lines = split(/\n/,$response);
		for my $line (@lines)
		{
			$line =~ s/\s+$//;
			if (!$first_line)
			{
				$first_line = $line;
				display($dbg_response,2,$line);
				last if $dbg_response == -1;
			}
			else
			{
				last if !$line && $dbg_response > -3;
				display(0,2,$line);
			}
		}
	}

	(print $client $response) ?
		display($dbg_response+1,1,"Sent response OK") :
		error("Could not complete HTTP Server Response len=".length($response));
	close($client);

}   # handle_connection()




sub localFile
{
	my ($params,$filename,$ext) = @_;

	my $response;
	my $fullname = "$params->{DOCUMENT_ROOT}$filename";
	display($dbg_html,1,"localFile() fullname=$fullname");
	if (!(-f $fullname))
	{
		$response = http_error("Could not open file: $fullname");
	}
	else
	{
		my $content_type = myMimeType($ext);

		# add CORS cross-origin headers to the main HTML file
		# allow cross-origin requests to iPad browsers
		# which would not call /get_art/ to get our album art URIs otherwise

		# Modified to allow most generous CORS options while messing with
		# 	cross-origin webUI request, but this is not, per se, specifically
		# 	needed for those.

		my $addl_headers = [];
		if ($ext eq 'html')
		{
			push @$addl_headers,"Access-Control-Allow-Origin: *";			# was http://$server_ip:$server_port";
			push @$addl_headers,"Access-Control-Allow-Methods: GET";		# OPTIONS, POST, SUBSCRIBE, UNSUBSCRIBE
		}
		if (0 && $ext =~ /jpg|png|gif/)
		{
			push(@$addl_headers, 'Cache-Control: max-age=3600');
		}

		$response = http_header({
			content_type => $content_type,
			addl_headers => $addl_headers });

		if ($params->{SEND_MINIFIED_JS_AND_CSS} && ($ext eq 'js' || $ext eq 'css'))
		{
			my $fullname2 = $fullname;
			$fullname2 =~ s/\.$ext$/.min.$ext/;
			display($dbg_minjs+1,0,"checking MIN: $fullname2");
			if (-f "$fullname2")
			{
				display($dbg_minjs,1,"serving MIN: $fullname2");
				$fullname = $fullname2;
			}
		}

		my $text = getTextFile($fullname,1);
		$text = process_html($params,$text) if $ext eq 'html';
		$response .= $text."\r\n";
	}

	return $response;
}



sub process_html
{
	my ($params,$html,$level) = @_;
	$level ||= 0;

	# special global variable replacement

	my $is_win = is_win() ? 1 : 0;
	my $as_service = $AS_SERVICE ? 1 : 0;
	my $machine_id = getMachineId();

	$html =~ s/is_win\(\)/$is_win/s;
	$html =~ s/as_service\(\)/$as_service/s;
	$html =~ s/machine_id\(\)/$machine_id/s;

	while ($html =~ s/<!-- include (.*?) -->/###HERE###/s)
	{
		my $id = '';
		my $spec = $1;
		$id = $1 if ($spec =~ s/\s+id=(.*)$//);

		my $filename = "$params->{DOCUMENT_ROOT}$spec";
		display($dbg_html,0,"including $filename  id='$id'");
		my $text = getTextFile($filename,1);

		$text =~ s/{id}/$id/g;

		$text = process_html($params,$text,$level+1);
		$text = "\n<!-- including $filename -->\n".
			$text.
			"\n<!-- end of included $filename -->\n";

		$html =~ s/###HERE###/$text/;
	}

	if (0 && !$level)
	{
		while ($html =~ s/<script type="text\/javascript" src="\/(.*?)"><\/script>/###HERE###/s)
		{
			my $filename = $1;
			display($dbg_html,0,"including javascript $filename");
			my $eol = "\r\n";
			# my $text = getTextFile($filename,1);

			my $text = $eol.$eol."<script type=\"text\/javascript\">".$eol.$eol;
			my @lines = getTextLines($filename);
			for my $line (@lines)
			{
				$line =~ s/\/\/.*$//;
				$text .= $line.$eol;
			}

			while ($text =~ s/\/\*.*?\*\///s) {};
			$text .= $eol.$eol."</script>".$eol.$eol;
			$html =~ s/###HERE###/$text/s;
		}
	}

	return $html;
}



1;
