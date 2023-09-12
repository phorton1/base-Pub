#!/usr/bin/perl
#--------------------------------------------------
# fileProgressDialog
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


package Pub::FS::fileProgressDialog;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_CLOSE EVT_BUTTON);
use Pub::Utils qw(getAppFrame display);
use base qw(Wx::Dialog);


my $ID_CANCEL = 4567;

my $dbg_fpd = 1;


sub new
{
    my ($class,
		$parent,
		$what,
		$num_files,
		$num_dirs ) = @_;

	display($dbg_fpd,0,"fileProgressDialog::new($what,$num_files,$num_dirs)");

	$parent = getAppFrame() if !$parent;
	$parent->Enable(0) if $parent;

    my $this = $class->SUPER::new($parent,-1,'',[-1,-1],[500,230]);

	$this->{parent} 	= $parent;
	$this->{what} 		= $what;
	$this->{num_files} 	= $num_files;
	$this->{num_dirs} 	= $num_dirs;
	$this->{entry}      = '';
	$this->{cancelled}  = 0;
	$this->{files_done} = 0;
	$this->{dirs_done} 	= 0;
	$this->{sub_range}  = 0;
	$this->{sub_done}   = 0;
	$this->{sub_msg}    = '';

	$this->{what_msg} 	= Wx::StaticText->new($this,-1,$what,	[20,10],  [170,20]);
	$this->{file_msg} 	= Wx::StaticText->new($this,-1,'',		[200,10], [120,20]);
	$this->{dir_msg} 	= Wx::StaticText->new($this,-1,'',		[340,10], [120,20]);
	$this->{entry_msg} 	= Wx::StaticText->new($this,-1,'',		[20,30],  [470,20]);
    $this->{gauge} 		= Wx::Gauge->new($this,-1,$num_files+$num_dirs,[20,60],[455,20]);
	$this->{sub_ctrl} 	= Wx::StaticText->new($this,-1,'',[20,100],[455,20]);
    $this->{sub_gauge} 	= Wx::Gauge->new($this,-1,$num_files+$num_dirs,[20,130],[455,16]);
	$this->{sub_gauge}->Hide();

    Wx::Button->new($this,$ID_CANCEL,'Cancel',[400,170],[60,20]);

    EVT_BUTTON($this,$ID_CANCEL,\&onButton);
    EVT_CLOSE($this,\&onClose);

    $this->Show();
	$this->update();

	display($dbg_fpd,0,"fileProgressDialog::new() finished");
    return $this;
}



sub onClose
{
    my ($this,$event) = @_;
	display($dbg_fpd,0,"fileProgressDialog::onClose()");
    $event->Veto() if !$this->{cancelled};
}


sub Destroy
{
	my ($this) = @_;
	display($dbg_fpd,0,"fileProgressDialog::Destroy()");
	if ($this->{parent})
	{
		$this->{parent}->Enable(1);
	}
	$this->SUPER::Destroy();
}



sub onButton
{
    my ($this,$event) = @_;
	display($dbg_fpd,0,"fileProgressDialog::onButton()");
    $this->{cancelled} = 1;
    $event->Skip();
}



#----------------------------------------------------
# update()
#----------------------------------------------------


sub update
{
	my ($this) = @_;
	display($dbg_fpd,0,"fileProgressDialog::update()");

	my $num_files 	= $this->{num_files};
	my $num_dirs 	= $this->{num_dirs};
	my $files_done 	= $this->{files_done};
	my $dirs_done 	= $this->{dirs_done};

	my $title = "$this->{what} ";
	$title .= "$num_files files " if $num_files;
	$title .= "and " if $num_files && $num_dirs;
	$title .= "$num_dirs directories " if $num_dirs;

	$this->SetLabel($title);
	$this->{file_msg}->SetLabel("$files_done/$num_files files") if $num_files;
	$this->{dir_msg}->SetLabel("$dirs_done/$num_dirs dirs") if $num_dirs;
	$this->{entry_msg}->SetLabel($this->{entry});

	$this->{gauge}->SetRange($num_files + $num_dirs);
	$this->{gauge}->SetValue($files_done + $dirs_done);

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

	Wx::App::GetInstance()->Yield();
	display($dbg_fpd,0,"fileProgressDialog::update() finished");

	return !$this->{cancelled};
}


#----------------------------------------------------
# UI accessors
#----------------------------------------------------


sub addFilesAndDirs
{
	my ($this,$num_files,$num_dirs) = @_;
	display($dbg_fpd,0,"addFilesAndDirs($num_files,$num_dirs)");

	$this->{num_files} += $num_files;
	$this->{num_dirs} += $num_dirs;
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
