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
use Pub::Utils qw(getAppFrame display warning);
use base qw(Wx::Dialog);


my $ID_WINDOW = 18000;
my $ID_CANCEL = 4567;

my $dbg_fpd = 1;


sub new
{
    my ($class,
		$parent,
		$command,
		$num_dirs,
		$num_files) = @_;

	$num_files ||= 0;
	$num_dirs ||= 0;

	display($dbg_fpd,0,"ProgressDialog::new($command,$num_files,$num_dirs)");

	$parent = getAppFrame() if !$parent;
	$parent->Enable(0) if $parent;

    my $this = $class->SUPER::new($parent,$ID_WINDOW,'',[-1,-1],[500,200]);

	$this->{parent} 	= $parent;
	$this->{command} 	= $command;
	$this->{num_dirs} 	= $num_dirs;
	$this->{num_files} 	= $num_files;
	$this->{entry}      = '';
	$this->{aborted}    = 0;
	$this->{files_done} = 0;
	$this->{dirs_done} 	= 0;
	$this->{byte_range} = 0;
	$this->{bytes_done} = 0;

	$this->{range}      = $num_files + $num_dirs;
	$this->{value}		= 0;

	$this->{command_msg}= Wx::StaticText->new($this,-1,$command, [20,10],  [170,20]);
	$this->{dir_msg} 	= Wx::StaticText->new($this,-1,'',		 [200,10], [120,20]);
	$this->{file_msg} 	= Wx::StaticText->new($this,-1,'',		 [340,10], [120,20]);
	$this->{entry_msg} 	= Wx::StaticText->new($this,-1,'',		 [20,30],  [470,20]);
    $this->{gauge} 		= Wx::Gauge->new($this,-1,0,		 	 [20,60],  [455,20]);
	$this->{bytes_msg} 	= Wx::StaticText->new($this,-1,'',		 [20,90],  [140,20]);
    $this->{byte_guage} = Wx::Gauge->new($this,-1,0,			 [150,90], [325,20]);
	$this->{bytes_msg}->Hide();
	$this->{byte_guage}->Hide();

    Wx::Button->new($this,$ID_CANCEL,'Cancel',[400,130],[60,20]);

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
	warning($dbg_fpd-1,0,"ProgressDialog::ABORTING");
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

	my $title = "$this->{command} ";
	$title .= "$num_dirs directories " if $num_dirs;
	$title .= "and " if $num_files && $num_dirs;
	$title .= "$num_files files " if $num_files;

	$this->SetLabel($title);
	$this->{dir_msg}->SetLabel("$dirs_done/$num_dirs dirs") if $num_dirs;
	$this->{file_msg}->SetLabel("$files_done/$num_files files") if $num_files;
	$this->{entry_msg}->SetLabel($this->{entry});

	if ($this->{range} != $num_dirs + $num_files)
	{
		$this->{range} = $num_dirs + $num_files;
		$this->{gauge}->SetRange($this->{range});
	}
	if ($this->{value} != $dirs_done + $files_done)
	{
		$this->{value} = $dirs_done + $files_done;
		$this->{gauge}->SetValue($this->{value});
	}

	if ($this->{byte_range})
	{
		$this->{bytes_msg}->SetLabel("$this->{bytes_done}/$this->{byte_range}");
		$this->{byte_guage}->SetRange($this->{byte_range});
		$this->{byte_guage}->SetValue($this->{bytes_done});
		$this->{byte_guage}->Show();
		$this->{bytes_msg}->Show();
	}
	else
	{
		$this->{byte_guage}->Hide();
		$this->{bytes_msg}->Hide();
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
	my ($this,$entry,$size) = @_;
	$size ||= 0;
	display($dbg_fpd,0,"setEntry($entry,$size)");
	$this->{entry} = $entry;
	$this->{byte_range} = $size;
	$this->{bytes_done} = 0;
	return $this->update();
}

sub setDone
{
	my ($this,$is_dir) = @_;
	display($dbg_fpd,0,"setDone($is_dir)");
	$this->{$is_dir ? 'dirs_done' : 'files_done'} ++;
	$this->{byte_range} = 0;
	$this->{bytes_done} = 0;
	return $this->update();
}

sub setBytes
{
	my ($this,$bytes) = @_;
	display($dbg_fpd,0,"setBytes($bytes)");
	$this->{bytes_done} = $bytes;
	return $this->update();
}




1;
