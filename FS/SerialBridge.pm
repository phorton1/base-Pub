#-------------------------------------------------
# Pub::FS::SerialBridge
#--------------------------------------------------
# The SerialBridge is a bridge between the fileClient
# and a device that implements a SerialServer orchestrated
# by buddy.
#
# The only current SerialServer is the teensyExpression,
# There is currently no Perl SerialServer.


package Pub::FS::SerialBridge;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::FS::SerialSession;
use Pub::FS::Server;
use base qw(Pub::FS::Server);

my $dbg_bridge = 1;


BEGIN {
    use Exporter qw( import );
	our @EXPORT = (
		qw (
		),
	    # forward base class exports
        @Pub::FS::Server::EXPORT,
	);
};


sub new
{
	my ($class,$params) = @_;
	$params ||= {};
	$params->{PORT} ||= 0;
	$params->{SEND_EXIT} = 1;
	my $this = $class->SUPER::new($params);
	return if !$this;
    bless $this,$class;
	return $this;
}


sub createSession
	# this method overriden in derived classes
	# to create different kinds of sessions
{
	my ($this,$sock) = @_;
	my $session = Pub::FS::SerialSession->new({
		SOCK => $sock,
		IS_SERVER => 1 });
	return $session;
}


sub processPacket
	# Returns 1 upon success and 0 upon failure.
	# 0 terminates the sessionThread and session.
	#
	# This derived class passes most packets from the Client
	# directly to the SerialServer, inasmuch as the context
	# for most commands is ITS file system.
	#
	# $packet is known to be defined and have content here.
{
	my ($this,$session,$packet) = @_;

	if ($dbg_bridge <= 0)
	{
		my $show_packet = $packet;
		$show_packet =~ s/\r/\r\n/g;
		display($dbg_bridge,0,"processPacket($show_packet)");
	}

	$session->doSerialRequest($packet);

	# currently always returns success (i.e. never terminates
	# the SerialSession). Any problems with serial communication
	# are sent to the Client over the socket via doSerialRequest().

	return 1;
}






1;
