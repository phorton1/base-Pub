#!/usr/bin/perl
#-------------------------------------------
# fileClientCommands
#-------------------------------------------
# The workhorse window of the application

package Pub::FS::fileClientPane;	# continued
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils;
use Pub::WX::Dialogs;
use Pub::FS::SessionClient;
use Pub::FS::fileClientDialogs;
use Pub::FS::fileProgressDialog;
use Pub::FS::fileClientPane;
use base qw(Wx::Window);

my $dbg_ops  = 0;		# commands
	# -1, -2 = more detail
my $dbg_thread = 0;		# threaded commands


#---------------------------------------------------------
# onCommand, doMakeDir, and doRename
#---------------------------------------------------------

sub onCommand
{
    my ($this,$event) = @_;
    my $id = $event->GetId();

    if ($id == $COMMAND_REFRESH)
    {
        $this->setContents();
        $this->populate();
    }
    elsif ($id == $COMMAND_DISCONNECT)
    {
        $this->disconnect();
    }
    elsif ($id == $COMMAND_RECONNECT)
    {
        $this->connect();
    }
    elsif ($id == $COMMAND_RENAME)
    {
        $this->doRename();
    }
    elsif ($id == $COMMAND_MKDIR)
    {
        $this->doMakeDir();
    }
    else
    {
        $this->doCommandSelected($id);
    }
    $event->Skip();
}


sub doMakeDir
    # responds to COMMAND_MKDIR command event
{
    my ($this) = @_;
    my $ctrl = $this->{list_ctrl};
    display($dbg_ops,1,"doMakeDir()");

    # Bring up a self-checking dialog box for accepting the new name

    my $dlg = mkdirDialog->new($this);
    my $dlg_rslt = $dlg->ShowModal();
    my $new_name = $dlg->getResults();
    $dlg->Destroy();

    # Do the command (locally or remotely)

    if ($dlg_rslt == wxID_OK)
	{
		my $rslt = $this->doCommand('doMakeDir',$SESSION_COMMAND_MKDIR,
			$this->{is_local},
			$this->{dir},
			$new_name);
		return if $rslt && $rslt eq '-2';
		$this->setContents($rslt);
		$this->populate();
	}
    return 1;
}


sub doRename
{
    my ($this) = @_;
    my $ctrl = $this->{list_ctrl};
    my $num = $ctrl->GetItemCount();

    # get the item to edit

    my $edit_item;
    for ($edit_item=1; $edit_item<$num; $edit_item++)
    {
        last if $ctrl->GetItemState($edit_item,wxLIST_STATE_SELECTED);
    }

    # start editing the item in place ...

    display($dbg_ops,1,"doRename($edit_item) starting edit ...");
    $ctrl->EditLabel($edit_item);
}


sub onBeginEditLabel
{
    my ($ctrl,$event) = @_;
    my $row = $event->GetIndex();

    display($dbg_ops,1,"onBeginEditLabel($row)");

	my $this = $ctrl->{parent};
	my $entry = $ctrl->GetItem($row,0)->GetText();
	$this->{edit_row} = $row;
	$this->{save_entry} = $entry;
	display($dbg_ops,2,"save_entry=$entry  list_index=".$ctrl->GetItemData($row));
	$event->Skip();
}


sub onEndEditLabel
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
    my $row = $event->GetIndex();
    my $entry = $event->GetLabel();
    my $is_cancelled = $event->IsEditCancelled() ? 1 : 0;
	$this->{new_edit_name} = $entry;

    # can't rename to a blank
	# could do a local check for same name existing

    if (!$entry || $entry eq '')
    {
		error("new name must be specified");
        $event->Veto();
        return;
    }

    display($dbg_ops,1,"onEndEditLabel($row) cancelled=$is_cancelled entry=$entry save=$this->{save_entry}");
    display($dbg_ops+1,2,"ctrl=$ctrl this=$this session=$this->{session}");

	return if $is_cancelled || $entry eq $this->{save_entry};

	my $info = $this->doCommand('doRename',$SESSION_COMMAND_RENAME,
		$this->{is_local},
		$this->{dir},
		$this->{save_entry},
		$entry);

	return if $info && $info eq '-2';
		# PRH -2 indicates threaded command underway

	$this->endRename($info,$event);
}


