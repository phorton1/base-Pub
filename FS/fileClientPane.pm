#!/usr/bin/perl
#-------------------------------------------
# filePane
#-------------------------------------------
# The workhorse window of the application

package Pub::FS::fileClientPane;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
    EVT_SIZE
    EVT_MENU
    EVT_MENU_RANGE
    EVT_CONTEXT_MENU
    EVT_UPDATE_UI_RANGE
    EVT_LIST_KEY_DOWN
    EVT_LIST_COL_CLICK
    EVT_LIST_ITEM_SELECTED
    EVT_LIST_ITEM_ACTIVATED
    EVT_LIST_BEGIN_LABEL_EDIT
    EVT_LIST_END_LABEL_EDIT
	EVT_COMMAND );
use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::Menu;
use Pub::WX::Dialogs;
use Pub::FS::FileInfo;
use Pub::FS::SessionClient;
use Pub::FS::fileClientResources;
use Pub::FS::fileClientDialogs;
use Pub::FS::fileProgressDialog;
use base qw(Wx::Window);


my $dbg_life = 0;		# life_cycle
my $dbg_pop  = 0;		# populate
	# -1 = addItem
	# -2 = addItem idx mapping
my $dbg_comp = 1;		# compare colors
	# -1 = entries
my $dbg_sort = 1;		# sorting
	# =1 = details
my $dbg_ops  = 0;		# commands
	# -1, -2 = more detail
my $dbg_threaded_commands = 0;


BEGIN {
    use Exporter qw( import );
	our @EXPORT = qw (
		$progress
	);
}



my $THREAD_EVENT:shared = Wx::NewEventType;


#-----------------------------------
# configuration vars
#-----------------------------------

my $PANE_TOP = 20;

my @fields = (
    entry       => 140,
    ext         => 50,
    compare     => 50,
    size        => 60,
    ts   		=> 140 );
my $num_fields = 5;
my $field_num_size = 3;

my $COMMAND_REPOPULATE = 8765;

my $title_font = Wx::Font->new(9,wxFONTFAMILY_DEFAULT,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);
my $normal_font = Wx::Font->new(8,wxFONTFAMILY_DEFAULT,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL);
my $bold_font = Wx::Font->new(8,wxFONTFAMILY_DEFAULT,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);

my $color_same    = Wx::Colour->new(0x00 ,0x00, 0xff);  # blue
my $color_missing = Wx::Colour->new(0x00 ,0x00, 0x00);  # black
my $color_older   = Wx::Colour->new(0xff, 0x00, 0xff);  # purple
my $color_newer   = Wx::Colour->new(0xff ,0x00, 0x00);  # red

my $color_red     = Wx::Colour->new(0xc0 ,0x00, 0x00);  # red
my $color_green   = Wx::Colour->new(0x00 ,0x90, 0x00);  # green
my $color_blue    = Wx::Colour->new(0x00 ,0x00, 0xc0);  # blue


sub compareType
{
	my ($comp_value) = @_;
	return '' if !$comp_value;
    return 'newer' if $comp_value == 3;
    return 'same'  if $comp_value == 2;
    return 'older' if $comp_value == 1;
	return '';	# JIC
}


#-----------------------------------
# new
#-----------------------------------

