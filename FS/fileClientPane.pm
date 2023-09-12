#!/usr/bin/perl
#-------------------------------------------
# filePane
#-------------------------------------------
# The workhorse window of the application

package Pub::FS::fileClientPane;
use strict;
use warnings;
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
    EVT_LIST_END_LABEL_EDIT );
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
my $dbg_pop  = 0;		# populate, sort, etc
	# 0 = basic calls
	# =1 = first order items
	# -2 = sort and gruesome details
my $dbg_ops  = 0;		# commands
	# 0 = basic calls
	# -1, -2 = more detail


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


#-----------------------------------
# new
#-----------------------------------

sub new
{
    my ($class,$parent,$splitter,$session,$is_local,$dir) = @_;
    my $this = $class->SUPER::new($splitter);

    $this->{parent}   = $parent;
    $this->{session}  = $session;
    $this->{is_local} = $is_local;
    $this->{dir}      = $dir;
    $this->{title_ctrl} = Wx::StaticText->new($this,-1,'',[0,0]);
    $this->{title_ctrl}->SetFont($title_font);

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

    # a message that gets displayed in populate if not connected

    $this->setConnectMsg('NO CONNECTION');

    # finished - layout & set_contents

    $this->{sort_col} = 0;
    $this->{sort_desc} = 0;
    $this->doLayout();
    $this->set_contents();

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

    return $this;

}   # filePane::new()


#--------------------------------------------
# simple event handlers and layout
#--------------------------------------------

sub onSize
{
    my ($this,$event) = @_;
	$this->doLayout();
    $event->Skip();
}


sub doLayout
{
    my ($this) = @_;
	my $sz = $this->GetSize();
    my $width = $sz->GetWidth();
    my $height = $sz->GetHeight();
    $this->{list_ctrl}->SetSize([$width,$height-$PANE_TOP]);
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
    my $key_code = $event->GetKeyCode();
    display($dbg_ops,0,"onKeyDown($key_code)");

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


#----------------------------------------------
# connection utilities
#----------------------------------------------

sub setConnectMsg
{
    my ($this,$msg) = @_;
    $this->{not_connected_msg} = $msg;
    $this->{title_ctrl}->SetLabel($this->{not_connected_msg});
}


sub checkConnected
{
    my ($this) = @_;
    return 1 if $this->{is_local} || $this->{session}->isConnected();
    error("Not connected!");
    return 0;
}


sub disconnect
{
    my ($this) = @_;
    return if (!$this->checkConnected());
    display($dbg_life,0,"Disconnecting...");
    $this->setConnectMsg('DISCONNECTED');
    $this->{session}->disconnect();
    $this->populate();
}


sub connect
{
    my ($this) = @_;
    $this->disconnect() if ($this->{session}->isConnected());
    $this->setConnectMsg('CONNECTING ...');
    display($dbg_life,0,"Connecting...");
    if (!$this->{session}->connect())
    {
        error("Could not connect!");
        return;
    }
    $this->set_contents();
    $this->populate();
}



#-----------------------------------------------
# set_contents
#-----------------------------------------------

sub set_contents
	# set the initial contents based on a directory list.
{
    my ($this) = @_;
    my $dir = $this->{dir};
    my $local = $this->{is_local};
    display($dbg_pop,0,"set_contents($local,$dir)");
    $this->{last_selected_index} = -1;

    my @list;     # an array (by index) of infos ...
	my %hash;

    if ($this->{is_local} || $this->{session}->isConnected())
    {
        my $dir_info = $this->{session}->doCommand($SESSION_COMMAND_LIST,$local,$dir);
		    # $local ?
			# $this->{session}->_listLocalDir($dir) :
			# $this->{session}->_listRemoteDir($dir);
		return if !$dir_info;

        # add ...UP... or ...ROOT...

		push @list,
		{
            is_dir      => 1,
            dir         => '',
            ts   		=> '',
            size        => '',
			entry		=> $dir eq "/" ? '...ROOT...' : '...UP...',
            compare     => '',
            entries     => {}
		};

        for my $entry (sort {lc($a) cmp lc($b)} (keys %{$dir_info->{entries}}))
        {
			my $info = $dir_info->{entries}->{$entry};
			$info->{ext} = !$info->{is_dir} && $info->{entry} =~ /^.*\.(.+)$/ ? $1 : '';
            push @list,$info;
			$hash{$entry} = $info;
        }
    }

    $this->{list} = \@list;
    $this->{hash} = \%hash;
    $this->{last_sortcol} = 0;
    $this->{last_desc}   = 0;
    $this->{changed} = 1;

}   # set_contents



#-----------------------------------------------
# Sort
#-----------------------------------------------

sub onClickColHeader
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
    return if (!$this->checkConnected());

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


sub comp
{
    my ($list,$sort_col,$desc,$index_a,$index_b) = @_;
    my $info_a = $$list[$index_a];
    my $info_b = $$list[$index_b];

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
        display($dbg_pop+2,0,"comp_dir($info_a->{entry},$info_b->{entry}) returning -1");
    }
    elsif ($info_b->{is_dir} && !$info_a->{is_dir})
    {
        $retval = 1;
        display($dbg_pop+2,0,"comp_dir($info_a->{entry},$info_b->{entry}) returning 1");
    }

    elsif ($info_a->{is_dir} && $sort_col>0 && $sort_col<$num_fields)
    {
		# we sort directories ascending except on the entry field
		$retval = (lc($info_a->{entry}) cmp lc($info_b->{entry}));
        display($dbg_pop+2,0,"comp_same_dir($info_a->{entry},$info_b->{entry}) returning $retval");
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

        display($dbg_pop+1,0,"comp($field,$sort_col,$desc,$val_a,$val_b) returning $retval");
    }
    return $retval;

}   # comp() - compare two infos for sorting


