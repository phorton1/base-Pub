#!/usr/bin/perl
#-------------------------------------------
# FC::Pane
#-------------------------------------------
# The workhorse window of the application.
#
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
use Pub::FS::ClientSession;
use Pub::FC::Resources;
use base qw(Wx::Window);


my $dbg_life = 0;		# life_cycle
my $dbg_pop  = 0;		# populate
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
our $THREAD_EVENT:shared = Wx::NewEventType;


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
my $color_diff    = Wx::Colour->new(0x00 ,0x60, 0xc0);  # cyan
my $color_missing = Wx::Colour->new(0x00 ,0x00, 0x00);  # black
my $color_older   = Wx::Colour->new(0xff, 0x00, 0xff);  # purple
my $color_newer   = Wx::Colour->new(0xff ,0x00, 0x00);  # red

my $color_black   = Wx::Colour->new(0x00 ,0x00, 0x00);  # black
my $color_red     = Wx::Colour->new(0xc0 ,0x00, 0x00);  # red
my $color_green   = Wx::Colour->new(0x00 ,0x90, 0x00);  # green
my $color_blue    = Wx::Colour->new(0x00 ,0x00, 0xc0);  # blue


sub compareType
{
	my ($comp_value) = @_;
	return '' if !$comp_value;
    return 'diff'  if $comp_value == 4;
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
	$params->{port} ||= 0;

	display($dbg_life,0,"new Pane($params->{pane_num}) port=$params->{port}");

	#------------------
	# init
	#------------------

    $this->{parent}  	  = $parent;
    $this->{dir}     	  = $params->{dir};
	$this->{pane_num}	  = $params->{pane_num};
	$this->{port}	 	  = $params->{port};
	$this->{enabled_ctrl} = $params->{enabled_ctrl};

	$this->{enabled}   = 0;
	$this->{got_list}  = 0;
	$this->{connected} = 0;

    $this->{sort_col}  = 0;
    $this->{sort_desc} = 0;
	$this->{last_sortcol} = -1;
	$this->{last_desc} = -1;

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

    # $this->doLayout();


	#---------------------------
	# Create the {session}
	#---------------------------

	if ($params->{port})
	{
		my $use_instance = $params->{pane_num} * 100 +
			$parent->{instance};

		# ctor tries to connect and returns !SOCK

		$this->{session} = Pub::FS::ClientSession->new({
			pane => $this,
			HOST => $params->{host},
			PORT => $params->{port},
			INSTANCE => $use_instance,
			IS_BRIDGED => $params->{is_bridged} });

		$this->{connected} = $this->{session}->isConnected();
		$this->setEnabled($this->{connected},"No initial connection",$color_red);
	}
	else
	{
		$this->{session} = Pub::FS::Session->new();
			# cannot fail
		$this->{connected} = 1;
		$this->setEnabled(1);
	}

	$this->{session}->{NAME} .= "(pane$this->{pane_num})";

	#------------------
	# setContents
	#------------------

    $this->setContents();

	#------------------
    # Event Handlers
	#------------------

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

    EVT_LIST_BEGIN_LABEL_EDIT($ctrl,-1,\&onBeginEditLabel);
    EVT_LIST_END_LABEL_EDIT($ctrl,-1,\&onEndEditLabel);
	EVT_COMMAND($this, -1, $THREAD_EVENT, \&onThreadEvent );

    return $this;

}   # filePane::new()




#----------------------------------------------
# connection utilities
#----------------------------------------------
# We never actually disable the window, so that they
# 	can still get to the context menu to reconnect.
# We just prevent the UI from doing things as follows.
#
# {thread} means a threaded command is underay and
#      all UI is disabled.
# !{enabled} means UI commands in general are disabled,
#      except for context menu Connect on a pane with a port.
#	   Panes with ports can be disabled/enabled via the socket
#      with messages in blue on disables.
# !{connected} means a port is not connected, and
#      implies ==> !enabled.  It is explicitly set
#      to enable the

sub setEnabled
	# 0 = requires and uses all params
	# 1 = forces color=black and msg=session->{SERVER_ID}
{
	my ($this,$enable,$msg,$color) = @_;

	$color = $color_black if $enable;
	$msg = $this->{session}->{SERVER_ID} if $enable;
	$color ||= $color_blue;

	display($dbg_life,0,sprintf("Pane$this->{pane_num} setEnabled($enable,$msg,0x%08x) enabled=$this->{enabled}",$color));
	if ($this->{enabled} != $enable)
	{
		display($dbg_life,0,"Pane$this->{pane_num} enable changed SERVER_ID=$this->{session}->{SERVER_ID}");
		$this->{enabled} = $enable;

		my $ctrl = $this->{enabled_ctrl};
		$ctrl->SetLabel($msg);
		$ctrl->SetForegroundColour($color);
	}
}