sub new
{
    my ($class,$parent,$splitter,$session,$is_local,$dir) = @_;
    my $this = $class->SUPER::new($splitter);

    $this->{parent}    = $parent;
    $this->{session}   = $session;
    $this->{is_local}  = $is_local;
    $this->{dir}       = $dir;

	$this->{connected} = 1;
	$this->{enabled}   = 1;
	$this->{got_list}  = 0;

    $this->{dir_ctrl} = Wx::StaticText->new($this,-1,'',[10,0]);
    $this->{dir_ctrl}->SetFont($title_font);

    # set up the list control

    my $ctrl = $this->{list_ctrl} = Wx::ListCtrl->new(
        $this,-1,[0,$PANE_TOP],[-1,-1],
        wxLC_REPORT | wxLC_EDIT_LABELS);
    $ctrl->{parent} = $this;

    for my $i (0..$num_fields-1)
    {
        my ($field,$width) = ($fields[$i*2],$fields[$i*2+1]);
        my $align = $i ? wxLIST_FORMAT_RIGHT : wxLIST_FORMAT_LEFT;
        $ctrl->InsertColumn($i,$field,$align,$width);
    }

    # show connection state
	# $this->setConnectMsg($color_green,'SERVER');

    # finished - layout & setContents

    $this->{sort_col} = 0;
    $this->{sort_desc} = 0;
	$this->{last_sortcol} = -1;
	$this->{last_desc} = -1;

    $this->doLayout();
    $this->setContents();

    EVT_SIZE($this,\&onSize);
    EVT_CONTEXT_MENU($ctrl,\&onContextMenu);
    EVT_MENU($this,$COMMAND_REPOPULATE,\&onRepopulate);
    EVT_MENU_RANGE($this, $COMMAND_XFER, $COMMAND_DISCONNECT, \&onCommand);
	EVT_UPDATE_UI_RANGE($this, $COMMAND_XFER, $COMMAND_DISCONNECT, \&onCommandUI);
    EVT_LIST_KEY_DOWN($ctrl,-1,\&onKeyDown);
    EVT_LIST_COL_CLICK($ctrl,-1,\&onClickColHeader);
    EVT_LIST_ITEM_SELECTED($ctrl,-1,\&onItemSelected);
    EVT_LIST_ITEM_ACTIVATED($ctrl,-1,\&onDoubleClick);
    EVT_LIST_BEGIN_LABEL_EDIT($ctrl,-1,\&onBeginEditLabel);
    EVT_LIST_END_LABEL_EDIT($ctrl,-1,\&onEndEditLabel);

	EVT_COMMAND($this, -1, $THREAD_EVENT, \&onThreadEvent );

    return $this;

}   # filePane::new()


#--------------------------------------------
# simple event handlers and layout
#--------------------------------------------

sub onSize
{
    my ($this,$event) = @_;
	$this->doLayout();
	# $this->{parent}->onSize($event);
		# to adjust the enabled_ctrl
    $event->Skip();
}


sub doLayout
{
    my ($this) = @_;
	my $sz = $this->GetSize();
    my $width = $sz->GetWidth();
    my $height = $sz->GetHeight();
    $this->{list_ctrl}->SetSize([$width,$height-$PANE_TOP]);

	my $sash_pos = $this->{parent}->{splitter}->GetSashPosition();
	$this->{parent}->{enabled_ctrl}->Move($sash_pos+10,5);
}


sub onRepopulate
{
    my ($this,$event) = @_;
    display($dbg_pop,0,"onRepopulate()");
    my $other = $this->{is_local} ?
        $this->{parent}->{pane2} :
        $this->{parent}->{pane1} ;
    $this->populate(1);
    $other->populate(1);
}


sub onKeyDown
{
    my ($ctrl,$event) = @_;
	my $this = $ctrl->{parent};
	return if $this->{parent}->{thread};

    my $key_code = $event->GetKeyCode();
    display($dbg_ops+2,0,"onKeyDown($key_code)");

    # if it's the delete key, and there's some
    # items selected, pass the command to onCommand

    if ($key_code == 127 && $ctrl->GetSelectedItemCount())
    {
        my $this = $ctrl->{parent};
        my $new_event = Wx::CommandEvent->new(
            wxEVT_COMMAND_MENU_SELECTED,
            $COMMAND_DELETE);
        $this->onCommand($new_event);
    }
    else
    {
        $event->Skip();
    }
}


sub onContextMenu
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
	return if $this->{parent}->{thread};

    display($dbg_ops,0,"filePane::onContextMenu()");
    my $cmd_data = $$resources{command_data}->{$COMMAND_XFER};
    $$cmd_data[0] = $this->{is_local} ? "Upload" : "Download";
    my $menu = Pub::WX::Menu::createMenu('win_context_menu');
	$this->PopupMenu($menu,[-1,-1]);
}


