#!/usr/bin/perl
#-----------------------------------------------------
# A Response from My HTTP Server
#-----------------------------------------------------
# Performs gzip content compression ala the
# request accept and server USE_GZIP_RESPONSES
# preferences.


package Pub::HTTP::Response;
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Socket;
use IO::Socket::SSL;
use IO::Compress::Gzip qw(gzip);
use JSON;
use Pub::Utils;
use base qw(Pub::HTTP::Message);


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

		http_ok
		http_error
		html_ok
		json_error
		json_response

		$RESPONSE_HANDLED
		$RESPONSE_STAY_OPEN
    );
}


our $RESPONSE_HANDLED = 'RESPONSE_HANDLED';
	# for responses that get fully handled by their derived classes
our $RESPONSE_STAY_OPEN = 'RESPONSE_STAY_OPEN';
	# for responses that get fully handled by their derived classes


my $dbg_resp = 1;



sub http_ok
{
    my ($request,$msg) = @_;
    return Pub::HTTP::Response->new($request,$msg);
}
sub http_error
{
    my ($request,$msg) = @_;
	error("HTTP_ERROR RESPONSE($request->{request_num}): $msg");
    return Pub::HTTP::Response->new($request,$msg,404,'text/plain');
}
sub html_ok
{
    my ($request,$msg) = @_;
    return Pub::HTTP::Response->new($request,$msg,200,'text/html');
}
sub json_error
{
    my ($request,$msg) = @_;
	error("JSON_ERROR RESPONSE($request->{request_num}): $msg->{error}");
    return Pub::HTTP::Response->new($request,{error => $msg},200,'application/json');
}
sub json_response
{
    my ($request,$data) = @_;
    return Pub::HTTP::Response->new($request,$data,200,'application/json');
}


sub addHeaders
{
	my ($this,$add_headers) = @_;
	my $headers = $this->{headers};
	for my $left (sort keys %$add_headers)
	{
		my $right = $add_headers->{$left} || '';
		if ($left eq 'cache-control')
		{
			delete $headers->{'pragma'};
			delete $headers->{'expires'};
		}
		if ($right eq 'undef')
		{
			delete $headers->{$left};
		}
		else
		{
			$headers->{$left} = $right;
		}
	}
}


sub dbg
{
	my ($this,$level,$indent,$msg,$call_level,$color) = @_;
	$call_level ||= 0;

	my $dbg_name = $this->get_dbg_name();
	$msg = $dbg_name." ".$msg;

	my $server = $this->{server};
	my $dbg_level = $this->{extra_debug};
	$dbg_level += $dbg_resp + $level - $server->{HTTP_DEBUG_RESPONSE};
	display($dbg_level,$indent,$msg,$call_level+1,$color)
		if $debug_level >= $dbg_level;
}





