#-------------------------------------------------
# Pub::FC::ConnectDialog.pm
#-------------------------------------------------

use lib '/base';

package Pub::FC::ConnectDialog;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_BUTTON
	EVT_UPDATE_UI_RANGE
	EVT_LIST_ITEM_ACTIVATED);
use Pub::Utils;
use Pub::FC::Prefs;
use Pub::FC::Resources;
use base qw(Wx::Dialog);


my $dbg_dlg = 1;


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

my $ID_CONNECT_CONNECTION 	= 1001;
my $ID_SAVE_CONNECTION 		= 1002;

my $ID_MOVE_UP 				= 1031;
my $ID_MOVE_DOWN			= 1032;
my $ID_LOAD_SELECTED    	= 1041;
my $ID_CONNECT_SELECTED  	= 1042;


my @list_fields = (
    connection  => 120,
    session1 => 75,
    session2 => 75 );



my $title_font = Wx::Font->new(9,wxFONTFAMILY_DEFAULT,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);

# use Data::Dumper;


sub connect()
{
    my ($class,$parent) = @_;
	display($dbg_dlg,0,"ConnectDialog::connect()");
	return if !waitPrefs();

	# Create the dialog

	my $this = $class->SUPER::new(
        $parent,
		-1,
		"Connect",
        [-1,-1],
        [400,540],
        wxDEFAULT_DIALOG_STYLE );

	# Create the controls

	$this->createControls();

	# Event handlers

    EVT_BUTTON($this,-1,\&onButton);
	EVT_UPDATE_UI_RANGE($this, $ID_CONNECT_CONNECTION, $ID_CONNECT_SELECTED, \&onUpdateUI);
    EVT_LIST_ITEM_ACTIVATED($this->{list_ctrl},-1,\&onDoubleClick);

	# Setup the starting information

	my $app_frame = getAppFrame();
	my $pane = $app_frame->getCurrentPane();
	$this->{connection} = $pane ?
		$pane->getWinConnection() :
		defaultConnection();

	# print Dumper($this->{connection});

	$this->toControls();
	$this->populateListCtrl();

	# Run the Dialog and release the prefs

	my $rslt = $this->ShowModal();
	releasePrefs();

	# Start the connection if so directed

	if ($rslt == $ID_CONNECT_CONNECTION)
	{
		$app_frame->createPane($ID_CLIENT_WINDOW,undef,$this->{connection});
	}

	# Remember that dialogs must be destroyed
	# when you are done with them !!!
	$this->Destroy();
}


#-----------------------------------
# event handlers
#-----------------------------------

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

	if ($id == $ID_CONNECT_CONNECTION)
	{
		$this->fromControls();
	    $this->EndModal($id);
	}
	elsif ($id == $ID_CONNECT_SELECTED ||
		   $id == $ID_LOAD_SELECTED )
	{
		my $connection_id = getSelectedItem($this->{list_ctrl});
		my $connection = getPrefConnection($connection_id,1);
		if ($connection)
		{
			$this->{connection} = $connection;
			$id == $ID_CONNECT_SELECTED ?
				$this->EndModal($ID_CONNECT_CONNECTION) :
				$this->toControls();
		}
	}
}


sub onUpdateUI
{
	my ($this,$event) = @_;
	my $id = $event->GetId();

	my $prefs = getPrefs();
	my $sessions = $prefs->{sessions};

	my $enabled = 0;

	$enabled = 1 if $id == $ID_CONNECT_CONNECTION;

	$enabled = 1 if $this->{list_ctrl}->GetSelectedItemCount() && (
		$id == $ID_MOVE_UP ||
        $id == $ID_MOVE_DOWN ||
        $id == $ID_LOAD_SELECTED ||
        $id == $ID_CONNECT_SELECTED );

    $event->Enable($enabled);
}


#-----------------------------------
# utilities
#-----------------------------------

sub getSelectedItem
{
	my ($ctrl) = @_;
    for (my $i=0; $i<$ctrl->GetItemCount(); $i++)
    {
		return $ctrl->GetItemText($i)
			if $ctrl->GetItemState($i,wxLIST_STATE_SELECTED);
	}
	return '';
}