sub onCommandUI
{
    my ($this,$event) = @_;
    my $id = $event->GetId();
    my $ctrl = $this->{list_ctrl};
    my $local = $this->{is_local};
    my $connected = $this->{session}->isConnected();

    # default enable is true for local, and
    # 'is connected' for remote ...

    my $enabled = 0;

   # Connection commands enabled only in the non-local pane
   # CONNECT is always available

    if ($id == $COMMAND_RECONNECT)
    {
        $enabled = !$local;
    }

    # other connection commands

    elsif ($id == $COMMAND_DISCONNECT)
    {
        $enabled = !$local && $connected;
    }

    # refresh and mkdir is enabled for both panes

    elsif ($id == $COMMAND_REFRESH ||
           $id == $COMMAND_MKDIR)
    {
        $enabled = $local || ($this->{enabled} && $connected);
    }

    # xfer requires both sides and some stuff

    elsif ($id == $COMMAND_XFER)
    {
        $enabled = $connected && $this->{enabled} && $ctrl->GetSelectedItemCount();
    }

    # rename requires exactly one selected item

    elsif ($id == $COMMAND_RENAME)
    {
        $enabled = ($local || ($this->{enabled} && $connected)) &&
            $ctrl->GetSelectedItemCount() == 1;
    }

	# delete requires some selected items

    elsif ($id == $COMMAND_DELETE)
    {
        $enabled = ($local || ($this->{enabled} && $connected)) &&
            $ctrl->GetSelectedItemCount();
    }

	$enabled = 0 if $this->{parent}->{thread};
    $event->Enable($enabled);
}




#----------------------------------------------
# connection utilities
#----------------------------------------------

sub setEnabled
{
	my ($this,$enable,$msg) = @_;
	return if $this->{is_local};
	if ($this->{enabled} != $enable)
	{
		$this->Enable($enable);
		$this->{enabled} = $enable;
		$this->{parent}->{enabled_ctrl}->SetLabel($enable ? '' : $msg);
		$this->{parent}->{enabled_ctrl}->SetForegroundColour(
			$enable ? $color_green : $color_blue);

		# this snippet repopulates if it has never been done successfully

		if ($enable && !$this->{got_list})
		{
			$this->setContents();
			$this->populate();
		}
	}
}


sub setConnectMsg
{
    my ($this,$color,$msg) = @_;
	return if $this->{is_local};
    $this->{parent}->{connected_ctrl}->SetLabel($msg);
	$this->{parent}->{connected_ctrl}->SetForegroundColour($color);
}


sub checkConnected
{
    my ($this) = @_;
    return 1 if $this->{is_local};
	my $connected = $this->{session}->isConnected();
	if ($this->{connected} != $connected)
	{
		$this->{connected} = $connected;
		if ($connected)
		{
			display($dbg_life,-1,"Connected");
			$this->setEnabled(1,'');
		}
		else
		{
			error("Not connected!");
			$this->setEnabled(0,'NO CONNECTION');
		}
	}
    return $connected;
}


sub disconnect
{
    my ($this) = @_;
	return if $this->{is_local};
    return if (!$this->checkConnected());
    display($dbg_life,0,"Disconnecting...");
    $this->{session}->disconnect();
	$this->checkConnected();
	# $this->populate();
}


sub connect
{
    my ($this) = @_;
	return if $this->{is_local};
    $this->disconnect() if ($this->{session}->isConnected());
    # $this->setConnectMsg($color_green,'CONNECTING ...');
    display($dbg_life,0,"Connecting...");
    my $connected = $this->{session}->connect();
	if ($this->checkConnected())
    {
		$this->setContents();
		$this->populate();
	}
}



#-----------------------------------------------
# Sorting
#-----------------------------------------------