sub disconnect
{
    my ($this,$quiet) = @_;
	return if !$this->{port};
    return if !$this->{connected};
    display($dbg_life,0,"Pane$this->{pane_num} Disconnecting...");
	$this->{disconnected_by_pane} = 1;
    $this->{session}->disconnect();
	$this->{connected} = 0;
	$quiet ?
		$this->setEnabled(0,"Disconnected by user",$color_red) :
		$this->{enabled} = 0;
}


sub connect
{
    my ($this) = @_;
	return if !$this->{port};
    $this->disconnect(1) if $this->{connected};
    display($dbg_life,0,"Pane$this->{pane_num} Connecting...");
    $this->{connected} = $this->{session}->connect();
	$this->{connected} ?
		$this->setEnabled(0,"Could not connect to Server",$color_red) :
		$this->{enabled} = 0;

	if ($this->{connected})
    {
		$this->setContents();
		$this->{parent}->populate();
	}
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
	display($dbg_life,-1,"Pane$this->{pane_num} onClose(pane$this->{pane_num}) called");
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
		$this->{enabled_ctrl}->Move($sash_pos+10,5);
	}
}


sub onRepopulate
{
    my ($this,$event) = @_;
    display($dbg_pop,0,"Pane$this->{pane_num}  onRepopulate()");
	$this->{parent}->populate();
}


sub onKeyDown
{
    my ($ctrl,$event) = @_;
	my $this = $ctrl->{parent};
	return if $this->{thread} || !$this->{enabled};

    my $key_code = $event->GetKeyCode();
    display($dbg_sel+2,0,"Pane$this->{pane_num} onKeyDown($key_code)");

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
    display($dbg_sel,0,"Pane$this->{pane_num} onContextMenu()");
    my $menu = Pub::WX::Menu::createMenu('win_context_menu');
	$this->PopupMenu($menu,[-1,-1]);
}


sub uiEnabled
{
	my ($this) = @_;
	return
		!$this->{thread} &&
		$this->{enabled} &&
		$this->{connected};
}


sub onCommandUI
{
    my ($this,$event) = @_;
    my $id = $event->GetId();
    my $ctrl = $this->{list_ctrl};
    my $port = $this->{port};

    my $enabled =
		!$this->{thread} &&
		$this->{enabled} &&
		$this->{connected};

 	# $COMMAND_REFRESH  	uses $enabled as is
    # $COMMAND_MKDIR		uses $enabled as is
	# $COMMAND_DISCONNECT	uses_$enabled as is

    # RECONNECT available to anyone with a port

    if ($id == $COMMAND_RECONNECT)
    {
        $enabled = !$this->{thread} && $port;
    }

    # rename requires exactly one selected item

    elsif ($id == $COMMAND_RENAME)
    {
        $enabled &&= $ctrl->GetSelectedItemCount()==1;
    }

	# delete requires some selected items

    elsif ($id == $COMMAND_DELETE)
    {
        $enabled &&= $ctrl->GetSelectedItemCount();
    }

    # xfer requires both sides and some stuff
	# oops I don't know how to do an xfer from pane1!

    elsif ($id == $COMMAND_XFER)
    {
        $enabled &&= $ctrl->GetSelectedItemCount() &&
			$this->{other_pane}->{connected};
    }

    $event->Enable($enabled);
}




#-----------------------------------------------
# Sorting
#-----------------------------------------------

