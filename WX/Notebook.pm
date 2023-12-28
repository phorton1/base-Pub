#!/usr/bin/perl
#-------------------------------------------------------------------------
# Pub::WX::Notebook
#-------------------------------------------------------------------------
# A Pub::WX::Notebook is a container (control) that holds Pub::WX::Windows,
# and which presents a tab bar at the top.
#
# It is derived from a Wx::AuiNotebook, which is turn derived from
# Wx::Control, which is basically just a window.
#
# There is a one to one relationship between a Pub::WX::Notebook is and
# a Pub::WX::Frame or Pub::WX::FloatingFrame, both of which are derived
# from Pub::WX::Frame and Pub::WX::FrameBase. Pub::WX::FrameBase
# is derived from Wx::EventHandler, and provides a common object that
# gives each frame in our system a Wx::AuiManager and a Pub::WX::Notebook.
#
# The Pub::WX::Frame is special in that has a system menu, contains
# functionality, but most importantly, structurally, it keeps hashes
# and a hash by instance, {frames}, of all the Pub::WX::FloatingFrames,
# and a list of all the Pub::WX::Windows in the entire system.


package Pub::WX::Notebook;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::AUI;
use Wx::Event qw(
	EVT_AUINOTEBOOK_DRAG_DONE
	EVT_CHILD_FOCUS
	EVT_AUINOTEBOOK_PAGE_CLOSE
	EVT_AUINOTEBOOK_ALLOW_DND
	EVT_AUINOTEBOOK_PAGE_CHANGING
	EVT_AUINOTEBOOK_PAGE_CHANGED );
use JSON;
use Error qw(:try);
use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::AppConfig;
use base 'Wx::AuiNotebook';


#sub CLONE_SKIP { 1 };
	# putting this in a package prevents it from being cloned
	# when the perl interpreter is copied to a new thread, so that
	# the DESTROY methods are not when the thread exits


my $dbg_nb = -2;
	# 0 = show minimal notebook lifecycle
	# -1 = show operations
my $dbg_sr = 1;
	# 0 = show everything


sub new
{
	my ($class,$app_frame,$float_frame) = @_;
	$float_frame ||= '';
 	warning($dbg_nb,0,"Notebook::new() float_frame=$float_frame");

	# create the notebook

	my $frame = $float_frame ? $float_frame : $app_frame;
	my $this = $class->SUPER::new( $frame, -1, [-1, -1], [300, 300],
		wxAUI_NB_TAB_SPLIT |
		wxAUI_NB_TAB_EXTERNAL_MOVE |
		wxAUI_NB_SCROLL_BUTTONS |
		wxAUI_NB_CLOSE_ON_ACTIVE_TAB |
		wxAUI_NB_TAB_MOVE );

	$this->{frame} = $frame;
    $this->{app_frame} = $app_frame;
	$this->{is_floating} = $float_frame;
	$this->{manager} = $frame->{manager};

	# add it to the aui manager

	my $pane = Wx::AuiPaneInfo->new
		->Name('blah')
		->Row(1)
		->Position(1)
		->CenterPane
		->Dockable
		->Floatable
		->Movable
		->Resizable
		->CloseButton
		->MinimizeButton;

	$this->{manager}->AddPane($this, $pane);
	$this->{manager}->Update();

	# register event handlers

	EVT_AUINOTEBOOK_DRAG_DONE($this, -1, \&onAuiDragDone);
	EVT_AUINOTEBOOK_ALLOW_DND($this, -1, \&onAuiAllowDND);
	EVT_AUINOTEBOOK_PAGE_CLOSE($this, -1, \&onAuiPageClose);
	EVT_AUINOTEBOOK_PAGE_CHANGED($this,-1,\&onPageChanged);
	EVT_CHILD_FOCUS($this,\&onChildFocus);

	# return to caller

 	display($dbg_nb,0,"Notebook() returning $this");
	return $this;

}	# Pub::WX::Notebook::new()


#---------------------------------------------
# methods
#---------------------------------------------

sub GetPage
{
	my ($this,$idx) = @_;
	my $rslt = $this->SUPER::GetPage($idx);
	return $rslt;
}


