#!/usr/bin/perl
#-------------------------------------------------------
# Pub::Socket::Packet
#-------------------------------------------------------

package Pub::Socket::Packet;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw( sleep  );
use IO::Select;
use Pub::Utils;


our $dbg_pkt = 1;


BEGIN {
    use Exporter qw( import );
	our @EXPORT = qw (

		$DEFAULT_TIMEOUT

		getPacket
		sendPacket

		verifyCallback

	);
}



our $DEFAULT_TIMEOUT = 15;



#--------------------------------------------------
# packets
#--------------------------------------------------
# sendPacket() and getPacket() return errors on failures.



sub getPacket
	# fills in the passed in reference to a packet.
	# returns an error at call_level=1 or '' upon success.
	# The protocol passes in $is_protocol, which blocks and prevents other
	# callers from getting packets.  Otherwise, the method does not block.
{
    my ($sock,$ppacket,$block) = @_;

	$block ||= 0;
	$$ppacket = '';

	display($dbg_pkt,0,"getPacket($block)");

	my $can_read;
	my $started = time();
	my $select = IO::Select->new($sock);

	display($dbg_pkt+1,0,"select($select)");

	while (1)
	{
		$can_read = $select->can_read(0.1);

		display($dbg_pkt,0,"can_read="._def($can_read));

		last if $can_read;
		return '' if !$block;
		return error("getPacket timed out")
			if time() > $started + $DEFAULT_TIMEOUT;
	}

	display($dbg_pkt,0,"reading ....");

	# return '';

	# can_read is true here
	# trying different approaches for SSL

	my $CRLF = "\015\012";
	local $/ = $CRLF;
	$$ppacket = <$sock>;
	display($dbg_pkt,0,"packet="._def($$ppacket));

	if (!defined($$ppacket))
	{
		return error("no response from peer");
	}

	$$ppacket =~ s/\s+$//g;
	if (!$$ppacket)
	{
		warning(0,0,"empty response from peer",1,1);
	}

	display($dbg_pkt,0,"getPacket($block) returning no error and packet='$$ppacket'");

	return '';

}	# getPacket()






sub sendPacket
	# returns 0 on failure, 1 on success
{
    my ($sock,$packet) = @_;

	display($dbg_pkt,0,"sendPacket($packet)");

	my $full_packet = $packet."\r\n";
	my $len = length($full_packet);
	my $bytes = syswrite($sock,$full_packet);
	if ($bytes != $len)
	{
		return error("could only write($bytes/$len) bytes to socket $sock",1,1);
	}

	$sock->flush();
    return '';
}




sub verifyCallback
	# 1. a true/false value that indicates what OpenSSL thinks of the certificate,
	# 2. a C-style memory address of the certificate store,
	# 3. a string containing the certificate's issuer attributes and owner attributes, and
	# 4. a string containing any errors encountered (0 if no errors).
	# 5. a C-style memory address of the peer's own certificate (convertible to PEM form with Net::SSLeay::PEM_get_string_X509()).
	# 6. The depth of the certificate in the chain. Depth 0 is the leaf certificate.
{
	my ($open_ssl_thinks,
		$ca_store,
		$attribs,
		$errors,
		$peer_cert,
		$depth) = @_;

	display(0,0,"verifyCallback()");
	display(0,1,"open_ssl_thinks ="._def($open_ssl_thinks));
	display(0,1,"ca_store        ="._def($ca_store));
	display(0,1,"attribs         ="._def($attribs));
	display(0,1,"errors          ="._def($errors));
	display(0,1,"peer_cert       ="._def($peer_cert));
	display(0,1,"depth           ="._def($depth));

	return $open_ssl_thinks;
}



1;
