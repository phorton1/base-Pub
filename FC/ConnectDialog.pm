#-------------------------------------------------
# Pub::FC::ConnectDialog.pm
#-------------------------------------------------
# Any changes made to the prefs are invariantly saved.
# The Add/Update, Delete, and MoveUp/Down changes are
# accumulated in the {dirty} and the prefs written after
# the dialog closes.
#
# This is different than {edit_dirty} which specifies that
# the connection edit fields are different than the prefs,
# and the Add/Update button should be enabled.
#
# Even is {edit_dirty}, they can still open a window to the
# connection specified by the edit fields, without necessary
# saving them to the prefs. In fact, this window will BEGIN
# with {edit_dirty} if it is activated from such a window.

package Pub::FC::ConnectDialog;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_BUTTON
	EVT_UPDATE_UI_RANGE
	EVT_LIST_ITEM_ACTIVATED
	EVT_KILL_FOCUS
	EVT_IDLE
	EVT_TEXT
	EVT_CHECKBOX);
use Pub::Utils;
use Pub::WX::Dialogs;
use Pub::FC::Prefs;
use Pub::FC::Resources;
use base qw(Wx::Dialog);


my $dbg_dlg = 0;
	# Show main dialog actions
my $dbg_chg = 1;
	# Show details about change event handling
	# and field validation


my $LINE_HEIGHT     = 20;

my $LEFT_COLUMN 			= 20;
my $INDENT_COLUMN 			= 40;
my $NAME_COLUMN 			= 110;
my $RIGHT_COLUMN  			= 300;
my $NAME_WIDTH 				= 160;
my $SESSION_NAME_WIDTH    	= 120;
my $SESSION_RIGHT_COLUMN  	= 260;

my $LIST_WIDTH	= 270;
my $LIST_HEIGHT = 7 * $LINE_HEIGHT;

my ($ID_CONNECT_CONNECTION,
	$ID_UPDATE_CONNECTION,
	$ID_MOVE_UP,
	$ID_MOVE_DOWN,
	$ID_LOAD_SELECTED,
	$ID_DELETE_SELECTED,
	$ID_CONNECT_SELECTED,

	$ID_CTRL_CID,
	$ID_CTRL_AUTO_START,
	$ID_CTRL_DIR0,
	$ID_CTRL_PORT0,
	$ID_CTRL_HOST0,
	$ID_CTRL_DIR1,
	$ID_CTRL_PORT1,
	$ID_CTRL_HOST1, ) = (1000..2000);


my @list_fields = (
    connection  => 90,
    session1 => 90,
    session2 => 90 );



my $title_font = Wx::Font->new(9,wxFONTFAMILY_DEFAULT,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);

# use Data::Dumper;


sub connect()
{
    my ($class,$parent) = @_;
	display($dbg_dlg,0,"ConnectDialog started");
	return if !waitPrefs();

	# Create the dialog

	my $this = $class->SUPER::new(
        $parent,
		-1,
		"Connect",
        [-1,-1],
        [400,520],
        wxDEFAULT_DIALOG_STYLE );

	# Create the controls

	$this->createControls();

	# Event handlers

	EVT_IDLE($this,\&onIdle);
    EVT_BUTTON($this,-1,\&onButton);
	EVT_TEXT($this, -1, \&onTextChanged);
	EVT_CHECKBOX($this, -1, \&onTextChanged);
	EVT_UPDATE_UI_RANGE($this, $ID_CONNECT_CONNECTION, $ID_CONNECT_SELECTED, \&onUpdateUI);
    EVT_LIST_ITEM_ACTIVATED($this->{list_ctrl},-1,\&onDoubleClick);

	EVT_KILL_FOCUS($this->{cid},		\&onValidateCtrl);
	EVT_KILL_FOCUS($this->{auto_start},	\&onValidateCtrl);
	EVT_KILL_FOCUS($this->{sdir0},		\&onValidateCtrl);
	EVT_KILL_FOCUS($this->{port0},		\&onValidateCtrl);
	EVT_KILL_FOCUS($this->{host0},		\&onValidateCtrl);
	EVT_KILL_FOCUS($this->{sdir1},		\&onValidateCtrl);
	EVT_KILL_FOCUS($this->{port1},		\&onValidateCtrl);
	EVT_KILL_FOCUS($this->{host1},		\&onValidateCtrl);

	# Setup the starting information

	my $app_frame = getAppFrame();
	my $pane = $app_frame->getCurrentPane();
	$this->{connection} = $pane ?
		$pane->getWinConnection() :
		defaultConnection();

	# {edit_dirty} is set if there is a connection name
	# and the parameters don't match the prefs for that
	# conneciton name. 'local' and 'buddy' are illegal
	# user defined connection names.

	# print Dumper($this->{connection});

	$this->toControls();
	$this->populateListCtrl();

	# Run the Dialog and write or restore prefs if dirty

	$this->{dirty} = 0;
	$this->{edit_dirty} = 0;
	$this->checkEditDirty();
	my $rslt = $this->ShowModal();
	writePrefs() if $this->{dirty};
	releasePrefs();

	# Start the connection if so directed

	if ($rslt == $ID_CONNECT_CONNECTION)
	{
		display($dbg_dlg,0,"ConnectDialog Conneccting ...");
		$app_frame->createPane($ID_CLIENT_WINDOW,undef,$this->{connection});
	}

	# Remember that dialogs must be destroyed
	# when you are done with them !!!
	$this->Destroy();
}


