#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::SocketSession
#-------------------------------------------------------
# A SocketSession has a SOCK on which it can operate.
#
# The object provides sendPacket() and getPacket().
# There is special code to protect FC::Window INSTANCES
# from re-entering sendPacket() and getPacket().



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
our $dbg_progress:shared = 0;

my $TEST_DELAY:shared = 0;
 	# delay remote operatios to test progress stuff
 	# set this to 1 or 2 seconds to slow things down for testing


BEGIN {
    use Exporter qw( import );
	our @EXPORT = ( qw (

		$dbg_packets
		$dbg_progress

		$DEFAULT_PORT
		$DEFAULT_HOST
		$DEFAULT_TIMEOUT
	),
	@Pub::FS::Session::EXPORT );
}

our $DEFAULT_PORT = 5872;
our $DEFAULT_HOST = "localhost";
our $DEFAULT_TIMEOUT = 15;


# Each thread has a separate SOCK from the Server
#    and getPacket cannot be re-entered by them.
# There can be upto two WX threads per SOCK in each fileClientPane.
#    One for the main process, which can be protocol, or not,
#    and one for a threadedCommand underway.
# The session ctor from the fileClientPane passes
#    in the non-zero instance number

my $instance_in_protocol:shared = shared_clone({});
	# re-entrancy protection for fileClientWindows

#------------------------------------------------
# lifecycle
#------------------------------------------------

sub new
{
	my ($class, $params, $no_error) = @_;
	$params ||= {};
	$params->{SOCK} ||= '';
	$params->{TIMEOUT} ||= $DEFAULT_TIMEOUT;
	$params->{INSTANCE} ||= 0;
	$params->{NAME} ||= 'SocketSession';

	my $this = { %$params };

	$instance_in_protocol->{$this->{INSTANCE}} = 0
		if $this->{INSTANCE};

	bless $this,$class;
	return $this;
}


#--------------------------------------------------
# packets
#--------------------------------------------------
# sendPacket() and getPacket() return errors on failures.
# Callers that are polling for non-protocol packets,
# 		may receive ''

sub sendPacket
	# returns 0 on failure, 1 on success
{
    my ($this,$packet,$override_protocol) = @_;
	if ($dbg_packets <= 0)
	{
		if (length($packet) > 100)
		{
			display($dbg_packets,-1,"$this->{NAME} --> ".length($packet)." bytes",1);
		}
		else
		{
			my $show_packet = $packet;
			$show_packet =~ s/\r/\r\n/g;
			display($dbg_packets,-1,"$this->{NAME} --> $show_packet",1);
		}
	}

	my $instance = $this->{INSTANCE};
	if ($instance && !$override_protocol)
	{
		my $in_protocol = $instance_in_protocol->{$instance};
		return error("$this->{NAME} sendPacket() while in_protocol=$in_protocol for instance=$instance",1,1)
			if $in_protocol;
	}

    my $sock = $this->{SOCK};
	return error("$this->{NAME} no socket in sendPacket",1,1)
		if !$sock;

    if (!$sock->send($packet."\r\n"))
    {
        $this->{SOCK} = undef;
        return error("$this->{NAME} could not write to socket $sock",1,1);
	}

	$sock->flush();
    return '';
}



sub getPacketInstance
{
	my ($this,$ppacket) = @_;
	my $instance = $this->{INSTANCE};
	$instance_in_protocol->{$instance}++ if $instance;
    my $err = $this->getPacket($ppacket,1);	# always is_protocol
	$instance_in_protocol->{$instance}-- if $instance;
	return $err;
}

sub incInProtocol
{
	my ($this) = @_;
	my $instance = $this->{INSTANCE};
	$instance_in_protocol->{$instance}++ if $instance;
}
sub decInProtocol
{
	my ($this) = @_;
	my $instance = $this->{INSTANCE};
	$instance_in_protocol->{$instance}-- if $instance;
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

	my $instance = $this->{INSTANCE};
	if ($instance)
	{
		my $in_protocol = $instance_in_protocol->{$instance};
		return '' if !$is_protocol && $in_protocol;
		return error("$this->{NAME} getPacket(1) while in_protocol=$in_protocol for instance=$instance",1,1)
			if $is_protocol && $in_protocol > 1;
	}

	# if !protocol, return immediately
	# if protcol, watch for timeouts

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

	$$ppacket =~ s/(\r|\n)$//g;
	if (!$$ppacket)
	{
		$this->{SOCK} = undef;
		return error("$this->{NAME} empty response from peer",1,1);
	}

	if ($dbg_packets <= 0)
	{
		if (length($$ppacket) > 100)
		{
			display($dbg_packets,-1,"$this->{NAME} <-- ".length($$ppacket)." bytes",1);
		}
		else
		{
			my $show_packet = $$ppacket;
			$show_packet =~ s/\r/\r\n/g;
			display($dbg_packets,-1,"$this->{NAME} <-- $show_packet",1);
		}
	}	# debugging only

	return '';

}	# getPacket()





1;
