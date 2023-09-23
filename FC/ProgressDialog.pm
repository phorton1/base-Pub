#!/usr/bin/perl
#--------------------------------------------------
# ProgressDialog
#--------------------------------------------------
# An exapanding progress dialog to allow for additional
# information gained during recursive directory operations.
#
# Initially constructed with the number of top level
# "files and directories" to act upon,  the window includes
# a file progress bar for files that will take more than
# one or two buffers to move to between machines.
#
# The top level bar can actually go backwards, as new
# recursive items are found.  So the top level bar
# range is the total number of things that we know about
# at any time.


package Pub::FC::ProgressDialog;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw( sleep );
use Wx qw(:everything);
use Wx::Event qw(EVT_CLOSE EVT_BUTTON);
use Pub::Utils qw(getAppFrame display);
use base qw(Wx::Dialog);


my $ID_WINDOW = 18000;
my $ID_GUAGE = 18001;
my $ID_CANCEL = 4567;

my $dbg_fpd = 1;


sub new
{
    my ($class,
		$parent,
		$what,
		$num_dirs,
		$num_files) = @_;

	$num_files ||= 0;
	$num_dirs ||= 0;

	display($dbg_fpd,0,"ProgressDialog::new($what,$num_files,$num_dirs)");

	$parent = getAppFrame() if !$parent;
	$parent->Enable(0) if $parent;

    my $this = $class->SUPER::new($parent,$ID_WINDOW,'',[-1,-1],[500,230]);

	$this->{parent} 	= $parent;
	$this->{what} 		= $what;
	$this->{num_dirs} 	= $num_dirs;
	$this->{num_files} 	= $num_files;
	$this->{entry}      = '';
	$this->{aborted}    = 0;
	$this->{files_done} = 0;
	$this->{dirs_done} 	= 0;
	$this->{sub_range}  = 0;
	$this->{sub_done}   = 0;
	$this->{sub_msg}    = '';

	$this->{range}      = $num_files+$num_dirs-1;
	$this->{value}		= 0;

	$this->{what_msg} 	= Wx::StaticText->new($this,-1,$what,	 [20,10],  [170,20]);
	$this->{dir_msg} 	= Wx::StaticText->new($this,-1,'',		 [200,10], [120,20]);
	$this->{file_msg} 	= Wx::StaticText->new($this,-1,'',		 [340,10], [120,20]);
	$this->{entry_msg} 	= Wx::StaticText->new($this,-1,'',		 [20,30],  [470,20]);
    $this->{gauge} 		= Wx::Gauge->new($this,$ID_GUAGE,0,		 [20,60],[455,20]);
	$this->{sub_ctrl} 	= Wx::StaticText->new($this,-1,'', 		 [20,100],[455,20]);
    $this->{sub_gauge} 	= Wx::Gauge->new($this,-1,$num_files+$num_dirs,[20,130],[455,16]);
	$this->{sub_gauge}->Hide();

    Wx::Button->new($this,$ID_CANCEL,'Cancel',[400,170],[60,20]);

    EVT_BUTTON($this,$ID_CANCEL,\&onButton);
    EVT_CLOSE($this,\&onClose);

    $this->Show();
	$this->update();

	display($dbg_fpd,0,"ProgressDialog::new() finished");
    return $this;
}


sub aborted()
{
	my ($this) = @_;
	# $this->update();
		# to try to fix guage problem
	return $this->{aborted};
}

sub onClose
{
    my ($this,$event) = @_;
	display($dbg_fpd,0,"ProgressDialog::onClose()");
    $event->Veto() if !$this->{aborted};
}


sub Destroy
{
	my ($this) = @_;
	display($dbg_fpd,0,"ProgressDialog::Destroy()");
	if ($this->{parent})
	{
		$this->{parent}->Enable(1);
	}
	$this->SUPER::Destroy();
}



sub onButton
{
    my ($this,$event) = @_;
	display($dbg_fpd,0,"ProgressDialog::onButton()");
    $this->{aborted} = 1;
    $event->Skip();
}