sub onClickColHeader
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
    return if !$this->uiEnabled();

    my $col = $event->GetColumn();
    my $prev_col = $this->{sort_col};
    display($dbg_sel+1,0,"Pane$this->{pane_num} onClickColHeader($col) prev_col=$prev_col desc=$this->{sort_desc}");

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

    display($dbg_sort,0,"Pane$this->{pane_num} sortListCtrl($sort_col,$sort_desc)");

    if ($sort_col == $this->{last_sortcol} &&
        $sort_desc == $this->{last_desc} &&
        !$this->{changed})
    {
        display($dbg_sort,1,"Pane$this->{pane_num} short ending last=$this->{last_desc}:$this->{last_sortcol}");
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
    my $other = $this->{other_pane};
    my $other_hash = $other->{hash};

    display($dbg_comp,0,"Pane$this->{pane_num} compareLists(Other$other->{pane_num})");

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
					$info->{size} != $other_info->{size} ?
						$info->{compare} = 4 :  # diff
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

    display($dbg_comp+1,1,"Pane$this->{pane_num} compareLists() returning");

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

    display($dbg_pop+1,0,"Pane$this->{pane_num} setListRow($is_new) row($row) isdir($is_dir) comp($compare_type) entry=$entry)");

	# prep

    my $font = $is_dir ? $bold_font : $normal_font;
	my $ext = !$is_dir && $entry =~ /^.*\.(.+)$/ ? $1 : '';
    my $color =
	    $compare_type eq 'diff'  ? $color_diff :
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
    my ($this,$dir_info,$from_other) = @_;
	return if !$this->{connected};
	$dir_info ||= '';
	$from_other ||= 0;

    my $dir = $this->{dir};
    display($dbg_pop,0,"Pane$this->{pane_num} setContents($dir_info,$from_other) dir=$dir");
    $this->{last_selected_index} = -1;

    my @list;     # an array (by index) of infos ...
	my %hash;

    if (!$dir_info)
    {
		$dir_info = $this->doCommand(
			'setContents',
			$PROTOCOL_LIST,
			$dir);
		return if $dir_info && $dir_info eq '-2';
			# PRH -2 indicates a threaded command underway
	}

	# We always add ...UP... or ...ROOT...

	my $is_valid = $dir_info && $dir_info ne '-1';
	my $dir_ts = $is_valid ? $dir_info->{ts} : '';
	my $dir_entry_name = $dir eq "/" ? '...ROOT...' : '...UP...';
	my $dir_info_entry =
	{
		is_dir      => 1,
		dir         => '',
		ts   		=> $dir_ts,
		size        => '',
		entry		=> $dir_entry_name,
		compare     => '',
		entries     => {}
	};

	push @list,$dir_info_entry;
	$hash{$dir_entry_name} = $dir_info_entry;

	# Could not get directory listing if !dir_info
	# Called back, -1 indicates threaded LIST failed
	# We write directly to the control and do not call
	# to allow user to use ...UP... to traverse.

	if (!$is_valid)
	{
		$this->{list_ctrl}->DeleteAllItems();
		my $ctrl = $this->{enabled_ctrl};
		$ctrl->SetLabel("Could not get directory listing");
		$ctrl->SetForegroundColour($color_red);
	}

	# else, got a directory listing

	else
	{
		$this->{enabled} = 0;	# force redraw
		$this->setEnabled(1);
		$this->{got_list} = 1;

		# push the dir_entries onto {hash} and {list}

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

	# if the other pane has the same connection as us
	# update it with our dir_info.

	my $other = $this->{other_pane};
	$other->setContents($dir_info,1) if
		$other &&
		!$from_other &&
		$this->{session}->sameMachineId($other->{session}) &&
		$this->{dir} eq $other->{dir};

}   # setContents



sub populate
    # display the directory listing,
    # comparing it to the other window
{
    my ($this) = @_;
    my $dir = $this->{dir};
    return if !$this->{connected};

    # debug and display title

    display($dbg_pop,0,"Pane$this->{pane_num} populate() dir=$dir");
	display($dbg_pop,1,"Pane$this->{pane_num}  changed ...") if $this->{changed};

    $this->{dir_ctrl}->SetLabel($dir);

    # compare the two lists before displaying

    my $other = $this->compareLists();

	# if the data has changed, fully repopulate the control
    # if the data has not changed, we don't pass in an entry
	# we use the number of items in our list cuz the control
	# might not have any yet

	$this->{list_ctrl}->DeleteAllItems() if $this->{changed};
	if ($this->{list})
	{
		for my $row (0..@{$this->{list}}-1)
		{
			my $use_entry = $this->{changed} ? $this->{list}->[$row]->{entry} : 0;
			$this->setListRow($row,$use_entry);
		}
	}

    # sort the control, which is already optimized

    $this->sortListCtrl();

    # finished

    $this->Refresh();
    $this->{changed} = 0;

}   # populate()



#------------------------------------------------
# Selection Handlers
#------------------------------------------------

sub onDoubleClick
    # {this} is the list control
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
    return if !$this->uiEnabled();

    my $item = $event->GetItem();
    my $index = $item->GetData();
    my $entry = $item->GetText();
    my $info = $this->{list}->[$index];
    my $is_dir = $info->{is_dir};

    display($dbg_sel,1,"Pane$this->{pane_num} onDoubleClick is_dir=$is_dir entry=$entry");

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
			my $other = $this->{other_pane};
            $other->{dir} = $this->{dir};
            $other->setContents();
        }

		$this->{parent}->populate();

    }
    else   # double click on file
    {
        $this->doCommandSelected($COMMAND_XFER);
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

    display($dbg_sel,0,"Pane$this->{pane_num} onItemSelected($index) old=$old_index num=$num_sel");

    if ($num_sel > 1 || $index != $old_index)
    {
        $this->{last_selected_index} = $index;
    }
    else
    {
		display($dbg_sel,0,"Pane$this->{pane_num} calling doRename()");
        $this->doRename();
    }
}


1;