sub sortListCtrl
{
    my ($this) = @_;
    my $list = $this->{list};
    my $ctrl = $this->{list_ctrl};
    my $sort_col = $this->{sort_col};
    my $sort_desc = $this->{sort_desc};

    display($dbg_pop+1,0,"sortListCtrl($sort_col,$sort_desc) local=$this->{is_local}");

    if ($sort_col == $this->{last_sortcol} &&
        $sort_desc == $this->{last_desc} &&
        !$this->{changed})
    {
        display($dbg_pop+1,1,"short ending last=$this->{last_desc}:$this->{last_sortcol}");
        return;
    }

    $ctrl->SortItems(sub {
        my ($a,$b) = @_;
        return comp($list,$sort_col,$sort_desc,$a,$b); });

	# now that they are sorted, {list} no longer matches the contents by row

    $this->{last_sortcol} = $sort_col;
    $this->{last_desc}   = $sort_desc;

}   # sort_entries() (with debugging)



#--------------------------------------------------------
# compare_lists and addListRow
#--------------------------------------------------------

sub getDbgPaneName
{
	my ($this) = @_;
	my $name = $this->{is_local} ? "LOCAL" : $this->{parent}->{name};
	$name .= " $this->{dir}";
	return $name;

}

sub compare_lists
{
    my ($this) = @_;

    my $hash = $this->{hash};

    my $other = $this->{is_local} ?
        $this->{parent}->{pane2} :
        $this->{parent}->{pane1} ;
    my $other_hash = $other->{hash};


    display($dbg_pop+1,0,"compare_list(".
			$this->getDbgPaneName().
			") other=(".
			$other->getDbgPaneName().
			")");

    # get a terminal node expression for the 'other' dir,
    # i.e. ...UP... == /junk/blah, so other_dir_name = 'blah',
    # then, while comparing dirs, highlight this one if it matches
    # the other.

    my $other_dir_name = '';
    $other_dir_name = $1 if $other->{dir} =~ /^.*\/(.+?)$/;

    for my $entry (keys(%$hash))
    {
        my $info = $$hash{$entry};
        display($dbg_pop+2,1,"checking $entry=$info");

        # do the opposite ...UP... on the client
        $entry = $1 if $entry eq '...UP...' && $this->{dir} =~ /^.*\/(.+?)$/;
        my $other_info = $$other_hash{$entry};

        $info->{compare} = '';

        if ($other_info)
        {
            display($dbg_pop+2,1,"found other info=$other_info");

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
        elsif ($info->{is_dir} && $entry eq $other_dir_name)
        {
            $info->{compare} = 2;
        }
    }

    display($dbg_pop+1,1,"compare_lists() returning");

    return $other;

}   # compare_lists()



sub addListRow
    # called to add, or refresh a given list row
{
    my ($this,$list,$row,$set_only) = @_;
    my $ctrl = $this->{list_ctrl};

	# if set only, get the index into OUR list
	# from the control (otherwise we are creating
	# the list with proper indexes)

	$set_only ||= 0;

	my $id = $row;
    my $info = $$list[$row];
    my $entry = $info->{entry};
    my $is_dir = $info->{is_dir} || '';
	my $compare = $info->{compare} || '';

    my $compare_type = !$compare ? '' :
        $compare == 3 ? 'newer' :
        $compare == 2 ? 'same' :
        $compare == 1 ? 'older' : '';
    display($dbg_pop+1,0,"addListRow($row,$is_dir,$compare_type,$set_only,$entry)");

    # create the item (if !set_only)

    if (!$set_only)
    {
        $ctrl->InsertStringItem($row,$entry);
        $ctrl->SetItemData($row,$id);

        # add main fields ...

        $ctrl->SetItem($row,3,($is_dir?'':$info->{size}));
        $ctrl->SetItem($row,4,$info->{ts});	# gmtToLocalTime($info->{ts}));
    }
	else
	{
		$id = $ctrl->GetItemData($row);
		display($dbg_pop+2,0,"addListRow mapping row($row) to $id");
	}

    # display/add fields that might have changed due to
    # RENAME or the other guy changing.

	my $ext = !$info->{is_dir} && $info->{entry} =~ /^.*\.(.+)$/ ? $1 : '';
    $ctrl->SetItem($id,1,$ext);
    $ctrl->SetItem($id,2,$is_dir?'':$compare_type);

    # set the color and font

    my $font = $normal_font;
    if ($is_dir)
    {
        $font = $bold_font;
    }

    my $color =
        $compare_type eq 'newer' ? $color_newer :
        $compare_type eq 'same'  ? $color_same :
        $compare_type eq 'older' ? $color_older :
        $color_missing;

    # can't get it to set just one row's format

    my $item = Wx::ListItem->new();
        # $ctrl->GetItem($row,0);

    $item->SetId($id);
    #$item->SetText('blah');
    #$item->SetMask(wxLIST_MASK_FORMAT|wxLIST_MASK_TEXT);
    $item->SetMask(wxLIST_MASK_FORMAT);

    $item->SetColumn(0);
    $item->SetFont($font);
    $item->SetTextColour($color);
    $ctrl->SetItem($item);


    if (0)  # some test code
    {
        $item->SetColumn(1);
        $item->SetTextColour($color_missing);
        $ctrl->SetItem($item);
    }


}   # addListRow()



#---------------------------------------------------------------------------
# populate()
#---------------------------------------------------------------------------

sub populate
    # display the directory listing,
    # comparing it to the other window
    # and calling populate on the other
    # window as necessary.
{
    my ($this,$from_other) = @_;
    my $dir = $this->{dir};
    my $ctrl = $this->{list_ctrl};

    $from_other = 0 if (!$from_other);

    # debug and display title

    display($dbg_pop,0,"populate($from_other) local=$this->{is_local} dir=$dir");

    if (!$this->{is_local} && !$this->{session}->isConnected())
    {
        $this->{title_ctrl}->SetLabel($this->{not_connected_msg});
    }
    else
    {
        $this->{title_ctrl}->SetLabel($dir);
    }

    # compare the two lists before displaying

    my $other = $this->compare_lists();

    # if the data has changed, repopulate the control
    # there should always be at least one entry ...
    # if the data has not changed, and we
    # are being called from 'other', then
    # we need to call addListRow with
    # set_only == !changed to set the colors appropriately

    if ($this->{changed} || $from_other)
    {
        my $list = $this->{list};
        $ctrl->DeleteAllItems() if $this->{changed};
        for my $row (0..@$list-1)
        {
            $this->addListRow($list,$row,!$this->{changed});
        }
    }

    # sort the control, which is already optimized

    $this->sortListCtrl();

    # if we changed, then tell the
    # other window to compare_lists and populate ..
    # the 1 is recursion protection

    if ($this->{changed})
    {
        $this->{changed} = 0;
        display($dbg_pop,0,"this changed ...");
        $other->populate(1) if (!$from_other);
    }

    # finished
    # Refresh is not always needed

    $this->Refresh();

}   # populate()




#------------------------------------------------
# Command event handlers
#------------------------------------------------

sub onContextMenu
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
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
        $enabled = $local || $connected;
    }

    # xfer requires both sides and some stuff

    elsif ($id == $COMMAND_XFER)
    {
        $enabled = $connected && $ctrl->GetSelectedItemCount();
    }

    # rename requires exactly one selected item

    elsif ($id == $COMMAND_RENAME)
    {
        $enabled = ($local || $connected) &&
            $ctrl->GetSelectedItemCount() == 1;
    }

    $event->Enable($enabled);
}