#----------------------------------------------------
# update()
#----------------------------------------------------


sub update
{
	my ($this) = @_;
	display($dbg_fpd,0,"ProgressDialog::update()");

	my $num_dirs 	= $this->{num_dirs};
	my $num_files 	= $this->{num_files};
	my $dirs_done 	= $this->{dirs_done};
	my $files_done 	= $this->{files_done};

	my $title = "$this->{what} ";
	$title .= "$num_dirs directories " if $num_dirs;
	$title .= "and " if $num_files && $num_dirs;
	$title .= "$num_files files " if $num_files;

	$this->SetLabel($title);
	$this->{dir_msg}->SetLabel("$dirs_done/$num_dirs dirs") if $num_dirs;
	$this->{file_msg}->SetLabel("$files_done/$num_files files") if $num_files;
	$this->{entry_msg}->SetLabel($this->{entry});

	if ($this->{range} != $num_dirs + $num_files - 1)
	{
		$this->{range} = $num_dirs + $num_files - 1;
		$this->{gauge}->SetRange($this->{range});
	}
	if ($this->{value} != $dirs_done + $files_done)
	{
		$this->{value} = $dirs_done + $files_done;
		$this->{gauge}->SetValue($this->{value});

		# hmmm .. the guage doesn't update till the second call to this method
		# and nothing seeed to make it better (including yields and sleeps here
		# and in other objects).
		#
		# In lieu of figuring out a solution, I decremented the range by one
		# so that it sort of looks right
        #
		# $this->{gauge}->Refresh();
		# $this->{gauge}->Update();
		# $this->Refresh();
		# $this->Update();
        #
		# my $new_event = Wx::CommandEvent->new($ID_GUAGE);
        # $this->AddPendingEvent($new_event);
        #
		# my $new_event2 = Wx::CommandEvent->new($ID_WINDOW);
        # $this->AddPendingEvent($new_event2);
	}

	$this->{sub_ctrl}->SetLabel($this->{sub_msg});

	if ($this->{sub_range})
	{
		$this->{sub_gauge}->SetRange($this->{sub_range});
		$this->{sub_gauge}->SetValue($this->{sub_done});
		$this->{sub_gauge}->Show();
	}
	else
	{
		$this->{sub_gauge}->Hide();
	}

	# yield occasionally

	Wx::App::GetInstance()->Yield();
	# sleep(0.2);
	# Wx::App::GetInstance()->Yield();


	display($dbg_fpd,0,"ProgressDialog::update() finished");

	return !$this->{aborted};
}


#----------------------------------------------------
# UI accessors
#----------------------------------------------------


sub addDirsAndFiles
{
	my ($this,$num_dirs,$num_files,) = @_;
	display($dbg_fpd,0,"addDirsAndFiles($num_dirs,$num_files)");

	$this->{num_dirs} += $num_dirs;
	$this->{num_files} += $num_files;
	return $this->update();
}

sub setEntry
{
	my ($this,$entry) = @_;
	display($dbg_fpd,0,"setEntry($entry)");

	$this->{entry} = $entry;
	return $this->update();
}

sub setDone
{
	my ($this,$is_dir) = @_;
	display($dbg_fpd,0,"setDone($is_dir)");

	$this->{$is_dir ? 'dirs_done' : 'files_done'} ++;
	$this->{sub_range} = 0;
	$this->{sub_msg} = '';
	return $this->update();
}

sub setSubRange
{
	my ($this,$sub_range,$sub_msg) = @_;
	display($dbg_fpd,0,"setSubRange($sub_range,$sub_msg)");

	$this->{sub_done} = 0;
	$this->{sub_msg} = $sub_msg;
	$this->{sub_range} = $sub_range;
	return $this->update();
}

sub updateSubRange
{
	my ($this,$sub_done,$sub_msg) = @_;
	display($dbg_fpd,0,"updateSubRange($sub_msg)");

	$this->{sub_done} = $sub_done;
	$this->{sub_msg} = $sub_msg;
	return $this->update();
}




1;
