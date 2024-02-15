#!/usr/bin/perl
#-----------------------------------------------------
# A Request to My HTTP Server
#-----------------------------------------------------

package Pub::HTTP::Request;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON;
use IO::Socket;
use IO::Select;
use IO::Uncompress::Gunzip qw(gunzip);
use Pub::Utils;
use base qw(Pub::HTTP::Message);


my $dbg_req = 1;

my $READ_TIMEOUT = 2;
    # Timeout for reads (when we're already select-accepted)
my $SHOW_KEEP_ALIVE_TIMEOUT = 1;


sub dbg
{
	my ($this,$level,$indent,$msg,$call_level,$color) = @_;
	$call_level ||= 0;

	my $dbg_name = $this->get_dbg_name();
	$msg = $dbg_name." ".$msg;

	my $server = $this->{server};
	my $dbg_level = $this->{extra_debug};
	$dbg_level += $dbg_req + $level - $server->{HTTP_DEBUG_REQUEST};
	display($dbg_level,$indent,$msg,$call_level+1,$color)
		if $debug_level >= $dbg_level;
}


sub new
    # Constructed in the context of a server.
    # Params *should* include:
    #
	#	request_num
    #   peer_ip
    #   peer_port
    #   peer_host
    #   peer_addr
{
    my ($class,$server,$params) = @_;

	display_hash(0,0,"Pub::Requst->new()",$params)
		if $server->{HTTP_DEBUG_REQUEST} >= 5;

    my $this = $class->SUPER::new($server);
	bless $this,$class;

    mergeHash($this,$params);

    $this->{is_request} = 1;
    $this->{headers} ||= shared_clone({});
    $this->{content} ||= '';

	$this->{extra_debug} = 0;

    return $this;
}



sub getPostParams
    # standard method to parse post params
    # Note that we use the default '&' separator for both url and post params,
    # and that the data is not yet url decoded!
{
    my ($this,$dbg) = @_;
    $dbg = $dbg_req + $this->{debug_extra} if !defined($dbg);
    my $params = parseParamStr($this->get_content(),$dbg,'post_');
    return $params;
}