sub onClickColHeader
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
    return if (!$this->checkConnected());
	return if $this->{parent}->{thread};

    my $col = $event->GetColumn();
    my $prev_col = $this->{sort_col};
    display($dbg_ops+1,0,"onClickColHeader($col) prev_col=$prev_col desc=$this->{sort_desc}");

    # set the new sort specification

    if ($col == $this->{sort_col})
    {
        $this->{sort_desc} = $this->{sort_desc} ? 0 : 1;
    }
    else
    {
        $this->{sort_col} = $col;
        $this->{sort_desc} = 0;
    }

    # sort it

    $this->sortListCtrl();

    # remove old indicator

    if ($prev_col != $col)
    {
        my $item = $ctrl->GetColumn($prev_col);
        $item->SetMask(wxLIST_MASK_TEXT);
        $item->SetText($fields[$prev_col*2]);
        $ctrl->SetColumn($prev_col,$item);
    }

    # set new indicator

    my $sort_char = $this->{sort_desc} ? 'v ' : '^ ';
    my $item = $ctrl->GetColumn($col);
    $item->SetMask(wxLIST_MASK_TEXT);
    $item->SetText($sort_char.$fields[$col*2]);
    $ctrl->SetColumn($col,$item);

}   # onClickColHeader()



sub comp	# for sort, not for conmpare
{
    my ($this,$sort_col,$desc,$index_a,$index_b) = @_;
	my $ctrl = $this->{list_ctrl};
	# my $entry_a = $ctrl->GetItemText($index_a);
	# my $entry_b = $ctrl->GetItemText($index_b);
	my $info_a = $this->{list}->[$index_a];
	my $info_b = $this->{list}->[$index_b];

    display($dbg_sort+1,0,"comp $index_a=$info_a->{entry} $index_b=$info_b->{entry}");

    # The ...UP... or ...ROOT... entry is always first

    my $retval;
    if (!$index_a)
    {
        return -1;
    }
    elsif (!$index_b)
    {
        return 1;
    }

    # directories are always at the top of the list

    elsif ($info_a->{is_dir} && !$info_b->{is_dir})
    {
        $retval = -1;
        display($dbg_sort+1,1,"comp_dir($info_a->{entry},$info_b->{entry}) returning -1");
    }
    elsif ($info_b->{is_dir} && !$info_a->{is_dir})
    {
        $retval = 1;
        display($dbg_sort+1,1,"comp_dir($info_a->{entry},$info_b->{entry}) returning 1");
    }

    elsif ($info_a->{is_dir} && $sort_col>0 && $sort_col<$num_fields)
    {
		# we sort directories ascending except on the entry field
		$retval = (lc($info_a->{entry}) cmp lc($info_b->{entry}));
        display($dbg_sort+1,1,"comp_same_dir($info_a->{entry},$info_b->{entry}) returning $retval");
    }
    else
    {
        my $field = $fields[$sort_col*2];
        my $val_a = $info_a->{$field};
        my $val_b = $info_b->{$field};
        $val_a = '' if !defined($val_a);
        $val_b = '' if !defined($val_b);
        my $val_1 = $desc ? $val_b : $val_a;
        my $val_2 = $desc ? $val_a : $val_b;

        if ($sort_col == $field_num_size)     # size uses numeric compare
        {
            $retval = ($val_1 <=> $val_2);
        }
        else
        {
            $retval = (lc($val_1) cmp lc($val_2));
        }

		# i'm not seeing any ext's here

        display($dbg_sort+1,1,"comp($field,$sort_col,$desc,$val_a,$val_b) returning $retval");
    }
    return $retval;

}   # comp() - compare two infos for sorting



sub sortListCtrl
{
    my ($this) = @_;
    my $hash = $this->{list};
    my $ctrl = $this->{list_ctrl};
    my $sort_col = $this->{sort_col};
    my $sort_desc = $this->{sort_desc};

    display($dbg_sort,0,"sortListCtrl($sort_col,$sort_desc) local=$this->{is_local}");

    if ($sort_col == $this->{last_sortcol} &&
        $sort_desc == $this->{last_desc} &&
        !$this->{changed})
    {
        display($dbg_sort,1,"short ending last=$this->{last_desc}:$this->{last_sortcol}");
        return;
    }

	# $a and $b are the indexes into $this->{list]
	# that we set via SetUserData() in the initial setListRow()

    $ctrl->SortItems(sub {
        my ($a,$b) = @_;
		return comp($this,$sort_col,$sort_desc,$a,$b); });

	# now that they are sorted, {list} no longer matches the contents by row

    $this->{last_sortcol} = $sort_col;
    $this->{last_desc} = $sort_desc;

}



