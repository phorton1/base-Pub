#-------------------------------------------------
# Pub::FC::PrefsDialog.pm
#-------------------------------------------------
# A dialog for editing the (few) 'global' preferences
# that are not 'connections'.  See Prefs.cpp for details.

package Pub::FC::PrefsDialog;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_BUTTON
	EVT_UPDATE_UI_RANGE
	EVT_IDLE);
use Pub::Utils;
use Pub::FC::Prefs;
# use Pub::FC::Resources;
use base qw(Wx::Dialog);


my $dbg_dlg = 0;
	# Show main dialog actions


my $LINE_HEIGHT     = 20;

my $LEFT_COLUMN 	= 20;
my $NAME_COLUMN 	= 140;
my $CHECKBOX_COLUMN = 200;
my $RIGHT_COLUMN  	= 300;
my $NAME_WIDTH 		= 210;


my ($ID_SAVE,

	$ID_CTRL_RESTORE_STARTUP,
	$ID_CTRL_DEF_LOCAL_DIR,
	$ID_CTRL_DEF_REMOTE_DIR, ) = (1000..2000);


sub editPrefs()
{
    my ($class,$parent) = @_;
	display($dbg_dlg,0,"PrefsDialog started");
	return if !waitPrefs();
		# I don't know how much I like this scheme.
		# Might just be 'first come first served' with only a
		# local semaphore to stop the dt loop ...

	# Create the dialog

	my $this = $class->SUPER::new(
        $parent,
		-1,
		"Preferences",
        [-1,-1],
        [400,170],
        wxDEFAULT_DIALOG_STYLE );

	my $y = 10;
	$this->{save_button} = Wx::Button->new($this,$ID_SAVE,'Save',[$RIGHT_COLUMN,$y],[70,20]);
	$y += $LINE_HEIGHT;

	my $ctrl = Wx::StaticText->new($this,-1,'Restore Windows at Startup',[$LEFT_COLUMN,$y]);
    $this->{restore_startup} = Wx::CheckBox->new($this,$ID_CTRL_RESTORE_STARTUP,'',[$CHECKBOX_COLUMN,$y+2],[-1,-1]);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Default Local Dir',[$LEFT_COLUMN,$y]);
    $this->{default_local_dir} =  Wx::TextCtrl->new($this,$ID_CTRL_DEF_LOCAL_DIR,'',[$NAME_COLUMN, $y],[$NAME_WIDTH,20]);
	$y += $LINE_HEIGHT;

	$ctrl = Wx::StaticText->new($this,-1,'Default Remote Dir',[$LEFT_COLUMN,$y]);
    $this->{default_remote_dir} =  Wx::TextCtrl->new($this,$ID_CTRL_DEF_REMOTE_DIR,'',[$NAME_COLUMN, $y],[$NAME_WIDTH,20]);
	$y += 2 * $LINE_HEIGHT;

	$ctrl = Wx::Button->new($this,wxID_CANCEL,'Cancel',[$RIGHT_COLUMN,$y],[70,20]);

	# Event handlers

	EVT_IDLE($this,\&onIdle);
    EVT_BUTTON($this,-1,\&onButton);
	EVT_UPDATE_UI_RANGE($this, $ID_SAVE, $ID_SAVE, \&onUpdateUI);

	# Run the Dialog and write or restore prefs if dirty

	$this->{dirty} = 0;
	$this->toControls();
	my $rslt = $this->ShowModal();
	writePrefs() if $rslt == $ID_SAVE && $this->{dirty};
	releasePrefs();

	$this->Destroy();
}


#-----------------------------------
# event handlers
#-----------------------------------

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


sub onButton
{
    my ($this,$event) = @_;
    my $id = $event->GetId();
	if ($id == $ID_SAVE)	# only button
	{
		if ($this->validateDirectory($this->{default_local_dir}) &&
			$this->validateDirectory($this->{default_remote_dir}))
		{
			$this->fromControls();
			$this->EndModal($ID_SAVE);
		}
	}
    $event->Skip();
}


sub onUpdateUI
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	my $enabled = 0;

	if ($id == $ID_SAVE)	# only button
	{
		my $prefs = getPrefs();
		my $restore_startup = $this->{restore_startup}->GetValue() || '';
		$enabled = $this->{dirty} =
			($prefs->{restore_startup} ne $restore_startup) ||
			($prefs->{default_local_dir} ne $this->{default_local_dir}->GetValue()) ||
			($prefs->{default_remote_dir} ne $this->{default_remote_dir}->GetValue());
	}
    $event->Enable($enabled);
}



#-----------------------------------
# utilities
#-----------------------------------


sub validateDirectory
{
	my ($this,$ctrl) = @_;
	my $value = $ctrl->GetValue();
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
	return !$this->{err_ctrl};
}


sub toControls
{
	my ($this) = @_;
	my $prefs = getPrefs();
    $this->{restore_startup}->SetValue($prefs->{restore_startup} || '');
    $this->{default_local_dir}->ChangeValue($prefs->{default_local_dir});
    $this->{default_remote_dir}->ChangeValue($prefs->{default_remote_dir});
}


sub fromControls
{
	my ($this) = @_;
	my $prefs = getPrefs();
    $prefs->{restore_startup} = $this->{restore_startup}->GetValue() || '';
    $prefs->{default_local_dir} = $this->{default_local_dir}->GetValue();
    $prefs->{default_remote_dir} = $this->{default_remote_dir}->GetValue();
}



1;
