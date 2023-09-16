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
# Be sure to pass 1 into get_packet(1) when
# doing the protocol or else you might get
# a null result if caller set NOBLOCK=1


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



sub _listRemoteDir
	# Be sure to pass 1 into get_packet(1) when
	# doing the protocol or else you might get
	# a null result if caller set NOBLOCK=1
{
    my ($this, $dir) = @_;
    display($dbg_commands,0,"_listRemoteDir($dir)");

    my $command = "$SESSION_COMMAND_LIST\t$dir";

    return if !$this->send_packet($command);
    my $text = $this->get_packet(1);
    return if (!$text);

    my $rslt = $this->textToList($text);
	display_hash($dbg_commands+1,1,"_getRemoteDir($rslt->{entry}) returning",$rslt->{entries})
		if $rslt;
    return $rslt;
}


sub _mkRemoteDir
{
    my ($this, $dir,$subdir) = @_;
    display($dbg_commands,0,"_mkRemoteDir($dir,$subdir)");

    my $command = "$SESSION_COMMAND_MKDIR\t$dir\t$subdir";

    return if !$this->send_packet($command);
    my $text = $this->get_packet(1);
    return if (!$text);

    my $rslt = $this->textToList($text);
	display_hash($dbg_commands+1,1,"_getRemoteDir($rslt->{entry} returning",$rslt->{entries})
		if $rslt;
    return $rslt;
}


sub _renameRemote
{
    my ($this,$dir,$name1,$name2) = @_;
    display($dbg_commands,0,"_renameRemote($dir,$name1,$name2)");

    my $command = "$SESSION_COMMAND_RENAME\t$dir\t$name1\t$name2";

    return if !$this->send_packet($command);
    my $text = $this->get_packet(1);
    return if (!$text);

    my $rslt = $this->textToList($text);
	display_hash($dbg_commands+1,1,"_getRemoteDir($rslt->{entry} returning",$rslt->{entries})
		if $rslt;
    return $rslt;
}



1;