sub read_headers
    # should be in request
{
    my ($this,$socket) = @_;
	my $server = $this->{server};
	my $dbg_from = $this->get_dbg_from();

    $this->dbg(4,0,"read_headers() socket=$socket from $dbg_from");
	my $select = IO::Select->new($socket);

	my $ok = 0;
	my $time = time();
	my $use_time = $this->{READ_TIMEOUT} || $READ_TIMEOUT;

	while (!$ok && time() < $time + $use_time)
	{
		$ok = $select->can_read($use_time);
	}
	if (!$ok)
	{
		if ($this->{server}->{KEEP_ALIVE})
		{
			$server->dbg(1,0,"KEEP_ALIVE Message($this->{request_num})::read_headers() TIMEOUT")
				if $SHOW_KEEP_ALIVE_TIMEOUT;
		}
		else
		{
			# display_hash(0,0,"request timeout",$this);
			error("Message($this->{request_num})::read_headers() TIMEOUT($use_time)")
		}
		return;
	}

    # special setup

    local $/ = Socket::CRLF;
    binmode $socket;
    $socket->autoflush(1);

    # READ THE FIRST LINE and log any valid requests/responses.
    # For a variety of reasons (browser based) we can get
    # "empty" requests.  This code optionally shows them as
    # warnings, and skips them

    my $line = <$socket>;
    $line =~ s/\s*$// if defined($line);
    if (!defined($line))
    {
        $this->dbg(1,0,"read_headers - empty request from $dbg_from");
        return;
    }
	if ($line !~ /\s*(\w+)\s*([^\s]+)\s*(HTTP\/\d.\d)/ || !$1 || !$2 || !$3)
	{
		error("READ_HEADERS unknown request from $dbg_from line=$line");
		return;
	}

	$this->{method} = uc $1;
	$this->{uri} = $2;
	$this->{http_version} = $3;
	$this->{params} = shared_clone({});

	my $def_location = $this->{server}->{HTTP_DEFAULT_LOCATION} || '';
	$this->{uri} = $def_location
		if $def_location && $this->{uri} eq '/';

	my $quiet_re = $server->{HTTP_DEBUG_QUIET_RE};
	my $loud_re = $server->{HTTP_DEBUG_LOUD_RE};
	if ($quiet_re && $this->{uri} =~ /$quiet_re/)
	{
		$this->{extra_debug} += 2;
		# print "==> QUIET extra_debug($this->{uri})=$this->{extra_debug} re='$quiet_re'\n";
	}

	if ($loud_re && $this->{uri} =~ /$loud_re/)
	{
		$this->{extra_debug} -= 2;
		# print "==> LOUD  extra_debug($this->{uri})=$this->{extra_debug} re='$loud_re'\n";
	}

	$this->dbg(0,0,"$this->{method} $this->{uri} $this->{http_version} from $dbg_from");

		# REMOVE PARAMETERS FROM HEADERS BY DEFAULT

	if ($this->{uri} =~ s/\?(.*)$//)
	{
		my $dbg = $dbg_req + $this->{extra_debug};
		mergeHash($this->{params},parseParamStr($1,$dbg,"url_"));
	}


    # READ THE HEADERS

    while ($line = <$socket>)
	{
        chomp $line;
        $line =~ s/\s+$//;
        last if !$line;

        my ($type,$val) = split(/:/,$line,2);
        for ($type, $val)
        {
            s/^\s+//;
            s/\s+$//;
        }

        $type = lc($type);
        $this->{headers}->{$type} = $val;
        $this->dbg(1,1,"header($type) = $val");
    }
    $this->{content} = '';
    return $select;
}



sub read
    # read a message from the socket
    # client must have already constructed
    # $this as a semi-valid Request or Response,
    # and must pass $request=0/1 appropriately.
    #
    # client can check defined($this->{content}
    # to see if the headers have been finished
{
    my ($this,$socket) = @_;
    $this->dbg(4,0,"read()");

    my $select = $this->read_headers($socket);
    return if !$select;
    my $content_length = $this->{headers}->{'content-length'} || 0;

	if ($content_length)
	{
		$this->dbg(0,1,"read() content_length=$content_length");

		# READ THE CONTENT

		while (length($this->{content}) < $content_length)
		{
			my $have = length($this->{content});
			my $to_read = $content_length - $have;
			$this->dbg(1,1,"read($have:$to_read) of $content_length");

			my $buffer;
			my $did_read = read($socket, $buffer, $to_read) || 0;
			$this->{content} .= $buffer;

			if ($did_read != $to_read && !$select->can_read($READ_TIMEOUT))
			{
				my $dbg_from = $this->get_dbg_from();
				error("read($content_length,$have,$to_read,$did_read) TIMEOUT in content $dbg_from");
				return;
			}
		}
	}

    # return to caller

    return $this;

}   # Message::read()



sub init_for_re_read
{
	my ($this) = @_;
    $this->{headers} = shared_clone({});
    $this->{content} = '';
    $this->{method} = '';
	$this->{uri} = '';
	$this->{http_version} = '';
	$this->{decoded_content} = '';
}



sub get_decoded_content
{
    my ($this) = @_;
	return $this->{decoded_content} if $this->{decoded_content};
    my $content = $this->{content};
    if ($this->{headers}->{'content-encoding'} &&
        $this->{headers}->{'content-encoding'} =~ /gzip/)
    {
        $this->dbg(1,0,"get_content($this->{request_num}) unzipping ".length($content)." bytes of zip content");
        my $unzipped = '';
        gunzip \$content => \$unzipped;
        $this->dbg(1,0,"get_content() unzipped length=".length($unzipped));
		$content = $unzipped;
    }
    if ($this->{headers}->{'content-type'} eq 'application/json')
    {
        $this->dbg(1,0,"get_content() decoding ".length($content)." bytes of json");
        $content = shared_clone(decode_json($content));
        if (!$content)
        {
            error("Message($this->{request_num}) - Could not decode json");
        }
    }
	$this->{decoded_content} = $content;
    return $content;
}


1;
