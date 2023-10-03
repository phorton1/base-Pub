#!/usr/bin/perl
#-------------------------------------------------------
# Pub::FC::ThreadedSession
#-------------------------------------------------------
# A ThreadedSession wraps a WX::Perl Thread around a ClientSession.
# It is both WX aware, and intimitaly knowledgeable about FC::Pane.
#
# It actually wraps the thread around ClientSession::doCommand()
# into the method onCommandThreaded().
#
# onCommandThreaded() and assoicated progress-like methods) cannot
# access the UI directly. They update the UI by to posting events to
# the onThreadedEvent method.


package Pub::FC::Pane;	# continued
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils;
use Pub::FS::FileInfo;
use Pub::FS::Session;		# for $PROTOCOL_XXX
use Pub::FC::Pane;			# for $THREAD_EVENT

my $dbg_thread = -0;
	# 0 = basics
	# -1 = onThreadEvent calls
	# -2 = onThreadEvent details
my $dbg_idle = 0;


my $USE_FORKING = 0;
	# Forking and threading now both work 'oK' with CONSOLE output,
	# no thread warnings, etc, after I commented line out of
	# Win32::Console.pm
my $fork_num = 0;


#------------------------------------------------------
# doCommand
#------------------------------------------------------

sub doCommand
{
    my ($this,
		$caller,
		$command,
        $param1,
        $param2,
        $param3 ) = @_;

	$param1 ||= '';
	$param2 ||= '';
	$param3 ||= '';

	display($dbg_thread,0,show_params("Pane$this->{pane_num} doCommand $caller",$command,$param1,$param2,$param3));

	# Even in local regular commands, $session->{progress} is set

	my $session = $this->{session};
	$session->{progress} = $this->{progress};

	# Cases of direct calls to local Session::doCommand()
	# return a blank or a valid file info

	if (!$this->{port} && $command ne $PROTOCOL_PUT)
	{
		my $rslt = $session->doCommand($command,$param1,$param2,$param3);
		$rslt = '' if !isValidInfo($rslt);
		return $rslt;
	}

	# PUT requires {other_session}, noting that {other_pane} is not
	# set by the Window until aftor the Pane ctor() completes, so we
	# check other_pane before assuming we can get to the other session.
	# Threaded commands require the {caller} in order to finish the
	# operation via onThreadEvent(), and everybody points to $this
	# as the progress member.

	my $other = $this->{other_pane};
	my $other_session = $other ? $other->{session} : '';

	$session->{caller} = $caller || '';
	$session->{other_session} = $other_session;
	$session->{progress} = $this;
	$other_session->{progress} = $this if $other_session;

	# We prevent the UI from doing anything by setting {thread}

	$this->{thread} = 1;

	# Forking and threads seem to work similarly.
	# Each eats a little memory and the CONSOLE works.

	if ($USE_FORKING)
	{
		my $SAVE_CONSOLE = $USE_CONSOLE;

		$fork_num++;
        my $child_pid = fork();
		if (!defined($child_pid))
		{
			error("FS_FORK($fork_num) FAILED!");
			return $caller eq 'setContents' ? -1 : '';
		}

		if (!$child_pid)	# child fork
		{
			display($dbg_thread,0,"THREADED_FORK_START($fork_num) pid=$$");

			$this->doCommandThreaded(
				$command,
				$param1,
				$param2,
				$param3);

			display($dbg_thread,0,"THREADED_FORK_END($fork_num) pid=$$");

			exit();
		}
	}
	else
	{
		# @_ = ();
			# said to be necessary to avoid "Scalars leaked"
			# but doesn't make any difference

		my $thread = threads->create(\&doCommandThreaded,
			$this,
			$command,
			$param1,
			$param2,
			$param3);

		#-----------------------------------------
		# detach() used to be a huge problem
		#-----------------------------------------
		# once I commented the line out of Win32::Console.pm
		# the problem seems to have gone away

		$thread->detach();
	}

	# A return of -2 indicates that a threaded command is in progress.

	display($dbg_thread,0,"Pane$this->{pane_num} doCommand($command) returning -2");
	return -2;

}



#------------------------------------------------------
# doCommandThreaded() cannot access the UI directly!
#------------------------------------------------------
# So it sends a THREAD_EVENT when the command finishes.

sub doCommandThreaded
{
    my ($this,
		$command,
        $param1,
        $param2,
        $param3) = @_;

	my $session = $this->{session};
	warning($dbg_thread,0,show_params("Pane$this->{pane_num} doCommandThreaded",$command,$param1,$param2,$param3)." caller=$session->{caller}");

	my $rslt = $this->{session}->doCommand(
		$command,
		$param1,
		$param2,
		$param3 );

	# back from the command, make sure to not leave any dangling pointers to progress

	warning($dbg_thread,0,"Pane$this->{pane_num} doCommandThreaded($command) got rslt=$rslt");

	# promote any non ref results to a shared hash, as final
	# resules typically require the $command and $caller

	$rslt = shared_clone({ rslt => $rslt || ''})
		if !$rslt || !ref($rslt);
	$rslt->{command} = $command;
	$rslt->{caller} = $session->{caller};

	# post the event and we're done

	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );

	display($dbg_thread,0,"Pane$this->{pane_num} doCommandThreaded($command)) finished");
}


#-------------------------------------------------------------
# progress-like method that dispatch to onThreadEvent()
#-------------------------------------------------------------

sub aborted
{
	return 0;
}