sub endRename
{
	my ($this,$info,$event) = @_;
	my $ctrl = $this->{list_ctrl};
	$info ||= '';
	display($dbg_ops,0,"endRename($info)");

	# if the rename failed, the error was already reported
	# Here we add a pending event to start editing again ...

	if (!$info)
	{
		if ($event)
		{
			$event->Veto() ;
		}
		else
		{
			display($dbg_ops,0,"resetting itemText($this->{edit_row},0,$this->{save_entry})");
			$ctrl->SetItem($this->{edit_row},0,$this->{save_entry});
		}
		my $new_event = Wx::CommandEvent->new(
			wxEVT_COMMAND_MENU_SELECTED,
			$COMMAND_RENAME);
		$this->AddPendingEvent($new_event);
		return;
	}

	# fix up the $this->{list} and $this->{hash}
	# invalidate the sort if they are sorted by name or ext

	my $index = $ctrl->GetItemData($this->{edit_row});
	my $list = $this->{list};
	my $hash = $this->{hash};

	$info->{ext} = !$info->{is_dir} && $info->{entry} =~ /^.*\.(.+)$/ ? $1 : '';

	$list->[$index] = $info;
	delete $hash->{$this->{save_entry}};
	$hash->{$this->{new_edit_name}} = $info;
	$this->{last_sortcol} = -1 if ($this->{last_sortcol} <= 1);

	# sort does not work from within the event,
	# as wx has not finalized it's edit
	# so we chain another event to repopulate

	my $new_event = Wx::CommandEvent->new(
		wxEVT_COMMAND_MENU_SELECTED,
		$COMMAND_REPOPULATE);
	$this->AddPendingEvent($new_event);
}


#--------------------------------------------------------------
# doCommandSelected
#--------------------------------------------------------------

sub doCommandSelected
{
    my ($this,$id) = @_;
    return if (!$this->checkConnected());

    my $num_files = 0;
    my $num_dirs = 0;
    my $ctrl = $this->{list_ctrl};
    my $num = $ctrl->GetItemCount();
    my $local = $this->{is_local};
    my $other = $local ?
        $this->{parent}->{pane2}  :
        $this->{parent}->{pane1}  ;

	my $display_command = $id == $COMMAND_XFER ?
		$local ? 'upload' : 'download' :
		'delete';

    display($dbg_ops,1,"doCommandSelected($display_command) ".$ctrl->GetSelectedItemCount()."/$num selected items");

    # build an info for the root entry (since the
	# one on the list has ...UP... or ...ROOT...),
	# and add the actual selected infos to it.

	my $dir_info = Pub::FS::FileInfo->new(
        $this->{session},
		1,					# $is_dir,
		undef,				# parent directory
        $this->{dir},		# directory or filename
        1 );				# $no_checks
	return if !$dir_info;
	my $entries = $dir_info->{entries};

	my $first_entry;
    for (my $i=1; $i<$num; $i++)
    {
        if ($ctrl->GetItemState($i,wxLIST_STATE_SELECTED))
        {
            my $index = $ctrl->GetItemData($i);
            my $info = $this->{list}->[$index];
			my $entry = $info->{entry};
			if (!$first_entry)
			{
				$first_entry = $entry;
			}
            display($dbg_ops+1,2,"selected=$info->{entry}");

			$info->{is_dir} ? $num_dirs++ : $num_files++;
			$entries->{$entry} = $info;
        }
    }

    # build a message saying what will be affected

    my $file_and_dirs = '';
    if ($num_files == 0 && $num_dirs == 1)
    {
        $file_and_dirs = "the directory '$first_entry'";
    }
    elsif ($num_dirs == 0 && $num_files == 1)
    {
        $file_and_dirs = "the file '$first_entry'";
    }
    elsif ($num_files == 0)
    {
        $file_and_dirs = "$num_dirs directories";
    }
    elsif ($num_dirs == 0)
    {
        $file_and_dirs = "$num_files files";
    }
    else
    {
        $file_and_dirs = "$num_dirs directories and $num_files files";
    }

	return if !yesNoDialog($this,
		"Are you sure you want to $display_command $file_and_dirs ??",
		CapFirst($display_command)." Confirmation");

	my $command = $id == $COMMAND_XFER ?
		$SESSION_COMMAND_XFER :
		$SESSION_COMMAND_DELETE;
	my $target_dir =

	$this->{progress} = Pub::FS::fileProgressDialog->new(
		undef,
		uc($display_command))
		if $num_dirs || $num_files>1;

	# call the command processor
	# no progress dialog at this time
	# note special case of single file

	my $param2 = !$num_dirs && $num_files == 1 ?
		$first_entry :
		$dir_info->{entries};
	my $rslt = $this->doCommand(
		'doCommandSelected',
		$command,
		$this->{is_local},
		$this->{dir},
		$param2,					# info-list or single filename
		$other->{dir},				# target dir
		$this->{progress});					# progress

	return if $rslt && $rslt eq '-2';
		# PRH -2 means threaded command underway


	$this->{progress}->Destroy() if $this->{progress};
	$this->{progress} = undef;

	# We repopulate regardless of the command result
	# For Xfer the directory returned is the one that was modified

	my $update_win = $id == $COMMAND_DELETE ?
		$this : $other;

	$update_win->setContents($rslt);
	$update_win->populate();

}   # doCommandSelected()


