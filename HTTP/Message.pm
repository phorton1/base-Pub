#!/usr/bin/perl
#-----------------------------------------------------
# Base class of My Requests and Responses
#-----------------------------------------------------
# Knows how to serialize a Message into a string
# and read one from a socket

package Pub::HTTP::Message;
use bytes;
    # This line is crucial esp with SSL.
    # Without it, Perl will mung binary streams into UNICODE,
    # and we can't deliver binary responses (i.e. gif files).
    # Also necessary are the various "local $/ = undef" calls.
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;


my $dbg_msg = 1;


my $msg_id:shared = 0;
    # every message gets an id, but it is actually
	# the request number (responses are paired to requests)
	# that is shown in debugging to make sense in the
	# context of debugging HTTP::ServerBase.


sub new
    # constructed in context of a Server
{
    my ($class,$server) = @_;
    my $this = shared_clone({});
    $this->{server} = $server;
    $this->{msg_id} = $msg_id++;
    bless $this,$class;
    return $this;
}



sub get_dbg_name
{
    my ($this) = @_;
    my $name = $this->{is_request} ? 'REQUEST' : 'RESPONSE';
	$name .= "($this->{request_num}";
	$name .= ":$this->{read_count}" if defined($this->{read_count});
	$name .= ")";
    return $name;
}

sub get_dbg_from
{
    my ($this) = @_;
    my $from = $this->{peer_ip} ? "$this->{peer_ip}:$this->{peer_port}" : '';
    return $from;
}



sub get_content_length
{
    my ($this) = @_;
    my $content_length = $this->{headers}->{'content-length'} || 0;
    return $content_length;
}




1;