sub new
    # A Response is constructed in the context of a Request,
    # with a specific response code, content_type and content.
    #
    # The content may be a ref to hash containing, at this time,
    # one field, a filename. This is called a FILE RESPONSE
    #
    #     new Response($request,200,'application/zip',
    #          shared_clone({filename=>'blah.zip'}));
    #
    # If so, the file will be opened and the response delivered
    # via bufferred writes.  This is to support large files, like
    # zip files without reading them into memory.
    #
    # As such, {filename} responses are RANGED, and assumed to
    # point to persistent filenames that can be RESUMED at a later
    # time, and if the request contains a range, the range is used
    # in send_client()
    #
    # Note that the hash must be in shared memory!
{
    my ($class,$request,$content,$code,$content_type,$addl_headers) = @_;

	$content ||= '';
	$code ||= 200;
	$content_type ||= 'text/plain';

    my $server = $request->{server};
    my $this = $class->SUPER::new($server);
	bless $this,$class;

    $this->{is_response} = 1;
	$this->{request_num} = $request->{request_num};
	$this->{extra_debug} = $request->{extra_debug};
	$this->{request} = $request;
	$this->{server} = $request->{server};

	my $dbg_ref = ref($content) || '';
    my $dbg_content = !defined($content) ? 'undef' :
		$dbg_ref =~ /HASH/ ?
			$content->{filename} ? "FILE("._def($content->{filename}).")" :
			'HASH with '.scalar(keys %$content).' keys' :
		$dbg_ref =~ /ARRAY/ ?
			'ARRAY with '.scalar(@$content).' elements' :
        "scalar bytes(".length($content).")";

	my $dbg_to = $this->{request}->get_dbg_from();
    $this->dbg(2,0,"$code $content_type $dbg_content to $dbg_to");

    my $msg = '';
    $msg = 'OK' if $code == 200;
    $msg = 'MOVED' if $code == 302;
    $msg = 'NOT FOUND' if $code == 404;
    $msg = 'UNAUTHORIZED' if $code == 401;
    $msg = 'INTERNAL SERVER ERROR' if $code == 500;
    $msg = 'BAD GATEWAY' if $code == 502;

    $this->{code} = $code;
    $this->{status_line} = "HTTP/1.1 $code $msg";
    $this->{headers} = shared_clone({});

    mergeHash($this->{headers},$server->{HTTP_DEFAULT_HEADERS});

    $this->{headers}->{'content-type'} = "$content_type";
        # charsets not implemented
        # $response->{headers}->{'content-type'} .= "; charset=ISO-8859-1";
        # $response->{headers}->{'content-type'} .= "; charset=utf8";
	$this->addHeaders($addl_headers) if $addl_headers;

    if ($code == 401)
    {
        $this->{headers}->{'WWW-Authenticate'} =
            "Basic realm=\"$server->{HTTP_AUTH_REALM}\"";
    }

    # Handle File Response {filename} by setting up
    # content-length header and adding {size} member.
    # Currently dis-includes JSON which also comes in
    # as a ref.

    if (ref($content) && $content_type ne 'application/json')
    {
        my $filename = $content->{filename};
        if (!$filename)
        {
            error("No filename in File Response!");
            return;
        }
        if (!-f $filename)
        {
            error("Could not find $filename");
            return;
        }

        my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
          	$atime,$mtime,$ctime,$blksize,$blocks) = stat($filename);

        $content->{size} = $size || 0;
        $this->{headers}->{'content-length'} = $size || 0;
		$this->{headers}->{'content-type'} ||= myMimetype($filename);
        $this->{content} = ref($content) ? shared_clone($content) : $content;
    }

    # normal, in-memory response

    elsif ($content)
    {
        if (ref($content) && $content_type eq 'application/json')
        {
            $content = my_encode_json($content);
            my $txt = "new() encoded_json_length=".length($content);
            $this->dbg(2,1,$txt);
        }

        my $accept = $request->{headers}->{'accept-encoding'};
        my $zipit = $accept && $accept =~ /gzip/ ? 1 : 0;

        # I wonder if this could have been a factor in slowness.
        # Were we double zipping content-type application/zip?

        if ($zipit &&
            $content_type ne 'application/zip' &&
            $server->{HTTP_ZIP_RESPONSES})
        {
            $this->dbg(2,1,"new() zipping content_length=".length($content));
            my $zipped = '';
            gzip \$content => \$zipped;
            $content = $zipped;
            $this->{headers}->{'content-encoding'} = 'gzip';
            my $txt = "new() zipped content_length=".length($content);
            $this->dbg(2,1,$txt);
        }

        $this->{headers}->{'content-length'} = length($content);
        $this->{content} = $content;
    }

    return $this;
}