sub selfOrChildOf
{
	my ($hbook,$hwin) = @_;
	while ($hwin)
	{
		return 1 if ($hbook == $hwin);
		$hwin = Win32::GuiTest::GetParent($hwin);
	}
	return 0;
}


sub closeFloatingSelf
	# called on floating frames when the notebook closes it's last pane.
{
	my ($this) = @_;
	my $app_frame = $this->{app_frame};
	display($dbg_nb+1,0,"closeFloatingSelf($this)");
	my $frame = $this->{frame};
	if (!$frame)
	{
		error("floating notebook without a parent frame??");
		return;
	}
	$frame->Close();
	display($dbg_nb+1,0,"closeFloatingSelf($this,$frame) finished");
}




sub closeBookPage
	# only called from Pub::Wx::Frame::closeWindows() and
	# 	Pub::Wx::Window::closeSelf()
	# Is intenionally separated from on onAuiPageClose which
	# 	(a) will Delete() the page upon return and
	# 	(b) will crash if we Delete() the page out from under it
	# Closes the notebook if this is the last page
{
    my ($this,$page) = @_;
    my $idx = $this->GetPageIndex($page);
	display($dbg_nb+1,0,"closeBookPage($idx,$page)");
	$page->Close();
    $this->DeletePage($idx);
	$this->closeFloatingSelf() if
		$this->{is_floating} &&
		!$this->GetPageCount();
    display($dbg_nb+1,0,"closeBookPage() finished");
}


#--------------------------------------
# Event Handlers
#--------------------------------------

sub onPageChanged
	# called from event
{
	my ($this,$event)=@_;
	my $idx = $event->GetSelection();
	my $page = $this->GetPage($idx);
	display($dbg_nb+1,0,"onPageChanged($idx,"._def($page).")");
	$this->{app_frame}->setCurrentPane($page);
	display($dbg_nb+1,0,"onPageChanged() finished");
	$event->Skip();
}


sub onChildFocus
	# called from event
	# notify the frame that the pane has changed
	# this (apparently) handles switches between floating
	# frames and manager, between notebooks, and between
	# tabs in a notebook.
{
	my ($this,$event) = @_;
	my $idx = $this->GetSelection();
	my $page = $this->GetPage($idx);
	display($dbg_nb+2,0,"onChildFocus($idx,"._def($page).")");;
	$this->{app_frame}->setCurrentPane($page) if $page;
	display($dbg_nb+2,0,"onChildFocus() finished");;
	$event->Skip();
}



sub onAuiPageClose
	# called from event.
	# C++ will Delete the page if we Allow() it, or we Veto()
	# the event if the page is dirty and should not be closed.
{
	my ($this,$event) = @_;
	my $idx = $event->GetSelection();
	my $page = $this->GetPage($idx);
	display($dbg_nb+1,0,"onAuiPageClose($idx,$page)");
	if ($page->closeOK())
	{
		# Call $page->close().  Pub::Wx::Window::onClose() will
		# call {app_frame}->removePane($page) as needed.

		$page->Close();

		# close the floating frame if this is the last window in it.

		$this->closeFloatingSelf() if
			$this->{is_floating} &&
			$this->GetPageCount() == 1;
		$event->Allow();
	}
	else
	{
		$event->Veto();
	}
	$event->Skip();
	display($dbg_nb+1,0,"onAuiPageClose() finished");
}




sub onAuiAllowDND
	# allows the event for external tab drag and drop
{
	my ($this,$event) = @_;
	$event->Allow();
	return;
}