sub toControls
{
	my ($this) = @_;

	my $connection = $this->{connection};
	my $params0 = $connection->{params}->[0];
	my $params1 = $connection->{params}->[1];

    $this->{cid} 	   ->SetValue($connection->{connection_id});
    $this->{auto_start}->SetValue($connection->{auto_start});
    $this->{sdir0}	   ->SetValue($params0->{dir});
    $this->{port0}	   ->SetValue($params0->{port});
    $this->{host0}	   ->SetValue($params0->{host});
    $this->{sdir1}	   ->SetValue($params1->{dir});
    $this->{port1}	   ->SetValue($params1->{port});
    $this->{host1}	   ->SetValue($params1->{host});
}


sub fromControls
{
	my ($this) = @_;

	my $connection = $this->{connection};
	my $params0 = $connection->{params}->[0];
	my $params1 = $connection->{params}->[1];

    $connection->{connection_id} = $this->{cid} 	  ->GetValue();
    $connection->{auto_start}	 = $this->{auto_start}->GetValue();
    $params0->{dir}				 = $this->{sdir0}	  ->GetValue();
    $params0->{port}			 = $this->{port0}	  ->GetValue();
    $params0->{host}			 = $this->{host0}	  ->GetValue();
    $params1->{dir}				 = $this->{sdir1}	  ->GetValue();
    $params1->{port}			 = $this->{port1}	  ->GetValue();
    $params1->{host}			 = $this->{host1}	  ->GetValue();
}



sub getParamDesc
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
	# only called when list changes
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
    $this->{cid} =  Wx::TextCtrl->new($this,-1,'',[$NAME_COLUMN, $y],[$NAME_WIDTH,20]);
    $ctrl = Wx::Button->new($this,$ID_CONNECT_CONNECTION,'Connect',[$RIGHT_COLUMN,$y],[70,20]);
	$ctrl->SetDefault();
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'AutoStart',[$INDENT_COLUMN,$y]);
    $this->{auto_start} = Wx::CheckBox->new($this,-1,'',[$NAME_COLUMN,$y+2],[-1,-1]);
	$ctrl = Wx::Button->new($this,$ID_SAVE_CONNECTION,'Save',[$RIGHT_COLUMN,$y],[70,20]);
	$y += 2 * $LINE_HEIGHT;

	# Session1

	$ctrl = Wx::StaticText->new($this,-1,'Session1',[$LEFT_COLUMN,$y]);
	$ctrl->SetFont($title_font);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Start Dir',[$INDENT_COLUMN,$y]);
    $this->{sdir0} =  Wx::TextCtrl->new($this,-1,'',[$NAME_COLUMN, $y],[$SESSION_NAME_WIDTH,20]);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Port',[$INDENT_COLUMN,$y]);
    $this->{port0} =  Wx::TextCtrl->new($this,-1,'',[$NAME_COLUMN, $y],[80,20]);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Host',[$INDENT_COLUMN,$y]);
    $this->{host0} =  Wx::TextCtrl->new($this,-1,'',[$NAME_COLUMN, $y],[$SESSION_NAME_WIDTH,20]);
	$y += 2 * $LINE_HEIGHT;


	# Session2

	$ctrl = Wx::StaticText->new($this,-1,'Session2',[$LEFT_COLUMN,$y]);
	$ctrl->SetFont($title_font);
    $this->{sid2} =  Wx::TextCtrl->new($this,-1,'',[$NAME_COLUMN, $y],[$SESSION_NAME_WIDTH,20]);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Start Dir',[$INDENT_COLUMN,$y]);
    $this->{sdir1} =  Wx::TextCtrl->new($this,-1,'',[$NAME_COLUMN, $y],[$SESSION_NAME_WIDTH,20]);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Port',[$INDENT_COLUMN,$y]);
    $this->{port1} =  Wx::TextCtrl->new($this,-1,'',[$NAME_COLUMN, $y],[80,20]);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Host',[$INDENT_COLUMN,$y]);
    $this->{host1} =  Wx::TextCtrl->new($this,-1,'',[$NAME_COLUMN, $y],[$SESSION_NAME_WIDTH,20]);
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

	$ctrl = Wx::Button->new($this,$ID_MOVE_DOWN,'v',[$RIGHT_COLUMN,$y],[70,20]);
	$y += $LINE_HEIGHT;

	# Cancel Button

	$y += 1.5*$LINE_HEIGHT;
	$ctrl = Wx::Button->new($this,wxID_CANCEL,'Cancel',[$RIGHT_COLUMN,$y],[70,20]);
}


1;
