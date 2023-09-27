#!/usr/bin/perl
#-------------------------------------------
# filePane
#-------------------------------------------
# The workhorse window of the application.
# For a discussion if threads in wxPerl, see:
# https://metacpan.org/dist/Wx/view/lib/Wx/Thread.pod

package Pub::FC::Pane;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
    EVT_SIZE
    EVT_MENU
	EVT_IDLE
	EVT_CLOSE
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
use Pub::WX::Dialogs;
use Pub::FS::FileInfo;
# use Pub::FS::Session;
use Pub::FC::ThreadedSession;
use Pub::FC::Resources;

use base qw(Wx::Window);


my $dbg_life = 0;		# life_cycle
my $dbg_pop  = 1;		# populate
	# -1 = addItem
	# -2 = addItem idx mapping
my $dbg_comp = 1;		# compare colors
	# -1 = entries
my $dbg_sort = 1;		# sorting
	# =1 = details
my $dbg_sel  = 1;		# item selection
	# -1, -2 = more detail



BEGIN {
    use Exporter qw( import );
	our @EXPORT = qw (
		$COMMAND_REPOPULATE
		$THREAD_EVENT
	);
}


our $COMMAND_REPOPULATE = 8765;


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
    my ($class,$parent,$splitter,$params) = @_;
    my $this = $class->SUPER::new($splitter);

	display($dbg_life,0,"new $params->{pane_num} port=$params->{port}");

    $this->{parent}    = $parent;
    $this->{dir}       = $params->{dir};
	$this->{pane_num}  = $params->{pane_num};
	$this->{port}	   = $params->{port};

	$this->{enabled}   = 1;
	$this->{got_list}  = 0;
	$this->{connected} = 1;

	# Create the {session}

	if ($params->{port})
	{
		my $use_instance = $params->{pane_num} * 100 +
			$parent->{instance};

		$this->{session} = Pub::FC::ThreadedSession->new({
			pane => $this,
			HOST => $params->{host},
			PORT => $params->{port},
			INSTANCE => $use_instance,
			IS_BRIDGED => $params->{is_bridged} });

		$this->checkConnected();
	}
	else
	{
		$this->{session} = Pub::FS::Session->new();
	}

	$this->{session}->{NAME} .= "(pane$this->{pane_num})";

	# create the {dir_ctrl{}

    $this->{dir_ctrl} = Wx::StaticText->new($this,-1,'',[10,0]);
    $this->{dir_ctrl}->SetFont($title_font);

    # set up the {list_control}

    my $ctrl = Wx::ListCtrl->new(
        $this,-1,[0,$PANE_TOP],[-1,-1],
        wxLC_REPORT | wxLC_EDIT_LABELS);
    $ctrl->{parent} = $this;
	$this->{list_ctrl} = $ctrl;

    for my $i (0..$num_fields-1)
    {
        my ($field,$width) = ($fields[$i*2],$fields[$i*2+1]);
        my $align = $i ? wxLIST_FORMAT_RIGHT : wxLIST_FORMAT_LEFT;
        $ctrl->InsertColumn($i,$field,$align,$width);
    }

    # finished - layout & setContents

    $this->{sort_col} = 0;
    $this->{sort_desc} = 0;
	$this->{last_sortcol} = -1;
	$this->{last_desc} = -1;

    $this->doLayout();

    $this->setContents();

    EVT_SIZE($this,\&onSize);
	EVT_IDLE($this,\&onIdle);
	EVT_CLOSE($this,\&onClose);
    EVT_CONTEXT_MENU($ctrl,\&onContextMenu);
    EVT_MENU($this,$COMMAND_REPOPULATE,\&onRepopulate);
    EVT_MENU_RANGE($this, $COMMAND_XFER, $COMMAND_DISCONNECT, \&onCommand);
	EVT_UPDATE_UI_RANGE($this, $COMMAND_XFER, $COMMAND_DISCONNECT, \&onCommandUI);
    EVT_LIST_KEY_DOWN($ctrl,-1,\&onKeyDown);
    EVT_LIST_COL_CLICK($ctrl,-1,\&onClickColHeader);
    EVT_LIST_ITEM_SELECTED($ctrl,-1,\&onItemSelected);
    EVT_LIST_ITEM_ACTIVATED($ctrl,-1,\&onDoubleClick);

	# in fileClientCommands.pm

    EVT_LIST_BEGIN_LABEL_EDIT($ctrl,-1,\&onBeginEditLabel);
    EVT_LIST_END_LABEL_EDIT($ctrl,-1,\&onEndEditLabel);
	EVT_COMMAND($this, -1, $THREAD_EVENT, \&onThreadEvent )
		if $this->{port};

    return $this;

}   # filePane::new()


# accessor for the "other" pane

sub otherPane
{
	my ($this) = @_;
	return $this->{pane_num} == 1 ?
		$this->{parent}->{pane2} :
		$this->{parent}->{pane1} ;
}