sub onAuiDragDone
	# Uses modified wxWidgets to allow drop in space
	# to create new floating frame. Also updates titles.
{
	my ($this,$event) = @_;
	my $flag = $event->GetSelection();
	display($dbg_nb+1,0,"onAuiDragDone(flag=$flag)",0,$win_color_light_magenta);

	# drop over empty space indicated by -1
	# we create new floating frame for the page

	if ($flag == -1)
	{
        my $pt = Wx::GetMousePosition();
		my $page = $event->GetEventObject();
		my $idx = $this->GetPageIndex($page);
		my $size = $this->{app_frame}->GetSize();
		my $rect = Wx::Rect->new($pt->x,$pt->y,$size->GetWidth(),$size->GetHeight());
		display($dbg_nb+1,1,"drop_in_space book=$this page($idx)=$page->{label}");
		$this->RemovePage($idx);
		my $frame = Pub::WX::FloatingFrame->new($this->{app_frame}, $rect, $page);
		$frame->Show(1);
	}

	# otherwise, close self if no pages left

    display($dbg_nb+1,1,"pagecount=".$this->GetPageCount()." isfloat=$this->{is_floating}");
	$this->closeFloatingSelf() if $this->{is_floating} && !$this->GetPageCount();
    display($dbg_nb+1,0,"onAuiDragDone() finished");
}



#----------------------------------------
# save and restore
#----------------------------------------

sub saveBook
    # called by the frame during save_state.
	# gets the books perspective (tabframe=), prepends
	# NUM_PANES comma to it, and writes it as book_$num
	#
	#     book_0=NUM_PANES,tabframe=5,0,0,0,100000,1,1,882,539,*10003;
	#
	# followed by a number of book_$num_pane_XXX entries
	#
	#     book_0_pane_0=10003,json_data
	#
	# giving the windowID and the jsonified window data to
	# be used in restore, noting that multiple instance windows
	# know how to create their instance numbers
{
	my ($this,$num) = @_;
	display($dbg_sr,0,"$this saveBook($num)");

	my $pane_num = 0;
	for (my $i=0; $i<$this->GetPageCount(); $i++)
	{
		my $pane = $this->GetPage($i);
        next if !defined($pane);
		next if !$pane->saveThisPane();
			# skip the pane if it doesn't want to be saved.
			# the base Pub::WX::Window returns true, so we continue

        my $data = $pane->getDataForIniFile() || '';
		display($dbg_sr,1,"got data=$data");

		my $encoded = $data;

		if ($data)
		{
			try
			{
				my $json = JSON->new();
				$json->allow_nonref();
				$encoded = $json->encode($data);
			}
			catch Error with
			{
				my $ex = shift;   # the exception object
				error("Could not encode_json($data): $ex");
				return;
			}
		}

		display($dbg_sr,1,"encoded=$encoded");

		my $str = "$pane->{id},".$encoded;
		my $config_id = "book_$num"."_pane_".$pane_num++;

		display($dbg_sr,1,"Writing $config_id=$str");
		writeConfig($config_id,$str);
	}

	my $count = $this->GetPageCount();
    my $book_pers = "$pane_num,".$this->SavePerspective();
	display($dbg_sr,1,"Writing book_$num=$book_pers");
	writeConfig("book_$num",$book_pers);
	display($dbg_sr,0,"$this saveBook($num) finished");
}


sub restoreBook
{
	my ($this,$num) = @_;
	display($dbg_sr,0,"$this restoreBook($num)");

	my $book_pers = readConfig("book_$num") || '';
	display($dbg_sr,1,"got book_$num=$book_pers");
	$book_pers =~ s/^(\d+),//;
	my $pane_count = $1;

	for (my $i=0; $i<$pane_count; $i++)
	{
		my $config_id = "book_$num"."_pane_$i";
		my $str = readConfig($config_id) || '';
		display($dbg_sr,1,"got $config_id=$str");
		if (!$str)
		{
			error("Could not readConfig($config_id)");
			return;
		}
		if ($str !~ s/^(\d+),//)
		{
			error("malformed $config_id=$str");
			return;
		}
		my $id = $1;
		my $data = $str;
		if ($str)
		{
			try
			{
				my $json = JSON->new();
				$json->allow_nonref();
				$data = $json->decode($str);
			}
			catch Error with
			{
				my $ex = shift;   # the exception object
				error("Could not decode_json($data): $ex");
				return;
			}
		}
		display($dbg_sr,2,"calling createPane($id,$data");
		$this->{app_frame}->createPane($id,$this,$data);
	}

	display($dbg_sr,1,"calling LoadPerspective($book_pers)");
	$this->LoadPerspective($book_pers);
	display($dbg_sr,0,"$this restoreBook($num) finished");
}



1;