sub send_client
    # produce the string of bytes to send
    # to the remote for the request/response
    # $client->write($send)
{
    my ($this,$client) = @_;
    $this->dbg(0,0,"send_client($this->{status_line})");

    local $/ = undef;
    my $crlf = Socket::CRLF;
    my $server = $this->{server};

    # send the headers

    my $headers = $this->{headers};
    my $text = $this->{status_line}.$crlf;
    for my $key (sort keys %$headers)
    {
        $this->dbg(1,1,"header($key) = $headers->{$key}");
        $text .= "$key: $headers->{$key}$crlf";
    }
    $text .= $crlf;
    $this->dbg(1,1,"send_client header length=".length($text));
	if (!$client->write($text)) # print $client $send)
	{
		error("Could not send response headers to client");
        return;
	}

    # MEMORY RESPONSE
    # if it's in memory, just send the content
    # fall thru if no content

    my $content = $this->{content};
    if (defined($content) && !ref($content) && length($content))
    {
		$this->dbg(1,1,"WARNING: non-200 scalar reply: $content",0,$DISPLAY_COLOR_WARNING)
			if $this->{code} != 200;

        if (!$client->write($content)) # print $client $send)
        {
            error("Could not send content to client");
            return;
        }
        return 1;
    }


    # FILE RESPONSE
    # otherwise, do a loop, with possible range
    # fall thru if no content, filename, or size

    my $size = ref($content) ? $content->{size} : 0;
    my $filename = ref($content) ? $content->{filename} : '';
    if ($filename && $size)
    {
        $this->dbg(0,1,"FILE_RESPONSE($size,$filename)");
        my $fh;
        if (!open($fh,"<$filename"))
        {
            error("Could not open file $filename for reading");
            return;
        }
        binmode $fh;

        my $MAX_BUFFER = 1000000;

        my $offset = 0;
        my $bytes = $size;
        $bytes = $MAX_BUFFER if $bytes > $MAX_BUFFER;

        while ($bytes > 0)
        {
            $this->dbg(2,1,"read $bytes from $offset : $filename");

            my $buffer;
            my $bytes_read = sysread($fh,$buffer,$bytes);
            if (!$bytes_read || $bytes_read != $bytes)
            {
                error("Wanted($bytes) but could only read($bytes_read) from $filename at offset($offset)");
                close $fh;
                return;
            }
            $this->dbg(2,1,"send $bytes from $offset to client len(buffer)=".length($buffer));

            if (!$client->write($buffer)) # print $client $send)
            {
                error("Could not send $bytes bytes of content at offset $offset to client");
                close $fh;
                return;
            }

            $offset += $bytes;
            $bytes = $size - $offset;
            $bytes = $MAX_BUFFER if $bytes > $MAX_BUFFER;
        }
        close $fh;
    }

    return 1;

}   # Response::send_client();




#------------------------------------
# synchronous HTML/Plain text reply
#------------------------------------

my $client_handle;

sub startReply
	# send the header and
	# register as the receiver of Pub::Utils output
	# cannot put $client into shared memory Response object!
	# $this->{client} = $client;
{
    my ($class,$request,$code,$content_type,$client) = @_;

	my $this = $class->new($request,'',$code,$content_type);
	return if !$this->send_client($client);

	$client_handle = $client;
	$this->{output_html} = $content_type =~ /text\/html/ ? 1 : 0;
	Pub::Utils::setOutputListener($this);
	return $this;
}


sub endReply
{
	$client_handle = undef;
	Pub::Utils::setOutputListener(undef);
	return $RESPONSE_HANDLED;
}



sub onUtilsOutput
{
	my ($this,$full_message,$utils_color) = @_;

	if ($this->{output_html})
	{
		my $hex_color = $utils_color_to_rgb->{$utils_color} || 0;
		my $html_color = sprintf("#%06X",$hex_color);
		$full_message =~ s/\n/<br>\n/g;
		$full_message =~ s/ /&nbsp;/g;
		$full_message = "<font color='$html_color'>$full_message</font><br>";
	}

	$full_message .= "\r\n";
	my $rslt = $client_handle && $client_handle->write($full_message);

	# if the client handle went offline, then stop doing any output to it,
	# and we continue to rport errors back thru Pub::Utils until somebody
	# else unhooks us ...

	if ($client_handle && !$rslt)		# client handle went offline
	{
		$client_handle = undef;
		Pub::Utils::setOutputListener(undef);		# no more output to the connection
		error("Lost connection to client handle!");	# report the error anyways
	}

	return $rslt;
}






1;
