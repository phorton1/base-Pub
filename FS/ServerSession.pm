#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FS::ServerSession
#-------------------------------------------------------
# A Server Session is an instance of a SocketSession
# which does the commands locally, but sends packet
# replies back to the client via the socket.
#
# it needs an 'other_session' to handle commands from
# the base class for FILE and BASE64 packets that need
# to be sent back to the client.

package Pub::FS::ServerOtherSession;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::FS::FileInfo;
use Time::HiRes qw( sleep  );
use Pub::Utils;
use Pub::FS::FileInfo;
use Pub::FS::Session;

sub new
{
	my ($class,$session) = @_;
	my $this = { session => $session };
	bless $this,$class;
}


sub doCommand
{
    my ($this,
		$command,
        $param1,
        $param2,
        $param3) = @_;		# unused on server

	my $session = $this->{session};
	display($dbg_commands+1,0,show_params("ServerOtherSession::doCommand",$command,$param1,$param2,$param3));

	if ($command eq $PROTOCOL_FILE ||
		$command eq $PROTOCOL_BASE64)
	{
		my $packet = "$command\t$param1\t$param2\t$param3";
		$session->sendPacket($packet);
		my $ret_packet;
		my $err = $session->getPacket(\$ret_packet,1);
		return $err || $ret_packet;
	}
	return error("illegal command($command) for ServerOtherSession");
}


#-------------------------------------------------------
# Pub::FS::ServerSession
#-------------------------------------------------------

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
    my $this = $class->SUPER::new($params);
	$this->{other_session} = Pub::FS::ServerOtherSession->new($this);
	$this->{aborted} = 0;
	return if !$this;
	bless $this,$class;
	return $this;
}


#------------------------------------------------------
# doCommand
#------------------------------------------------------
# Calls base class and converts result to a packet
# which is sends back to the client.
#
# FILE and BASE64 are weird.  The base session wants
# to call other_session->doCommand() for these.


sub doCommand
{
    my ($this,
		$command,
        $param1,
        $param2,
        $param3) = @_;		# unused on server

	display($dbg_commands+1,0,show_params("$this->{NAME} doCommand",$command,$param1,$param2,$param3));
	my $rslt = $this->SUPER::doCommand($command,$param1,$param2,$param3);
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




# The ServerSession is $progress-like

sub aborted
{
	my ($this) = @_;
	my $packet;
	my $err = $this->getPacket(\$packet);
	return 1 if !$err && $packet && $packet =~ /^$PROTOCOL_ABORT/;
	return 0;
}


sub addDirsAndFiles
{
	my ($this,$num_dirs,$num_files) = @_;
    return 0 if $this->aborted();
	my $packet = "$PROTOCOL_PROGRESS\tADD\t$num_dirs\t$num_files";
	my $err = $this->sendPacket($packet);
	return $err ? 0 : 1;
}


sub setEntry
{
	my ($this,$entry,$size) = @_;
	$size ||= 0;
    return 0 if $this->aborted();
	my $packet = "$PROTOCOL_PROGRESS\tENTRY\t$entry\t$size";
	my $err = $this->sendPacket($packet);
	return $err ? 0 : 1;
}


sub setDone
{
	my ($this,$is_dir) = @_;
    return 0 if $this->aborted();
	my $packet = "$PROTOCOL_PROGRESS\tDONE\t$is_dir";
	my $err = $this->sendPacket($packet);
	return $err ? 0 : 1;
}



1;
