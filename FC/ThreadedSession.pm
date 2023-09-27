#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FC::ThreadedSession
#-------------------------------------------------------
# A ThreadedSession wraps a WX::Perl Thread around a ClientSession.
# It is both WX aware, and intimitaly knowledgeable about FC::Pane.
#
# It actually wraps the thread around ClientSession::doCommand().
#
# ThreadedSession::doCommand() usds the $caller parameter,
# which is ignored by the standard Session used by local Panes.
#
# When the ThreadedSession is constsructed, keeps a pointer to the Pane.
# to point to the onThreadedEvent method. This allows the thread to
# communnicate back to the (Pane) UI using WX events.

package Pub::FC::ThreadedSession;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use IO::Socket::INET;
use Pub::Utils;
use Pub::FS::FileInfo;
use Pub::FS::ClientSession;
use base qw(Pub::FS::ClientSession);

our $dbg_thread = 0;
our $dbg_idle = 0;

our $THREAD_EVENT:shared = Wx::NewEventType;


BEGIN {
    use Exporter qw( import );
	our @EXPORT = (
		qw (
			$dbg_thread
			$dbg_idle

			$THREAD_EVENT
		),
	    # forward base class exports
        @Pub::FS::ClientSession::EXPORT,
	);
};




sub new
	# requires $params->{pane}
{
	my ($class, $params) = @_;
	$params ||= {};
	$params->{NAME} ||= "ThreadedSession";
	my $this = $class->SUPER::new($params);
	return if !$this;
	bless $this,$class;
	return $this;
}


#------------------------------------------------------
# doCommand
#------------------------------------------------------


sub doCommand
{
    my ($this,
		$command,
        $param1,
        $param2,
        $param3,
		$progress,		# ignored
		$caller,
		$other_session ) = @_;

	$other_session ||= '';

	my $show3 = $command eq $PROTOCOL_BASE64 ?
		length($param3)." encoded bytes" : $param3;
	display($dbg_thread,0,"$this->{NAME} doCommand($command,$param1,$param2,$show3,$caller");

	# Without detaching or joining, each command eats 26M+ of memory
	# and gives Perl exited with XXX threads, but I get to see the
	# debugging output.

	# Detaching loses STDOUT.
	# Various efforts to keep STDOUT/STDERR working
	# 	 local *STDOUT;
	# 	 local *STDERR;
	# 	 my $SAVE_STDOUT = *STDOUT;
	# 	 my $SAVE_STDERR = *STDERR;
	# 	 open(STDERR,">&MY_ERR") if !$first;
	# 	 open(MY_OUT,">&STDERR");
	# 	 open(STDERR, ">&STDOUT");
	# 	 open(STDERR, ">>/junk/xyz2.txt") || die "PRH Error stderr: $!";
	# 	 open(STDOUT, ">>/junk/xyz.txt") || die "PRH Error stderr: $!";

	# @_ = ();
		# said to be necessary to avoid "Scalars leaked"
		# but doesn't make any difference

	my $thread = threads->create(\&doCommandThreaded,
		$this,
		$command,
		$param1,
		$param2,
		$param3,
		$progress,
		$caller,
		$other_session);
	$this->{pane}->{thread} = 1; # $thread;
		# to prevent commands while in threaded command

	# *STDOUT = $SAVE_STDOUT;
	# *STDERR = $SAVE_STDERR;
	# close(STDOUT);
	# open(STDERR, ">&MY_OUT");
	# open(MY_ERR, ">&STD_ERR");

	# no warnings 'threads';
		# Set in in FC::Window::onClose()
		# to prevent showing Perl exited with XXX threads message

	###### THE ISSUE #######

	# $thread->detach();

	########################
	#
	# if (0)
	# {
	# 	my $thread_count = threads->list();
	# 	my $running = threads->list(threads::running);
	# 	my $joinable = threads->list(threads::joinable);
	# 	display(0,-1,"threads=$thread_count running=$running joinable=$joinable");
	# }

	display($dbg_thread,0,"$this->{NAME} doCommand($command) returning -2");
	return -2;		# PRH -2 indicates threaded command in progress

}


