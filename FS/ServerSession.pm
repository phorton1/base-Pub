#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::ServerSession
#-------------------------------------------------------
# A Server Session is an instance of a SocketSession
# which does the commands locally, but sends packet
# replies back to the client via the socket.

package Pub::FS::ServerSession;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::FS::FileInfo;
use Time::HiRes qw( sleep  );
use Pub::Utils;
use Pub::FS::FileInfo;
use Pub::FS::SocketSession;
use base qw(Pub::FS::SocketSession);


my $TEST_DELAY = 0;
 	# delay local operatios to test progress stuff
 	# set this to 1 or 2 seconds to slow things down for testing


BEGIN {
    use Exporter qw( import );
	our @EXPORT = ( qw (
	),
	@Pub::FS::SocketSession::EXPORT );
}



#------------------------------------------------
# lifecycle
#------------------------------------------------

sub new
{
	my ($class, $params, $no_error) = @_;
	$params ||= {};
	$params->{NAME} ||= 'ServerSession';
	$params->{RETURN_ERRORS} ||= 1;
    my $this = $class->SUPER::new($params);
	$this->{aborted} = 0;
	return if !$this;
	bless $this,$class;
	return $this;
}


#------------------------------------------------------
# doCommand
#------------------------------------------------------
# Calls base class and converts result to a packet
# which is sends back to the client

sub doCommand
{
    my ($this,
		$command,
        $param1,
        $param2,
        $param3,
		$progress,					# the Server is a progress thing
		$caller,					# unused on server
		$other_session) = @_;		# unused on server

	my $show3 = $command eq $PROTOCOL_BASE64 ?
		length($param3)." encoded bytes" : $param3;
	display($dbg_commands+1,0,"$this->{NAME} doCommand($command,$param1,$param2,$show3) called");
	my $rslt = $this->SUPER::doCommand($command,$param1,$param2,$param3,$progress,'','');
	display($dbg_commands+1,0,"$this->{NAME} doCommand($command) returning $rslt");

	my $packet = $rslt;
	if (isValidInfo($rslt))
	{
		if ($rslt->{is_dir} && keys %{$rslt->{entries}})
		{
			$packet = dirInfoToText($rslt)
		}
		else
		{
			$packet = $rslt->toText();
		}
	}

	display($dbg_commands+1,0,"$this->{NAME} doCommand($command) sending packet=$rslt");
	$this->sendPacket($packet);
	return '';
}


1;