sub setDirty
{
	my ($this) = @_;
	$this->{dirty} = 1;
}


#-----------------------------------
# event handlers
#-----------------------------------

sub onTextChanged
	# Enable/disable the Add/Update button on every character
{
	my ($this,$event) = @_;
	$this->checkEditDirty();
	$event->Skip();
}


sub onIdle
	# Used to return focus to the {err_ctrl} after onValidateCtrl
{
	my ($this,$event) = @_;
	if ($this->{err_ctrl})
	{
		$this->{err_ctrl}->SetFocus();
		$this->{err_ctrl} = '';
	}
}


sub onValidateCtrl
	# Called from EVT_KILL_FOCUS for any editable fields changing.
	# Show error message and sets {err_ctrl} for any controls in error
{
	my ($ctrl,$event) = @_;
	my $id = $ctrl->GetId() || '';
	my $this = $ctrl->GetParent();

	display($dbg_chg,0,"onKillFocus($id) ctrl=$ctrl this=$this"); #  ctrl_id=$ctrl_id");

	my $value = $ctrl->GetValue();
	if (!$value)	# blank is always allowed
	{
		$event->Skip();
		return;
	}

	if ($id == $ID_CTRL_CID)
	{
		if ($value !~ /^[A-Za-z0-9_\-\.]*$/)
		{
			error("Host may only contain A-Z, a-z, 0-9, dot, underscore, and dash");
			$this->{err_ctrl} = $ctrl;
		}
	}
	elsif ($id == $ID_CTRL_DIR0 || $id == $ID_CTRL_DIR1)
	{
		if ($value !~ /^\//)
		{
			error("Directory must start with '/'");
			$this->{err_ctrl} = $ctrl;
		}
		elsif ($value =~ /[:\\]/)
		{
			# probably has do change when we figure out Win C: versus D:
			error("Directory cannot contain ':' or '\\'");
			$this->{err_ctrl} = $ctrl;
		}
		else
		{
			my @parts = split(/\//,$value);
			for my $part (@parts)
			{
				if ($part eq '.' || $part eq '..')
				{
					error("Cannot use '.' or '..' in directories");
					$this->{err_ctrl} = $ctrl;
					last;
				}
			}
		}
	}
	elsif ($id == $ID_CTRL_PORT0 || $id == $ID_CTRL_PORT1)
	{
		if ($value !~ /^\d+$/)
		{
			error("Port must be a number");
			$this->{err_ctrl} = $ctrl;
		}
	}
	elsif ($id == $ID_CTRL_HOST0 || $id == $ID_CTRL_HOST1)
	{
		if ($value eq 'localhost')
		{
			error("Use '' for localhost");
			$this->{err_ctrl} = $ctrl;

		}
		elsif ($value !~ /^[A-Za-z0-9_\-\.]*$/)
		{
			error("Host may only contain A-Z, a-z, 0-9, dot, underscore, and dash");
			$this->{err_ctrl} = $ctrl;
		}
		elsif ($value =~ /^\.|\.$/ || $value !~ /\./)
		{
			error("Illegal host name");
			$this->{err_ctrl} = $ctrl;
		}
	}

	$event->Skip();
}


sub onDoubleClick
{
	my ($ctrl,$event) = @_;
	my $this = $ctrl->{parent};
    my $item = $event->GetItem();
    my $connection_id = $item->GetText();
	my $connection = getPrefConnection($connection_id);
	if ($connection)
	{
		$this->{connection} = $connection;
		$this->EndModal($ID_CONNECT_CONNECTION);
	}
}


sub onButton
{
    my ($this,$event) = @_;
    my $id = $event->GetId();
    $event->Skip();

	if ($id == $ID_UPDATE_CONNECTION)
	{
		$this->updateConnection();
	}
	elsif ($id == $ID_CONNECT_CONNECTION)
	{
		$this->fromControls();
	    $this->EndModal($id);
	}
	elsif ($id == $ID_DELETE_SELECTED)
	{
		$this->deleteSelected();
	}
	elsif ($id == $ID_CONNECT_SELECTED ||
		   $id == $ID_LOAD_SELECTED )
	{
		my $connection_id = getSelectedItemText($this->{list_ctrl});
		my $connection = getPrefConnection($connection_id,1);
		$this->{connection} = $connection;
		if ($id == $ID_CONNECT_SELECTED)
		{
			$this->EndModal($ID_CONNECT_CONNECTION);
		}
		else
		{
			$this->toControls();
			$this->{edit_dirty} = 0;
		}
	}
	elsif ($id == $ID_MOVE_UP || $id == $ID_MOVE_DOWN)
	{
		my $prefs = getPrefs();
		my $ctrl = $this->{list_ctrl};
		my $idx1 = getSelectedItemIndex($ctrl);
		my $idx2 = ($id == $ID_MOVE_UP) ? $idx1-1 : $idx1+1;
		my $temp = $prefs->{connections}->[$idx1];
		$prefs->{connections}->[$idx1] = $prefs->{connections}->[$idx2];
		$prefs->{connections}->[$idx2] = $temp;

		$this->populateListCtrl();
		$ctrl->SetItemState($idx2,
			wxLIST_STATE_SELECTED,
			wxLIST_STATE_SELECTED);

		$this->setDirty();
	}
}


sub onUpdateUI
{
	my ($this,$event) = @_;
	my $id = $event->GetId();

	# enable buttons by state

	my $enabled = 0;
	my $ctrl = $this->{list_ctrl};

	if ($id == $ID_UPDATE_CONNECTION)
	{
		$enabled = $this->{edit_dirty};
	}
	elsif ($id == $ID_CONNECT_CONNECTION)
	{
		$enabled = 1;
	}
	elsif ($id == $ID_LOAD_SELECTED ||
		   $id == $ID_DELETE_SELECTED ||
           $id == $ID_CONNECT_SELECTED)
	{
		$enabled = 1 if $ctrl->GetSelectedItemCount();
	}
	elsif ($id == $ID_MOVE_UP ||
		   $id == $ID_MOVE_DOWN)
	{
		if ($ctrl->GetSelectedItemCount())
		{
			my $count = $ctrl->GetItemCount();
			my $idx = getSelectedItemIndex($ctrl);
			$enabled = 1 if
				($id == $ID_MOVE_UP && $idx > 0) ||
				($id == $ID_MOVE_DOWN && $idx < $count-1);
		}
	}

    $event->Enable($enabled);
}


#-----------------------------------
# utilities
#-----------------------------------

sub getSelectedItemIndex
{
	my ($ctrl) = @_;
    for (my $i=0; $i<$ctrl->GetItemCount(); $i++)
    {
		return $i
			if $ctrl->GetItemState($i,wxLIST_STATE_SELECTED);
	}
	return -1;
}


sub getSelectedItemText
{
	my ($ctrl) = @_;
	my $idx = getSelectedItemIndex($ctrl);
	return $idx >= 0 ? $ctrl->GetItemText($idx) : '';
}


sub toControls
	# Note that the user is never allowed to actually
	# specify '' for the port, which is used by Sessions
	# to mean "create an arbitrary port", and that when
	# this dialog is populated from an existing connection
	# it receives '0' for the port number. So below we
	# set 0 to blank.
	#
	# 0 or '' means 'local' in the Pane ctor.
{
	my ($this) = @_;

	my $connection = $this->{connection};
	my $params0 = $connection->{params}->[0];
	my $params1 = $connection->{params}->[1];

    $this->{cid} 	   ->ChangeValue($connection->{connection_id});
    $this->{auto_start}->SetValue($connection->{auto_start} || '');
    $this->{sdir0}	   ->ChangeValue($params0->{dir});
    $this->{port0}	   ->ChangeValue($params0->{port} || '');
    $this->{host0}	   ->ChangeValue($params0->{host});
    $this->{sdir1}	   ->ChangeValue($params1->{dir});
    $this->{port1}	   ->ChangeValue($params1->{port} || '');
    $this->{host1}	   ->ChangeValue($params1->{host});
}


sub fromControls
{
	my ($this) = @_;

	my $connection = $this->{connection};
	my $params0 = $connection->{params}->[0];
	my $params1 = $connection->{params}->[1];

    $connection->{connection_id} = $this->{cid} 	  ->GetValue();
    $connection->{auto_start}	 = $this->{auto_start}->GetValue() || '';
    $params0->{dir}				 = $this->{sdir0}	  ->GetValue();
    $params0->{port}			 = $this->{port0}	  ->GetValue() || '';
    $params0->{host}			 = $this->{host0}	  ->GetValue();
    $params1->{dir}				 = $this->{sdir1}	  ->GetValue();
    $params1->{port}			 = $this->{port1}	  ->GetValue() || '';
    $params1->{host}			 = $this->{host1}	  ->GetValue();
}



sub getParamDesc
	# returns what is shown in the params fields of the list_ctrl
{
	my ($params) = @_;
	my $name =
		$params->{host} ? "$params->{host}".
			($params->{port}?":$params->{port}":'') :
		$params->{port} ? "port($params->{port})" :
		"local";
	return $name;
}

sub populateListCtrl
	# Called when prefs change
{
	my ($this) = @_;
	my $ctrl = $this->{list_ctrl};
	$ctrl->DeleteAllItems();

	my $row = 0;
	my $prefs = getPrefs();
	my $connections = $prefs->{connections};
	for my $connection (@$connections)
	{
        $ctrl->InsertStringItem($row,$connection->{connection_id});
		$ctrl->SetItemData($row,$row);
		$ctrl->SetItem($row,1,getParamDesc($connection->{params}->[0]));
		$ctrl->SetItem($row,2,getParamDesc($connection->{params}->[1]));
		$row++;
	}
}



#------------------------------------------------------------
# createControls()
#------------------------------------------------------------

sub createControls
{
	my ($this) = @_;

	# Connection

	my $y = 20;
	my $ctrl = Wx::StaticText->new($this,-1,'Connection',[$LEFT_COLUMN,$y]);
	$ctrl->SetFont($title_font);
    $this->{cid} =  Wx::TextCtrl->new($this,$ID_CTRL_CID,'',[$NAME_COLUMN, $y],[$NAME_WIDTH,20]);
    $ctrl = Wx::Button->new($this,$ID_CONNECT_CONNECTION,'Connect',[$RIGHT_COLUMN,$y],[70,20]);
	$ctrl->SetDefault();
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'AutoStart',[$INDENT_COLUMN,$y]);
    $this->{auto_start} = Wx::CheckBox->new($this,$ID_CTRL_AUTO_START,'',[$NAME_COLUMN,$y+2],[-1,-1]);
	$this->{upd_button} = Wx::Button->new($this,$ID_UPDATE_CONNECTION,'Add',[$RIGHT_COLUMN,$y],[70,20]);
	$y += 2 * $LINE_HEIGHT;

	# Session1

	$ctrl = Wx::StaticText->new($this,-1,'Session1',[$LEFT_COLUMN,$y]);
	$ctrl->SetFont($title_font);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Start Dir',[$INDENT_COLUMN,$y]);
    $this->{sdir0} =  Wx::TextCtrl->new($this,$ID_CTRL_DIR0,'',[$NAME_COLUMN, $y],[$SESSION_NAME_WIDTH,20]);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Port',[$INDENT_COLUMN,$y]);
    $this->{port0} =  Wx::TextCtrl->new($this,$ID_CTRL_PORT0,'',[$NAME_COLUMN, $y],[80,20]);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Host',[$INDENT_COLUMN,$y]);
    $this->{host0} =  Wx::TextCtrl->new($this,$ID_CTRL_HOST0,'',[$NAME_COLUMN, $y],[$SESSION_NAME_WIDTH,20]);
	$y += 2 * $LINE_HEIGHT;


	# Session2

	$ctrl = Wx::StaticText->new($this,-1,'Session2',[$LEFT_COLUMN,$y]);
	$ctrl->SetFont($title_font);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Start Dir',[$INDENT_COLUMN,$y]);
    $this->{sdir1} =  Wx::TextCtrl->new($this,$ID_CTRL_DIR1,'',[$NAME_COLUMN, $y],[$SESSION_NAME_WIDTH,20]);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Port',[$INDENT_COLUMN,$y]);
    $this->{port1} =  Wx::TextCtrl->new($this,$ID_CTRL_PORT1,'',[$NAME_COLUMN, $y],[80,20]);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Host',[$INDENT_COLUMN,$y]);
    $this->{host1} =  Wx::TextCtrl->new($this,$ID_CTRL_HOST1,'',[$NAME_COLUMN, $y],[$SESSION_NAME_WIDTH,20]);
	$y += 2 * $LINE_HEIGHT;

	# List Control

	$ctrl = Wx::StaticText->new($this,-1,'Pre-defined Connections',[$LEFT_COLUMN,$y]);
	$ctrl->SetFont($title_font);
	$y += $LINE_HEIGHT;

    $ctrl = Wx::ListCtrl->new(
        $this,-1,[$LEFT_COLUMN,$y],[$LIST_WIDTH,$LIST_HEIGHT],
        wxLC_REPORT | wxLC_SINGLE_SEL ); #  | wxLC_EDIT_LABELS);
    $ctrl->{parent} = $this;
	$this->{list_ctrl} = $ctrl;

    for my $i (0..(scalar(@list_fields)/2)-1)
    {
        my ($field,$width) = ($list_fields[$i*2],$list_fields[$i*2+1]);
        $ctrl->InsertColumn($i,$field,wxLIST_FORMAT_LEFT,$width);
    }

	# List Control Buttons

	$ctrl = Wx::Button->new($this,$ID_CONNECT_SELECTED,'Connect',[$RIGHT_COLUMN,$y],[70,20]);
	$y += 2*$LINE_HEIGHT;

	$ctrl = Wx::Button->new($this,$ID_MOVE_UP,'^',[$RIGHT_COLUMN,$y],[70,20]);
	$y += $LINE_HEIGHT;
	$ctrl = Wx::Button->new($this,$ID_LOAD_SELECTED,'Load',[$RIGHT_COLUMN,$y],[70,20]);
	$y += $LINE_HEIGHT;
	$ctrl = Wx::Button->new($this,$ID_DELETE_SELECTED,'Delete',[$RIGHT_COLUMN,$y],[70,20]);
	$y += $LINE_HEIGHT;
	$ctrl = Wx::Button->new($this,$ID_MOVE_DOWN,'v',[$RIGHT_COLUMN,$y],[70,20]);
	$y += $LINE_HEIGHT;

	# Cancel Button

	$y += 1.75*$LINE_HEIGHT;
	$ctrl = Wx::Button->new($this,wxID_CANCEL,'Close',[$RIGHT_COLUMN,$y],[70,20]);
}


sub checkEditDirty
	# Sets {edit_dirty} if the edit fields are 'saveable'
	# They are not saveable if they dont have a cid, or
	# if everything matches an existing prefConnection of
	# the given cid.
{
	my ($this) = @_;
	my $edit_dirty = 0;
    my $cid = $this->{cid}->GetValue();
	my $shows_add = $this->{upd_button}->GetLabel() eq 'Add' ? 1 : 0;

	display($dbg_chg,0,"checkEditDirty($cid)");

	if ($cid)	# without a CID it cannot be saved
	{
		my $prefs = getPrefs();
		my $connection = $prefs->{connectionById}->{$cid};

		if (!$connection)		# no connection of this cid exists
		{
			display($dbg_chg,1,"no connection($cid)");
			$edit_dirty = 1;	# so it is saveable by definition
			$this->{upd_button}->SetLabel('Add') if !$shows_add;
		}
		else
		{
			$this->{upd_button}->SetLabel('Update') if $shows_add;
			my $auto_start = $this->{auto_start}->GetValue() ? 1 :  '';
			if ($connection->{auto_start} ne $auto_start)
			{
				display($dbg_chg,1,"auto_start($connection->{auto_start} ne $auto_start");
				$edit_dirty = 1;	# auto_start is different
			}
			else	# check to see if any fields are different
			{
				my @triplets = (
					[ qw(0 dir 	    sdir0) ],
					[ qw(0 port 	port0) ],
					[ qw(0 host 	host0) ],
					[ qw(1 dir 	    sdir1) ],
					[ qw(1 port 	port1) ],
					[ qw(1 host 	host1) ] );
				for my $trip (@triplets)
				{
					my $val1 = $connection->{params}->[$trip->[0]]->{$trip->[1]} || '';
					my $val2 = $this->{$trip->[2]}->GetValue() || '';
					if ($val1 ne $val2)
					{
						display($dbg_chg,1,"params($trip->[0],$trip->[1],$val1) ne ctrl($trip->[2],$val2)");
						$edit_dirty = 1;
						last;
					}
				}
			}
		}
	}

	$this->{edit_dirty} = $edit_dirty;
}



sub updateConnection
	# Add or Update the prefs connections from
	# the edit fields
{
	my ($this) = @_;

	$this->fromControls();

	my $prefs = getPrefs();
	my $conn = $this->{connection};
	my $cid = $conn->{connection_id};
	my $exists = $prefs->{connectionById}->{$cid};

	if ($cid eq 'buddy' || $cid eq 'local')
	{
		error("Cannot save 'buddy' or 'local' as a connection_id");
		return;
	}


	return if $exists && !yesNoDialog($this,
		"Overwrite existing connection '$cid'?",
		"Overwrite Connection $cid");
	if ($exists)
	{
		$exists->{auto_start} = $conn->{auto_start} || '';
		$exists->{params}->[0] = shared_clone($conn->{params}->[0]);
		$exists->{params}->[1] = shared_clone($conn->{params}->[1]);
	}
	else
	{
		my $new = shared_clone({
			connection_id => $cid,
			auto_start => $conn->{auto_start} || '',
			params => shared_clone([
				shared_clone($conn->{params}->[0]),
				shared_clone($conn->{params}->[1]) ]) });
		unshift @{$prefs->{connections}},$new;
		$prefs->{connectionById}->{$cid} = $new;
	}

	$this->setDirty();
	$this->{edit_dirty} = 0;
	$this->populateListCtrl();
}


sub deleteSelected
	# delete the selected connection
{
	my ($this) = @_;
	my $prefs = getPrefs();
	my $conns = $prefs->{connections};
	my $cid = getSelectedItemText($this->{list_ctrl});
	display($dbg_dlg,0,"deleteSelected($cid)");

	return if !yesNoDialog($this,
		"Delete connection '$cid' ??",
		"Delete Connection $cid");

	delete $prefs->{connectionById}->{$cid};

	$prefs->{connections} = shared_clone([]);
	for my $conn (@$conns)
	{
		push @{$prefs->{connections}},$conn
			if $conn->{connection_id} ne $cid;
	}

	$this->setDirty();
	$this->populateListCtrl();
	$this->checkEditDirty();
}


1;