sub doCommandThreaded
{
	local *STDOUT;
	local *STDERR;

    my ($this,
		$command,
        $param1,
        $param2,
        $param3,
		$progress,
		$caller,
		$other_session) = @_;

	my $show3 = $command eq $PROTOCOL_BASE64 ?
		length($param3)." encoded bytes" : $param3;
	warning($dbg_thread,0,"$this->{NAME} doCommandThreaded($command,$param1,$param2,$show3,$caller)");
		#.ref($progress).",$caller,".ref($other_session).") called");

	my $rslt = $this->SUPER::doCommand(
		$command,
		$param1,
		$param2,
		$param3,
		$this,		# progress replaced with a pointer to $this
		$caller,
		$other_session );

	warning($dbg_thread,0,"$this->{NAME} doCommandThreaded($command) got rslt=$rslt");

	# promote everything non-progress to a shared hash
	# with a caller and pass it to onThreadEvent

	$rslt = shared_clone({
		rslt => $rslt || ''
	}) if !$rslt || !ref($rslt);

	$rslt->{caller} = $caller;
	$rslt->{command} = $command;
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this->{pane}, $evt );

	display($dbg_thread,0,"$this->{NAME} doCommandThreaded($command)) finished");

	# try different ways of killing the thread
	# threads->detach();	# same as detaching anywhere else
	# threads->exit();	# the thread already goes to non-running
}



sub aborted
{
	return 0;
}

sub addDirsAndFiles
{
	my ($this,$num_dirs,$num_files) = @_;
	display($dbg_thread,-1,"$this->{NAME}::addDirsAndFiles($num_dirs,$num_files)");
	my $rslt:shared = "$PROTOCOL_PROGRESS\tADD\t$num_dirs\t$num_files";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this->{pane}, $evt );
	return 1;	# !$this->{aborted};
}
sub setDone
{
	my ($this,$is_dir) = @_;
	display($dbg_thread,-1,"$this->{NAME}::setDone($is_dir)");
	my $rslt:shared = "$PROTOCOL_PROGRESS\tDONE\t$is_dir";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this->{pane}, $evt );
	return 1;	# !$this->{aborted};
}
sub setEntry
{
	my ($this,$entry) = @_;
	display($dbg_thread,-1,"$this->{NAME}::setEntry($entry)");
	my $rslt:shared = "$PROTOCOL_PROGRESS\tENTRY\t$entry";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this->{pane}, $evt );
	return 1;	# !$this->{aborted};
}





#---------------------------------------------------------------
# These methods access the Pane WX::UI
#---------------------------------------------------------------

package Pub::FC::Pane;	# continued
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils;
use Pub::FS::ClientSession;	# for $PROTOCOL_XXX