#--------------------------------------------
# simple event handlers and layout
#--------------------------------------------

sub onSize
{
    my ($this,$event) = @_;
	$this->doLayout();
    $event->Skip();
}

sub onClose
	# the bane of my existence.
	# onClose seems to get called twice,  once before deleting the pane
	# and once after ... I may try to figure that out later, but for
	# now I exit the whole program when it reaches zero
{
	my ($this,$event) = @_;
	display($dbg_life,-1,"Pane::onClose(pane$this->{pane_num}) called");
	if ($this->{port} && $this->{session}->{SOCK} && !$this->{GOT_EXIT})
	{
		$this->{GOT_EXIT} = 1;
		# no error checking on result
		$this->{session}->sendPacket($PROTOCOL_EXIT)
	}
	# $this->SUPER::onClose();
	$event->Skip();
}



sub doLayout
{
    my ($this) = @_;
	my $sz = $this->GetSize();
    my $width = $sz->GetWidth();
    my $height = $sz->GetHeight();
    $this->{list_ctrl}->SetSize([$width,$height-$PANE_TOP]);
	if ($this->{pane_num} == 2)
	{
		my $sash_pos = $this->{parent}->{splitter}->GetSashPosition();
		$this->{parent}->{enabled_ctrl2}->Move($sash_pos+10,5);
	}
}


sub onRepopulate
{
    my ($this,$event) = @_;
    display($dbg_pop,0,"onRepopulate()");
    $this->populate(1);
    $this->otherPane()->populate(1);
}


sub onKeyDown
{
    my ($ctrl,$event) = @_;
	my $this = $ctrl->{parent};
	return if $this->{thread} || !$this->{enabled};

    my $key_code = $event->GetKeyCode();
    display($dbg_sel+2,0,"onKeyDown($key_code)");

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
	return if $this->{thread};
    display($dbg_sel,0,"filePane::onContextMenu()");
    my $menu = Pub::WX::Menu::createMenu('win_context_menu');
	$this->PopupMenu($menu,[-1,-1]);
}


sub onCommandUI
{
    my ($this,$event) = @_;
    my $id = $event->GetId();
    my $ctrl = $this->{list_ctrl};
    my $port = $this->{port};

    # default enable is true for local, and
    # 'is connected' for remote ...

    my $enabled = $this->{enabled} && ! $this->{thread};

   # Connection commands enabled only in a pane with a prt

    if ($id == $COMMAND_RECONNECT)
    {
        $enabled = $port;
    }
    elsif ($id == $COMMAND_DISCONNECT)
    {
        $enabled &&= $port && $this->{session}->isConnected();
    }

    # refresh and mkdir depend on a connection if there's a $port

    elsif ($id == $COMMAND_REFRESH ||
           $id == $COMMAND_MKDIR)
    {
        $enabled &&= !$port || $this->{session}->isConnected();
    }

    # rename requires exactly one selected item

    elsif ($id == $COMMAND_RENAME)
    {
        $enabled &&= $ctrl->GetSelectedItemCount()==1 &&
			(!$port || $this->{session}->isConnected());
    }

	# delete requires some selected items

    elsif ($id == $COMMAND_DELETE)
    {
        $enabled &&= $ctrl->GetSelectedItemCount() &&
			(!$port || $this->{session}->isConnected());
    }

    # xfer requires both sides and some stuff
	# oops I don't know how to do an xfer from pane1!

    elsif ($id == $COMMAND_XFER)
    {
		my $other = $this->otherPane();
        $enabled &&= $ctrl->GetSelectedItemCount() &&
			(!$port || $this->{session}->isConnected()) &&
			(!$other->{port} || $other->{session}->isConnected());
    }

    $event->Enable($enabled);
}


#----------------------------------------------
# connection utilities
#----------------------------------------------

sub setEnabled
{
	my ($this,$enable,$msg) = @_;
	$msg ||= '';
	if ($this->{enabled} != $enable)
	{
		# We don't actually disable the window, so they
		# can still get to the context menu to reconnect.
		# We just prevent methods from doing things.
		#        # $this->Enable($enable);

		$this->{enabled} = $enable;
		my $ctrl = $this->{pane_num} == 1 ?
			$this->{parent}->{enabled_ctrl1} :
			$this->{parent}->{enabled_ctrl2};
		$ctrl->SetLabel($enable ? '' : $msg);
		$ctrl->SetForegroundColour($enable ? $color_green : $color_blue);

		# this snippet repopulates if it has never been done successfully

		if ($enable && !$this->{got_list})
		{
			$this->setContents();
			$this->populate();
		}
	}
}