#--------------------------------------------------------
# compareLists and addListRow
#--------------------------------------------------------

sub getDbgPaneName
{
	my ($this) = @_;
	my $name = $this->{is_local} ? "LOCAL" : $this->{parent}->{name};
	$name .= " $this->{dir}";
	return $name;

}

sub compareLists
{
    my ($this) = @_;

    my $hash = $this->{hash};
    my $other = $this->{is_local} ?
        $this->{parent}->{pane2} :
        $this->{parent}->{pane1} ;
    my $other_hash = $other->{hash};

    display($dbg_comp,0,"compareLists(".
			$this->getDbgPaneName().
			") other=(".
			$other->getDbgPaneName().
			")");

    for my $entry (keys(%$hash))
    {
        my $info = $$hash{$entry};

        display($dbg_comp+1,1,"checking $entry=$info");

        my $other_info = $$other_hash{$entry};

        $info->{compare} = '';

        if ($other_info && $entry !~ /^...(UP|ROOT).../)
        {
            if (!$info->{is_dir} && !$other_info->{is_dir})
            {
                if ($info->{ts} gt $other_info->{ts})
                {
                    $info->{compare} = 3;   # newer
                }
                elsif ($info->{ts} lt $other_info->{ts})
                {
                    $info->{compare} = 1;   # older
                }
                elsif ($info->{ts})
                {
                    $info->{compare} = 2;   # same
                }
            }
            elsif ($info->{is_dir} && $other_info->{is_dir})
            {
                $info->{compare} = 2;
            }
        }

		display($dbg_comp,1,"comp $entry = ".compareType($info->{compare}));
    }

    display($dbg_comp+1,1,"compareLists() returning");

    return $other;

}   # compareLists()



sub setListRow
    # Create a new, or modify an existing list_ctrl row
{
    my ($this,$row,$entry) = @_;
    my $ctrl = $this->{list_ctrl};
	my $is_new = $entry ? 1 : 0;
	$entry ||= $ctrl->GetItemText($row);
	my $info = $this->{hash}->{$entry};

    my $is_dir = $info->{is_dir} || '';
    my $compare_type = compareType($info->{compare});

    display($dbg_pop+1,0,"setListRow($is_new) row($row) isdir($is_dir) comp($compare_type) entry=$entry)");

	# prep

    my $font = $is_dir ? $bold_font : $normal_font;
	my $ext = !$is_dir && $entry =~ /^.*\.(.+)$/ ? $1 : '';
    my $color =
        $compare_type eq 'newer' ? $color_newer :
        $compare_type eq 'same'  ? $color_same :
        $compare_type eq 'older' ? $color_older :
        $color_missing;

    # create the row if needed

    if ($is_new)
    {
        $ctrl->InsertStringItem($row,$entry);
		$ctrl->SetItemData($row,$row);
			# the index into $this->{list} is persistent
			# and passed back in sort
		$ctrl->SetItem($row,3,($is_dir?'':$info->{size}));
		$ctrl->SetItem($row,4,$info->{ts} || '');	# PRH - need gmtToLocalTime($info->{ts}));
	}

	# things that might have changed due to rename

	$ctrl->SetItem($row,1,$ext);
	$ctrl->SetItem($row,2,$is_dir?'':$compare_type);

    # set the color and font

    my $item = $ctrl->GetItem($row);
    $item->SetFont($font);
    $item->SetTextColour($color);
	$ctrl->SetItem($item);

}   # addListRow()




#-----------------------------------------------
# setContents and populate
#-----------------------------------------------

