#-------------------------------------------------
# Pub::FS::RemoteServer
#--------------------------------------------------
# The RemoteServer "file server" is compatible with the existing
# TE fileSystem.cpp and teensyPiLooper programs, that is
# to say that it uses the same basic line oriented text
# protocol for communicating over the serial port..
#
# The only thing the UI cares about are directory listings
# and success/failure/progress messages.
#
# All other 'protocol' and local file access is done on
# a thread here in the Buddy console application.


package Pub::FS::RemoteServer;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::FS::SessionRemote;
use Pub::FS::Server;
use base qw(Pub::FS::Server);


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
	$params->{IS_REMOTE} = 1;
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
	return Pub::FS::SessionRemote->new({
		SOCK => $sock,
		IS_SERVER => 1 });
}




1;