sub checkConnected
{
    my ($this) = @_;
	return 1 if !$this->{port};
	my $connected = $this->{session}->isConnected();
	if ($this->{connected} != $connected)
	{
		$this->{connected} = $connected;
		if ($connected)
		{
			display($dbg_life,-1,"Connected");
			$this->{disconnected_by_pane} = 0;
			$this->setEnabled(1,'');
		}
		else
		{
			warning($dbg_life,-1,"Not connected!");
			$this->setEnabled(0,'NO CONNECTION');
		}
	}
    return $connected;
}


sub disconnect
{
    my ($this) = @_;
	return if !$this->{port};
    return if (!$this->checkConnected());
    display($dbg_life,0,"Disconnecting...");
	$this->{disconnected_by_pane} = 1;
    $this->{session}->disconnect();
	$this->checkConnected();
}


sub connect
{
    my ($this) = @_;
	return if !$this->{port};
    $this->disconnect() if $this->{connected};
    display($dbg_life,0,"Connecting...");
    $this->{session}->connect();
	if ($this->checkConnected())
    {
		$this->setContents();
		$this->populate();
		$this->setEnabled(1);
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
	return if $this->{thread} || !$this->{enabled};

    my $col = $event->GetColumn();
    my $prev_col = $this->{sort_col};
    display($dbg_sel+1,0,"onClickColHeader($col) prev_col=$prev_col desc=$this->{sort_desc}");

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

    display($dbg_sort,0,"sortListCtrl($sort_col,$sort_desc)");

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


sub compareLists
{
    my ($this) = @_;

    my $hash = $this->{hash};
    my $other = $this->otherPane();
    my $other_hash = $other->{hash};

    display($dbg_comp,0,"compareLists(pane$this->{pane_num},other$other->{pane_num}");

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
		$ctrl->SetItem($row,4,gmtToLocalTime($info->{ts}));
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
	return if $this->{port} && !$this->{session}->isConnected();
	$dir_info ||= '';

    my $dir = $this->{dir};
    display($dbg_pop,0,"setContents(pane$this->{pane_num},$dir_info) dir=$dir");
    $this->{last_selected_index} = -1;

    my @list;     # an array (by index) of infos ...
	my %hash;

    if (!$dir_info)
    {
		$dir_info = $this->{session}->doCommand(
			$PROTOCOL_LIST,
			$dir,			# param1
			'',				# param2
			'',				# param3
			'',				# progress
			'setContents',	# caller
			'');			# other session

		return if $dir_info && $dir_info eq '-2';
			# PRH -2 indicates a threaded command underway
	}

	# PRH - called back, -1 indicates threaded command failed

	my $ctrl = $this->{pane_num} == 1 ?
		$this->{parent}->{enabled_ctrl1} :
		$this->{parent}->{enabled_ctrl2};
	if (!$dir_info || $dir_info eq '-1')
	{
		$ctrl->SetLabel("Could not get directory listing");
		$ctrl->SetForegroundColour($color_red);
		$this->{list} = \@list;
		$this->{hash} = \%hash;
		$this->{list_ctrl}->DeleteAllItems();
		$this->{changed} = 1;
		return;
	}

	$ctrl->SetLabel("");

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

    display($dbg_pop,0,"populate(pane$this->{pane_num}) from_other=$from_other dir=$dir");
	display($dbg_pop,1,"this changed ...") if $this->{changed};

    return if $this->{port} && !$this->{session}->isConnected();

    $this->{dir_ctrl}->SetLabel($dir);

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
	return if $this->{thread} || !$this->{enabled};
			# free up for more commands

    my $item = $event->GetItem();
    my $index = $item->GetData();
    my $entry = $item->GetText();
    my $info = $this->{list}->[$index];
    my $is_dir = $info->{is_dir};

    display($dbg_sel,1,"onDoubleClick is_dir=$is_dir entry=$entry");

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
            $entry = makePath($dir,$entry);
        }
        $this->{dir} = $entry;

        my $follow = $this->{parent}->{follow_dirs}->GetValue();

		$this->setContents();

        if ($follow)
        {
			my $other = $this->otherPane();
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
	# can't prevent anyone from selecting items when not connected
    # if it's twice they've selected this item the start renaming it.
{
    my ($ctrl,$event) = @_;
	my $this = $ctrl->{parent};
    my $item = $event->GetItem();
    my $row = $event->GetIndex();

    # unselect the 0th row

    if (!$row)
    {
        display($dbg_sel,2,"unselecting row 0");
        $item->SetStateMask(wxLIST_STATE_SELECTED);
        $item->SetState(0);
        $ctrl->SetItem($item);
        return;
    }

    $event->Skip();

    my $index = $item->GetData();
    my $old_index = $this->{last_selected_index};
    my $num_sel = $ctrl->GetSelectedItemCount();

    display($dbg_sel,0,"onItemSelected($index) old=$old_index num=$num_sel");

    if ($num_sel > 1 || $index != $old_index)
    {
        $this->{last_selected_index} = $index;
    }
    else
    {
		display($dbg_sel,0,"calling doRename()");
        $this->doRename();
    }
}


1;