sub setContents
	# set the contents based on a directory list.
	# which may be optionally passed in
	# short return if not local and not connected
{
    my ($this,$dir_info) = @_;
	return if !$this->{is_local} && !$this->{session}->isConnected();

    my $dir = $this->{dir};
    my $local = $this->{is_local};
    display($dbg_pop,0,"setContents($local,$dir)");
    $this->{last_selected_index} = -1;

    my @list;     # an array (by index) of infos ...
	my %hash;

    if (!$dir_info)
    {
		$dir_info = $this->doCommand('setContents',$SESSION_COMMAND_LIST,$local,$dir);
		return if $dir_info && $dir_info eq '-2';
			# PRH -2 indicates a threaded command underway
	}

	# PRH - called back, -1 indicates threaded command failed

	if (!$dir_info || $dir_info eq '-1')
	{
		$this->{parent}->{enabled_ctrl}->SetLabel("Could not get directory listing");
		$this->{parent}->{enabled_ctrl}->SetForegroundColour($color_red);
		$this->{list} = \@list;
		$this->{hash} = \%hash;
		$this->{list_ctrl}->DeleteAllItems();
		$this->{changed} = 1;
		# $this->setEnabled(0,"Could not get directory listing");
		return;
	}

	$this->{parent}->{enabled_ctrl}->SetLabel("");

	$this->{got_list} = 1;

	# add ...UP... or ...ROOT...

	my $dir_entry_name = $dir eq "/" ? '...ROOT...' : '...UP...';
	my $dir_info_entry =
	{
		is_dir      => 1,
		dir         => '',
		ts   		=> $dir_info->{ts},
		size        => '',
		entry		=> $dir_entry_name,
		compare     => '',
		entries     => {}
	};

	push @list,$dir_info_entry;
	$hash{$dir_entry_name} = $dir_info_entry;

	for my $entry (sort {lc($a) cmp lc($b)} (keys %{$dir_info->{entries}}))
	{
		my $info = $dir_info->{entries}->{$entry};
		$info->{ext} = !$info->{is_dir} && $info->{entry} =~ /^.*\.(.+)$/ ? $1 : '';
		push @list,$info;
		$hash{$entry} = $info;
	}

    $this->{list} = \@list;
    $this->{hash} = \%hash;
    $this->{last_sortcol} = 0;
    $this->{last_desc}   = 0;
    $this->{changed} = 1;

}   # setContents



sub populate
    # display the directory listing,
    # comparing it to the other window
    # and calling populate on the other
    # window as necessary.
{
    my ($this,$from_other) = @_;
    my $dir = $this->{dir};

    $from_other ||= 0;

    # debug and display title

    display($dbg_pop,0,"populate($from_other) local=$this->{is_local} dir=$dir");
	display($dbg_pop,1,"this changed ...") if $this->{changed};

    if (!$this->{is_local} && !$this->{session}->isConnected())
    {
		return;
    }
    else
    {
        $this->{dir_ctrl}->SetLabel($dir);
    }

    # compare the two lists before displaying

    my $other = $this->compareLists();

	# if the data has changed, fully repopulate the control
    # if the data has not changed, we don't pass in an entry
	# we use the number of items in our list cuz the control
	#	  might not have any yet

    if ($this->{changed} || $from_other)
    {
        $this->{list_ctrl}->DeleteAllItems() if $this->{changed};

		if ($this->{list})
		{
			for my $row (0..@{$this->{list}}-1)
			{
				my $use_entry = $this->{changed} ? $this->{list}->[$row]->{entry} : 0;
				$this->setListRow($row,$use_entry);
			}
		}
	}

    # sort the control, which is already optimized

    $this->sortListCtrl();

    # if we changed, then tell the
    # other window to compareLists and populate ..

    if ($this->{changed})
    {
        $this->{changed} = 0;
        $other->populate(1) if (!$from_other);
    }

    # finished

    $this->Refresh();

}   # populate()




#------------------------------------------------
# Selection Handlers
#------------------------------------------------