sub onCommand
{
    my ($this,$event) = @_;
    my $id = $event->GetId();

    if ($id == $COMMAND_REFRESH)
    {
        $this->set_contents();
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



sub onDoubleClick
    # {this} is the list control
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
    return if (!$this->checkConnected());

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

        $this->set_contents();

        if ($follow)
        {
            $other->{dir} = $this->{dir};
            $other->set_contents();
        }

        $this->populate();

    }
    else   # double click on file
    {
        $this->doCommandSelected($COMMAND_XFER);
    }
}



sub doCommandSelected
{
    my ($this,$id) = @_;
    return if (!$this->checkConnected());

    my @entries;
    my %subdir;
    my $ctrl = $this->{list_ctrl};
    my $num_files = 0;
    my $num_dirs = 0;
    my $num = $ctrl->GetItemCount();
    my $local = $this->{is_local};
    my $other = $local ?
        $this->{parent}->{pane2}  :
        $this->{parent}->{pane1}  ;

    display($dbg_ops,1,"doCommandSelected(".$ctrl->GetSelectedItemCount()."/$num) selected items");

    # build a list of the selected entries
    # prevent item zero from being grabbed
    # hence loop starts at one

    for (my $i=1; $i<$num; $i++)
    {
        if ($ctrl->GetItemState($i,wxLIST_STATE_SELECTED))
        {
            my $entry = $ctrl->GetItemText($i);
            my $index = $ctrl->GetItemData($i);
            my $info = $this->{list}->[$index];
            my $is_dir = $info->{is_dir};

            $num_dirs++ if $is_dir;
            $num_files++ if !$is_dir;

            display($dbg_ops+1,2,"selected=$entry");
            push @entries,$entry;
            $subdir{$entry} = 1 if ($is_dir);
        }
    }

    # build a message saying what will be affected

    my $file_and_dirs = '';
    if ($num_files == 0 && $num_dirs == 1)
    {
        $file_and_dirs = "the directory '$entries[0]'";
    }
    elsif ($num_dirs == 0 && $num_files == 1)
    {
        $file_and_dirs = "the file '$entries[0]'";
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

    # Recursive commands

    if ($id == $COMMAND_XFER ||
		$id == $COMMAND_DELETE)
    {
		my $command =
			$id == $COMMAND_XFER ? $local ? 'UPLOAD' : 'DOWNLOAD' :
			'DELETE';
		my $params = $id == $COMMAND_DELETE ?
			{ DELETE=>1 } :
			{
				$command => $other->{dir},
				sync_any => $this->{parent}->{sync_any}->GetValue() ? 1 : 0
			};

		my $update_win = $id == $COMMAND_DELETE ?
			$this : $other;


        return if !yesNoDialog($this,
            "Are you sure you want to ".lc($command)." $file_and_dirs ??",
            CapFirst($command)." Confirmation");


        display($dbg_ops,1,"COMMAND_$command");

        $this->doUICommandRecursive(
				$command,
				$num_files,
				$num_dirs,
				\@entries,
				\%subdir,
                $local,
                $params);

		$update_win->set_contents();
        $update_win->populate();
    }

    # different dialog boxes, but similar calls
    # for SETDTIME, SETMODE, and SET_UG

    else
    {
        my $dlg;
        my $opt = '';

        # show the dialog get the result
        # quit if not ok

        my $rslt = $dlg->ShowModal();
        my ($val,$recurse) = $dlg->getResults();
        $dlg->Destroy();
        return if ($rslt != wxID_OK);

        $val = localToGMTTime($val);
        my %opts;
        $opts{$opt} = $val;
        $opts{RECURSE} = 1 if ($recurse);

		$this->doUICommandRecursive(
			$opt,
			$num_files,
			$num_dirs,
			# $opt." ".$file_and_dirs,
			\@entries,
			\%subdir,
			$local,
			\%opts);

		$this->set_contents();
        $this->populate();

    }

}   # doCommandSelected()



sub doUICommandRecursive
	# mostly exists to wrap the command
	# in a progress dialog
{
    my ($this,
		$what,
		$num_files,
		$num_dirs,
		$entries,			# entries upon which to operate
		$subdir,			# hash telling if entries are subdirs
        $local,				# constant
        $opts) = @_;		# reference

	my $progress = fileProgressDialog->new(
		undef,
		$what,
		$num_files,
		$num_dirs);

	for my $entry (@$entries)
	{
		last if !$this->{session}->doCommandRecursive(
			$local,
			$subdir->{$entry} ? 1:0,
			$opts,
			$this->{dir},
			$entry,
			$progress);
	}

	$progress->Destroy();
}





#-------------------------------------------------
# COMMAND_RENAME
#-------------------------------------------------

sub onBeginEditLabel
{
    my ($ctrl,$event) = @_;
    my $row = $event->GetIndex();
    my $col = 0;  # $event->GetColumn();

    display($dbg_ops,1,"onBeginEditLabel($row,$col)");

    # - deselect the file extension if any

    if (!$row || $col)
    {
        $event->Veto();
    }
    else
    {
        my $this = $ctrl->{parent};
        my $entry = $ctrl->GetItem($row,$col)->GetText();
        $this->{save_entry} = $entry;
        display($dbg_ops,2,"save_entry=$entry  list_index=".$ctrl->GetItemData($row));
		$event->Skip();
    }
}

sub onEndEditLabel
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
    my $row = $event->GetIndex();
    my $col = $event->GetColumn();
    my $entry = $event->GetLabel();
    my $save_entry = $this->{save_entry};
    my $is_cancelled = $event->IsEditCancelled() ? 1 : 0;
    $this->{save_entry} = '';

    # can't rename to a blank

    if (!$entry || $entry eq '')
    {
        $event->Veto();
        return;
    }

    display($dbg_ops,1,"onEndEditLabel($row,$col) cancelled=$is_cancelled entry=$entry save=$save_entry");
    display($dbg_ops+1,2,"ctrl=$ctrl this=$this session=$this->{session}");

    if (!$is_cancelled && $entry ne $save_entry)
    {
        # my $info = $this->{session}->renameItem(
        my $info = $this->{session}->doCommand($SESSION_COMMAND_RENAME,
            $this->{is_local},
            $this->{dir},
            $save_entry,
            $entry);

        # if the rename failed, the error was already reported
		# to the UI via Session::textToList().
        # Here we add a pending event to start editing again ...

        if (!$info)
        {
            # error("renameItem failed!!");
            $event->Veto();

            my $new_event = Wx::CommandEvent->new(
                wxEVT_COMMAND_MENU_SELECTED,
                $COMMAND_RENAME);
            $this->AddPendingEvent($new_event);
            return;
        }

        # fix up the entry of dirs, reset the
        # hash and list members, and maybe tell the
        # list it is not sorted any more (if it
        # was sorted by name or ext)

        my $index = $ctrl->GetItemData($row);
        my $list = $this->{list};
        my $hash = $this->{hash};

        display($dbg_ops,2,"renameItem re-setting list[$index]=$$list[$index] and $hash\{$save_entry}=$$hash{$save_entry}");

        # the ext and entry for dirs
        # could be set in base class and from_text constructors

        if ($info->{is_dir})
        {
            my $d = $info->{dir};
            $d =~ s/$this->{dir}//;
            $d =~ s/^\///;
            $info->{entry} = $d;
        }

        $info->{ext} = !$info->{is_dir} && $info->{entry} =~ /^.*\.(.+)$/ ? $1 : '';

        $$list[$index] = $info;
        delete $$hash{$save_entry};
        $$hash{$entry} = $info;
        $this->{last_sortcol} = -1 if ($this->{last_sortcol} <= 1);

        # sort does not work from within the
        # event, as wx has not finalized it's edit
        # so we chain another event to repopulate

        my $new_event = Wx::CommandEvent->new(
            wxEVT_COMMAND_MENU_SELECTED,
            $COMMAND_REPOPULATE);
        $this->AddPendingEvent($new_event);
    }
}


