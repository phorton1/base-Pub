#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::SocketSession
#-------------------------------------------------------
# A SocketSession has a SOCK on which it can operate.
# The object provides sendPacket() and getPacket().

package Pub::FS::SocketSession;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw( sleep  );
use IO::Select;
use Pub::Utils;
use Pub::FS::FileInfo;
use Pub::FS::Session;
use base qw(Pub::FS::Session);


our $dbg_packets:shared =  0;
our $DEBUG_PING = 0;


BEGIN {
    use Exporter qw( import );
	our @EXPORT = ( qw (

		$dbg_packets
		dbgPacket

		$DEFAULT_PORT
		$DEFAULT_SSL_PORT
		$DEFAULT_HOST
		$DEFAULT_TIMEOUT
	),
	@Pub::FS::Session::EXPORT );
}

our $DEFAULT_PORT = 5872;
our $DEFAULT_SSL_PORT = 5873;
our $DEFAULT_HOST = "localhost";
our $DEFAULT_TIMEOUT = 15;

my $instance = 0;
my %in_protocol:shared;

#------------------------------------------------
# new()
#------------------------------------------------

sub new
{
	my ($class, $params, $no_error) = @_;
	$params ||= {};
	$params->{SOCK} ||= '';
	$params->{TIMEOUT} ||= $DEFAULT_TIMEOUT;
	$params->{NAME} ||= 'SocketSession';

	my $this = $class->SUPER::new($params);
	$this->{instance} = $instance++;
	$in_protocol{$this->{instance}} = 0;

	bless $this,$class;
	return $this;
}


sub DESTROY
{
	my ($this) = @_;
	delete $in_protocol{$this->{instance}};
}

#--------------------------------------------------
# packets
#--------------------------------------------------
# sendPacket() and getPacket() return errors on failures.

sub dbgPacket
{
	my ($dbg_level,$packet) = @_;
	my @lines = split(/\r/,$packet);
	my @parts = split(/\t/,shift @lines);
	$parts[3] = "content(".length($parts[3]).")"
		if $parts[0] eq $PROTOCOL_BASE64;
	my $rslt = join('  ',@parts);
	$rslt .= $debug_level > $dbg_level ?
		join("\r\n",@lines) :
		"  lines(".scalar(@lines).")"
		if @lines;
	return $rslt;
}


sub sendPacket
	# returns 0 on failure, 1 on success
{
    my ($this,$packet) = @_;

	my $is_ping = $packet =~ /^$PROTOCOL_PING/;
	display($dbg_packets,-1,"$this->{NAME} --> ".dbgPacket($dbg_packets,$packet),1)
		if (!$is_ping || $DEBUG_PING) && $dbg_packets <= 0;

    my $sock = $this->{SOCK};
	return error("$this->{NAME} no socket in sendPacket",1,1)
		if !$sock;

	$packet =~ s/\s+$//g;

	if (0)	# OLD WAY
	{
		if (!$sock->send($packet."\r\n"))
		{
			$this->{SOCK} = undef;
			return error("$this->{NAME} could not write to socket $sock",1,1);
		}
	}
	else	# NEW WAY REQUIRED FOR SSL, works for regular sockets
	{
		my $full_packet = $packet."\r\n";
		my $len = length($full_packet);
		my $bytes = syswrite($sock,$full_packet);
		if ($bytes != $len)
		{
			$this->{SOCK} = undef;
			return error("$this->{NAME} could only write($bytes/$len) bytes to socket $sock",1,1);
		}
	}

	$sock->flush();
    return '';
}


sub incInProtocol
{
	my ($this) = @_;
	$in_protocol{$this->{instance}}++;
}
sub decInProtocol
{
	my ($this) = @_;
	$in_protocol{$this->{instance}}--;
}



sub getPacket
	# fills in the passed in reference to a packet.
	# returns an error at call_level=1 or '' upon success.
	# The protocol passes in $is_protocol, which blocks and prevents other
	# callers from getting packets.  Otherwise, the method does not block.
{
    my ($this,$ppacket,$is_protocol) = @_;
	$is_protocol ||= 0;
	$$ppacket = '';

    my $sock = $this->{SOCK};
	return error("$this->{NAME} no socket in getPacket",1,1)
		if !$sock;

	return '' if !$is_protocol && $in_protocol{$this->{instance}};

	# if !protocol, return immediately
	# otherwise, watch for timeouts

	my $can_read;
	my $started = time();
	my $select = IO::Select->new($sock);
	while (1)
	{
		$can_read = $select->can_read(0.1);
		last if $can_read;
		return '' if !$is_protocol;
		return error("getPacket timed out",1,1)
			if time() > $started + $this->{TIMEOUT};
	}

	# can_read is true here

	my $CRLF = "\015\012";
	local $/ = $CRLF;

	$$ppacket = <$sock>;
	if (!defined($$ppacket))
	{
		$this->{SOCK} = undef;
		return error("$this->{NAME} no response from peer",1,1);
	}

	$$ppacket =~ s/\s+$//g;
	if (!$$ppacket)
	{
		$this->{SOCK} = undef;
		return error("$this->{NAME} empty response from peer",1,1);
	}

	my $is_ping = $$ppacket =~ /^$PROTOCOL_PING/;
	display($dbg_packets,-1,"$this->{NAME} <-- ".dbgPacket($dbg_packets,$$ppacket),1)
		if (!$is_ping || $DEBUG_PING) && $dbg_packets <= 0;

	return '';

}	# getPacket()



1;