sub onDoubleClick
    # {this} is the list control
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
    return if (!$this->checkConnected());
	return if $this->{parent}->{thread};
			# free up for more commands

    my $item = $event->GetItem();
    my $index = $item->GetData();
    my $entry = $item->GetText();
    my $info = $this->{list}->[$index];
    my $is_dir = $info->{is_dir};

    display($dbg_ops,1,"onDoubleClick is_dir=$is_dir entry=$entry");

    if ($is_dir)
    {
        return if $entry eq '...ROOT...';
        my $dir = $this->{dir};
        if ($entry eq '...UP...')
        {
            $dir =~ /(.*)\/(.+)?$/;
            $entry = $1;
            $entry = '/' if (!$entry);
        }
        else
        {
            $entry = makepath($dir,$entry);
        }
        $this->{dir} = $entry;

        my $follow = $this->{parent}->{follow_dirs}->GetValue();

        my $other = $this->{is_local} ?
            $this->{parent}->{pane2}  :
            $this->{parent}->{pane1}  ;
		$this->setContents();

        if ($follow)
        {
            $other->{dir} = $this->{dir};
            $other->setContents();
        }

        $this->populate();

    }
    else   # double click on file
    {
        $this->doCommandSelected($COMMAND_XFER);
			# PRH COMMAND_XFER not implemented yet
    }
}



sub onItemSelected
    # it's twice they've selected this item then
    # start renaming it.
{
    my ($ctrl,$event) = @_;
    my $item = $event->GetItem();
    my $row = $event->GetIndex();

    # unselect the 0th row

    if (!$row)
    {
        display($dbg_ops,2,"unselecting row 0");
        $item->SetStateMask(wxLIST_STATE_SELECTED);
        $item->SetState(0);
        $ctrl->SetItem($item);
        return;
    }

    $event->Skip();

    my $this = $ctrl->{parent};
    my $index = $item->GetData();
    my $old_index = $this->{last_selected_index};
    my $num_sel = $ctrl->GetSelectedItemCount();

    display($dbg_ops,0,"onItemSelected($index) old=$old_index num=$num_sel");

    if ($num_sel > 1 || $index != $old_index)
    {
        $this->{last_selected_index} = $index;
    }
    else
    {
		display($dbg_ops,0,"calling doRename()");
        $this->doRename();
    }
}


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

	warning($dbg_threaded_commands,-1,"doCommandThreaded($caller,$command,$local) called");

	my $rslt = $this->{session}->doCommand(
		$command,
		$local,
		$param1,
		$param2,
		$param3,
		$this);

	warning($dbg_threaded_commands,-1,"doCommandThreaded($caller) got rslt=$rslt");

	# scalar result can be an error message
	# and we still want to pass caller for doRename

	if ($rslt && !ref($rslt) && $caller eq 'doRename')
	{
		display($dbg_threaded_commands,-2,"setting rename_error=$rslt");
		$rslt = shared_clone({ rename_error => $rslt })
	}

	# we want to pass a bare hash, with the caller, if there was no result

	$rslt ||= shared_clone({});
	$rslt->{caller} = $caller if ref($rslt);
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
}


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
		display($dbg_threaded_commands,1,"onThreadEvent caller($caller)");
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

	display($dbg_threaded_commands,1,"onThreadEvent rslt=$rslt");

	if ($rslt =~ s/^ERROR - //)
	{
		error($rslt);
		delete $this->{parent}->{thread};
			# free up for more commands
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
			display($dbg_threaded_commands,1,"onThreadEvent(PROGRESS,$command,$params[0],$params[1])");

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



# $this is now a progress like thing

sub addDirsAndFiles
{
	my ($this,$num_dirs,$num_files) = @_;
	display($dbg_threaded_commands,-1,"THIS->addDirsAndFiles($num_dirs,$num_files)");
	my $rslt:shared = "PROGRESS\tADD\t$num_dirs\t$num_files";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
	# Wx::App::GetInstance()->Yield();
}
sub setDone
{
	my ($this,$is_dir) = @_;
	display($dbg_threaded_commands,-1,"THIS->setDone($is_dir)");
	my $rslt:shared = "PROGRESS\tDONE\t$is_dir";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
	# Wx::App::GetInstance()->Yield();
}
sub setEntry
{
	my ($this,$entry) = @_;
	display($dbg_threaded_commands,-1,"THIS->setEntry($entry)");
	my $rslt:shared = "PROGRESS\tENTRY\t$entry";
	my $evt = new Wx::PlThreadEvent( -1, $THREAD_EVENT, $rslt );
	Wx::PostEvent( $this, $evt );
	# Wx::App::GetInstance()->Yield();
}










1;