sub doRename
{
    my ($this) = @_;
    my $ctrl = $this->{list_ctrl};
    my $num = $ctrl->GetItemCount();

    # get the item to edit

    my $i;
    for ($i=1; $i<$num; $i++)
    {
        last if $ctrl->GetItemState($i,wxLIST_STATE_SELECTED);
    }
    if ($i >= $num)
    {
        error("No items selected!");
        return;
    }

    # start editing the item in place ...

    display($dbg_ops,1,"doRename($i) starting edit ...");
    $ctrl->EditLabel($i);

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


#------------------------------------------------------------
# other COMMANDS
#------------------------------------------------------------

sub doMakeDir
    # responds to COMMAND_MKDIR command event
{
    my ($this) = @_;
    my $ctrl = $this->{list_ctrl};
    display($dbg_ops,1,"doMakeDir()");

    # Bring up a self-checking dialog box for accepting the new name

    my $dlg = mkdirDialog->new($this);
    my $rslt = $dlg->ShowModal();
    my $new_name = $dlg->getResults();
    $dlg->Destroy();

    # Do the command (locally or remotely)

    return if $rslt == wxID_OK &&
		!$this->{session}->doCommand($SESSION_COMMAND_MKDIR,
            $this->{is_local},
            $this->{dir},
            $new_name);

        #!$this->{session}->makeDirectory($this->{is_local},$this->{dir},$new_name);

    $this->set_contents();
    $this->populate();
    return 1;
}


1;
