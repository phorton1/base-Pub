#!/usr/bin/perl
#-------------------------------------------
# fileClientCommands
#-------------------------------------------
# The workhorse window of the application

package Pub::FC::Pane;	# continued
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils;
use Pub::WX::Dialogs;
use Pub::FS::FileInfo;
use Pub::FS::ClientSession;
use Pub::FC::Dialogs;
use Pub::FC::ProgressDialog;
use Pub::FC::Pane;		# needed for $COMMAND_XXXX
use base qw(Wx::Window);

my $dbg_ops  = 0;		# commands
	# -1, -2 = more detail
my $dbg_thread = -2;		# threaded commands
my $dbg_idle = 0;


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
		my $rslt = $this->{session}->doCommand(
			$PROTOCOL_MKDIR,	# command
			$this->{dir},		# param1
			$new_name,			# param2
			'',					# param3
			'',					# progress
			'doMakeDir',		# caller
			'');				# other_session

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

	my $info = $this->{session}->doCommand(
		$PROTOCOL_RENAME,		# command
		$this->{dir},			# param1
		$this->{save_entry},	# param2
		$entry,					# param3
		'',						# progress
		'doMakeDir',			# caller
		'');					# other_session

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
	my $other = $this->otherPane();

	my $display_command = $id == $COMMAND_XFER ?
		'xfer' :
		'delete';

    display($dbg_ops,1,"doCommandSelected($display_command) ".$ctrl->GetSelectedItemCount()."/$num selected items");

    # build an info for the root entry (since the
	# one on the list has ...UP... or ...ROOT...),
	# and add the actual selected infos to it.

	my $dir_info = Pub::FS::FileInfo->new(
		1,					# $is_dir,
		undef,				# parent directory
        $this->{dir},		# directory or filename
        1 );				# $no_checks
	if (!isValidInfo($dir_info))
	{
		error($dir_info) if $dir_info;
		return;
	}
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
		$PROTOCOL_PUT :
		$PROTOCOL_DELETE;
	my $target_dir =

	$this->{progress} = # !$num_dirs && $num_files==1 ? '' :
		Pub::FC::ProgressDialog->new(
			undef,
			uc($display_command));

	my $param2 = !$num_dirs && $num_files == 1 ?
		$first_entry :
		$dir_info->{entries};

	my $rslt = $this->{session}->doCommand(
		$command,				# command
		$this->{dir},			# param1
		$param2,				# param2
		$other->{dir},			# param3
		$this->{progress},	  	# progress
		'doCommandSelected',	# caller
		$other->{session} );	# other_session

	# ThreadedSession::doComand() is used for all non-local Sessions.
	# It invariantly sets this->{thread} and returns -2 indicating that
	# and there is a threaded command underway.

	return if $rslt && $rslt eq '-2';

	# The base local Session will either return a valid info
	# or $PROTOCOL_ABORTED

	if ($rslt && $rslt =~ /^$PROTOCOL_ABORTED/)
	{
		okDialog(undef,"$command aborted by user","$command Aborted");
		$rslt = '';
	}

	$this->{progress}->Destroy() if $this->{progress};
	$this->{progress} = undef;

	# For any DELETE we want to repopulate this pane with
	#     $rslt which still might be a local DIR_LIST.
	# However, for PUT we only want to repopulate the
	#   OTHER pane if there IS a result, which should
	#   generally be the case for a local Session, but
	#   will be '' for a ThreadedSession

	if ($id == $COMMAND_DELETE)
	{
		$this->setContents($rslt);
		$this->populate();
	}
	elsif ($rslt)
	{
		$other->setContents($rslt);
		$other->populate();
	}

}   # doCommandSelected()



1;