#--------------------------------------------------------
# doCommand
#--------------------------------------------------------
# implements threading for non-local commands

sub doCommand
{
    my ($this,
		$caller,
		$command,
        $local,
        $param1,
        $param2,
        $param3,
		$progress) = @_;

	if ($local)
	{
		return $this->{session}->doCommand(
			$command,
			$local,
			$param1,
			$param2,
			$param3,
			$progress);
	}


	@_ = ();	# necessary to avoid "Scalars leaked"
	my $thread = threads->create(\&doCommandThreaded,
		$this,
		$caller,
		$command,
        $local,
        $param1,
        $param2,
        $param3);
	$this->{parent}->{thread} = $thread;
		# to prevent commands while in threaded command

	# $thread->detach();
		# prevents messages about unjoined threads at program termination
		# but causes scalars leaked message

	return -2;		# PRH -2 indicates threaded command in progress
}


sub doCommandThreaded
{
    my ($this,
		$caller,
		$command,
        $local,
        $param1,
        $param2,
        $param3) = @_;

	warning($dbg_thread,-1,"doCommandThreaded($caller,$command,$local) called");

	my $rslt = $this->{session}->doCommand(
		$command,
		$local,
		$param1,
		$param2,
		$param3,
		$this);

	warning($dbg_thread,-1,"doCommandThreaded($caller) got rslt=$rslt");

	# scalar result can be an error message
	# and we still want to pass caller for doRename

	if ($rslt && !ref($rslt) && $caller eq 'doRename')
	{
		display($dbg_thread,-2,"setting rename_error=$rslt");
		$rslt = shared_clone({ rename_error => $rslt })
	}

	# we want to pass a bare hash, with the caller, if there was no result

	$rslt ||= shared_clone({});
	$rslt->{caller} = $caller if ref($rslt);
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
}


#--------------------------------------------------------
# onThreadEvent
#--------------------------------------------------------

sub onThreadEvent
{
	my($this, $event ) = @_;
	if (!$event)
	{
		error("No event in onThreadEvent!!",0);
		return;
	}

	my $rslt = $event->GetData();

	if (ref($rslt))
	{
		my $caller = $rslt->{caller};
		display($dbg_thread,1,"onThreadEvent caller($caller)");
		$this->{progress}->Destroy() if $this->{progress};
		$this->{progress} = undef;

		# we need to report rename errors separately here

		error($rslt->{rename_error})
			if $rslt->{rename_error} &&
			   $rslt->{rename_error} =~ s/ERROR - //;

		# success if it's a FileInfo

		my $is_ref = ref($rslt) =~ /Pub::FS::FileInfo/;

		$rslt = -1 if !$is_ref && $caller eq 'setContents';
		$rslt = '' if !$is_ref;

		if ($caller eq 'doRename')
		{
			$this->endRename($rslt);
		}
		elsif ($rslt)
		{
			$this->setContents($rslt);
			$this->populate();
		}

		delete $this->{parent}->{thread};
			# free up for more commands

		return;
	}

	# text results
	# they can theoretically currently re-enter on remote commands
	# as we don't disable the window in doCommandThreaded!

	display($dbg_thread,1,"onThreadEvent rslt=$rslt");

	if ($rslt =~ s/^ERROR - //)
	{
		error($rslt);
		delete $this->{parent}->{thread};
			# free up for more commands
		$this->{progress}->Destroy() if $this->{progress};
		$this->{progress} = undef;
	}
	elsif ($rslt =~ /^PROGRESS/)
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
}


#--------------------------------------
# $this is now a progress like thing
#--------------------------------------

sub addDirsAndFiles
{
	my ($this,$num_dirs,$num_files) = @_;
	display($dbg_thread,-1,"THIS->addDirsAndFiles($num_dirs,$num_files)");
	my $rslt:shared = "PROGRESS\tADD\t$num_dirs\t$num_files";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
	# Wx::App::GetInstance()->Yield();
}
sub setDone
{
	my ($this,$is_dir) = @_;
	display($dbg_thread,-1,"THIS->setDone($is_dir)");
	my $rslt:shared = "PROGRESS\tDONE\t$is_dir";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
	# Wx::App::GetInstance()->Yield();
}
sub setEntry
{
	my ($this,$entry) = @_;
	display($dbg_thread,-1,"THIS->setEntry($entry)");
	my $rslt:shared = "PROGRESS\tENTRY\t$entry";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
	# Wx::App::GetInstance()->Yield();
}


1;
