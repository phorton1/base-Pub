#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::SessionClient
#-------------------------------------------------------
# A SessionClient handles purely local requests
#    by passing them to the base class.
#
# For pure remote requests, it passes them to the
#    remote server via socket, and parses the
#    returned reply into objects which it returns
#    to the client.
#
# Be sure to pass 1 into getPacket(1) when doing the protocol


package Pub::FS::SessionClient;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::FS::FileInfo;
use Pub::FS::Session;
use base qw(Pub::FS::Session);


BEGIN {
    use Exporter qw( import );
	our @EXPORT = (
		qw (),
	    # forward base class exports
        @Pub::FS::Session::EXPORT,
	);
};




sub new
{
	my ($class, $params) = @_;
	$params ||= {};
	my $this = $class->SUPER::new($params);
	return if !$this;
	bless $this,$class;
	return $this;
}





1;