sub onThreadEvent
{
	my ($this, $event ) = @_;
	if (!$event)
	{
		error("No event in onThreadEvent!!",0);
		return;
	}

	my $rslt = $event->GetData();

	if (ref($rslt))
	{
		my $caller = $rslt->{caller};
		my $command = $rslt->{command};
		display($dbg_thread,1,"onThreadEvent caller($caller) command(($command) rslt=$rslt");

		# if not a FileInfo demote created hashes back to outer $rslt

		my $is_info = isValidInfo($rslt);
		if (!$is_info)
		{
			$rslt = $rslt->{rslt} || '';
			display($dbg_thread,2,"inner rslt=$rslt");
		}

		# report ABORTS and ERRORS

		if ($rslt =~ s/^$PROTOCOL_ERROR//)
		{
			error($rslt);
			$rslt = '';
		}
		if ($rslt =~ /^$PROTOCOL_ABORTED/)
		{
			okDialog(undef,"$command has been Aborted by the User","$command Aborted");
			$rslt = '';
		}

		# shut the progress dialog

		$this->{progress}->Destroy() if $this->{progress};
		$this->{progress} = undef;

		#--------------------------
		# POPULATE AS NECCESARY
		#--------------------------
		# Set special -1 value for setContents to display
		# red could not get directory listing message

		$rslt = $caller eq 'setContents' ? -1 : '' if !$is_info;

		# endRename as a special case

		if ($caller eq 'doRename')
		{
			$this->endRename($rslt);
		}

		# Invariantly re-populate other pane for PUT,

		elsif ($command eq $PROTOCOL_PUT)
		{
			my $other = $this->otherPane();
			$other->setContents($rslt);
			$other->populate();
		}

		# or this one, except if there's no result and
		# the caller was setContents()

		elsif ($rslt || $caller ne 'setContents')
		{
			$this->setContents($rslt);
			$this->populate();
		}

		# done with the thread

		$this->{aborted} = 0;
		delete $this->{thread};
		return;
	}

	# the only pure text $rslt are PROGRESS message

	display($dbg_thread,1,"onThreadEvent rslt=$rslt");

	if ($rslt =~ /^$PROTOCOL_PROGRESS/)
	{
		if ($this->{progress})
		{
			my @params = split(/\t/,$rslt);
			shift @params;	# ditch the 'PROGRESS'
			my $command = shift(@params);

			$params[0] = '' if !defined($params[0]);
			$params[1] = '' if !defined($params[1]);
			display($dbg_thread,1,"onThreadEvent(PROGRESS,$command,$params[0],$params[1])");

			$this->{progress}->addDirsAndFiles($params[0],$params[1])
				if $command eq 'ADD';
			$this->{progress}->setDone($params[0])
				if $command eq 'DONE';
			$this->{progress}->setEntry($params[0])
				if $command eq 'ENTRY';

			Wx::App::GetInstance()->Yield();
		}
	}
	else
	{
		error("unknown rslt=$rslt in onThreadEvent()");
	}
}


sub onIdle
{
    my ($this,$event) = @_;

	if ($this->{port} &&	# these two should be synonymous
		$this->{session})
	{

		my $do_exit = 0;
		if ($this->{session}->{SOCK})
		{
			my $packet;
			my $err = $this->{session}->getPacket(\$packet);
			error($err) if $err;
			if ($packet && !$err)
			{
				display($dbg_idle,-1,"pane$this->{pane_num} got packet $packet");
				if ($packet eq $PROTOCOL_EXIT)
				{
					display($dbg_idle,-1,"pane$this->{pane_num} onIdle() EXIT");
					$this->{GOT_EXIT} = 1;
					$do_exit = 1;
				}
				elsif ($packet =~ /^($PROTOCOL_ENABLE|$PROTOCOL_DISABLE)(.*)$/)
				{
					my ($what,$msg) = ($1,$2);
					$msg =~ s/\s+$//;
					$this->setEnabled(
						$what eq $PROTOCOL_ENABLE ? 1 : 0,
						$msg);
				}
			}
		}
		elsif (!$this->{disconnected_by_pane})
		{
			display($dbg_idle,-1,"pane$this->{pane_num} lost SOCKET");
			$do_exit = 1;
		}

		if ($do_exit)
		{
			warning(0,0,"pane$this->{pane_num} closing parent Window");
			$this->{parent}->closeSelf();
			return;
		}

		# check if we need to send an ABORT

		if ($this->{progress} &&	# should be synonymous
			$this->{thread} &&
			$this->{session}->{SOCK})
		{
			my $aborted = $this->{progress}->aborted();
			if ($aborted && !$this->{aborted})
			{
				warning($dbg_idle,-1,"pane$this->{pane_num} sending PROTOCOL_ABORT");
				$this->{aborted} = 1;
				$this->{session}->sendPacket($PROTOCOL_ABORT,1);
					# no error checking on result
					# 1 == $override_protocol to allow sending
					# another packet while INSTANCE->{in_protocol}
			}
		}

		$event->RequestMore(1);
	}
}




1;