sub addDirsAndFiles
{
	my ($this,$num_dirs,$num_files) = @_;
	display($dbg_thread,-1,"Pane$this->{pane_num}::addDirsAndFiles($num_dirs,$num_files)");
	my $rslt:shared = "$PROTOCOL_PROGRESS\tADD\t$num_dirs\t$num_files";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
	return 1;	# !$this->{aborted};
}
sub setDone
{
	my ($this,$is_dir) = @_;
	display($dbg_thread,-1,"Pane$this->{pane_num}::setDone($is_dir)");
	my $rslt:shared = "$PROTOCOL_PROGRESS\tDONE\t$is_dir";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
	return 1;	# !$this->{aborted};
}
sub setEntry
{
	my ($this,$entry,$size) = @_;
	$size ||= 0;
	display($dbg_thread,-1,"Pane$this->{pane_num}::setEntry($entry,$size)");
	my $rslt:shared = "$PROTOCOL_PROGRESS\tENTRY\t$entry\t$size";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
	return 1;	# !$this->{aborted};
}
sub setBytes
{
	my ($this,$bytes) = @_;
	display($dbg_thread,-1,"Pane$this->{pane_num}::setBytes($bytes)");
	my $rslt:shared = "$PROTOCOL_PROGRESS\tBYTES\t$bytes";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
	return 1;	# !$this->{aborted};
}


#---------------------------------------------------------------
# onThradEvent() accesses the Pane WX::UI
#---------------------------------------------------------------

sub onThreadEvent
{
	my ($this, $event ) = @_;
	if (!$event)
	{
		error("No event in onThreadEvent!!",0);
		return;
	}

	my $rslt = $event->GetData();
	display($dbg_thread+1,1,"Pane$this->{pane_num} onThreadEvent() called");

	if (ref($rslt))
	{
		my $caller = $rslt->{caller};
		my $command = $rslt->{command};
		display($dbg_thread,1,"Pane$this->{pane_num} onThreadEvent finiishing caller($caller) command(($command) rslt=$rslt",
			0,$display_color_light_magenta);

		# we clear the {thread} early so that Window::populate() will work
		# in the below calls. We are running in the main thread, so everything
		# should be synchronous

		$this->{aborted} = 0;
		delete $this->{thread};

		# if not a FileInfo, demote created hashes back to outer $rslt

		my $is_info = isValidInfo($rslt);
		if (!$is_info)
		{
			$rslt = $rslt->{rslt} || '';
			display($dbg_thread+2,2,"Pane$this->{pane_num} inner rslt=$rslt");
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
			$this->{other_pane}->setContents();
			$this->{parent}->populate();
		}

		# or this one, except if there's no result and
		# the caller was setContents()

		elsif ($rslt || $caller ne 'setContents')
		{
			$this->setContents($rslt);
			$this->{parent}->populate();
		}

		# really done

		display($dbg_thread,1,"Pane$this->{pane_num} onThreadEvent done caller($caller) command(($command) rslt=$rslt",
			0,$display_color_light_magenta);
	}

	# the only pure text $rslts are PROGRESS message

	elsif ($rslt =~ /^$PROTOCOL_PROGRESS/)
	{
		if ($this->{progress})
		{
			my @params = split(/\t/,$rslt);
			shift @params;	# ditch the 'PROGRESS'
			my $command = shift(@params);

			$params[0] = '' if !defined($params[0]);
			$params[1] = '' if !defined($params[1]);
			display($dbg_thread,-4,"Pane$this->{pane_num} onThreadEvent(PROGRESS,$command,$params[0],$params[1])");

			$this->{progress}->addDirsAndFiles($params[0],$params[1])
				if $command eq 'ADD';
			$this->{progress}->setDone($params[0])
				if $command eq 'DONE';
			$this->{progress}->setEntry($params[0],$params[1])
				if $command eq 'ENTRY';
			$this->{progress}->setBytes($params[0])
				if $command eq 'BYTES';

			Wx::App::GetInstance()->Yield();
		}
	}
	else
	{
		error("unknown rslt=$rslt in onThreadEvent()");
	}

	display($dbg_thread+1,1,"Pane$this->{pane_num} onThreadEvent() returning");

}	# onThreadEvent()



#---------------------------------------------------------------
# onIdle
#---------------------------------------------------------------

sub onIdle
{
    my ($this,$event) = @_;

	if ($this->{port} &&	# these two should be synonymous
		$this->{session})
	{
		my $session = $this->{session};

		my $do_exit = 0;
		if ($session->{SOCK})
		{
			my $packet;
			my $err = $session->getPacket(\$packet);
			error($err) if $err;
			if ($packet && !$err)
			{
				display($dbg_idle,-1,"Pane$this->{pane_num} got packet $packet");
				if ($packet eq $PROTOCOL_EXIT)
				{
					display($dbg_idle,-1,"Pane$this->{pane_num} onIdle() EXIT");
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
			display($dbg_idle,-1,"Pane$this->{pane_num} lost SOCKET");
			$do_exit = 1;
		}

		if ($do_exit)
		{
			warning(0,0,"Pane$this->{pane_num} closing parent Window");
			$this->{parent}->closeSelf();
			return;
		}

		# check if we need to send an ABORT

		if ($this->{progress} &&	# should be synonymous
			$this->{thread} &&
			$session->{SOCK})
		{
			my $aborted = $this->{progress}->aborted();
			if ($aborted && !$this->{aborted})
			{
				warning($dbg_idle,-1,"Pane$this->{pane_num} sending PROTOCOL_ABORT");
				$this->{aborted} = 1;
				$session->sendPacket($PROTOCOL_ABORT,1);
					# no error checking on result
					# 1 == $override_protocol to allow sending
					# another packet while INSTANCE->{in_protocol}
			}
		}

		$event->RequestMore(1);
	}
}




1;
