#!/usr/bin/perl
#-------------------------------------------------------------------------
# Pub::WX::Notebook
#-------------------------------------------------------------------------
# A Pub::WX::Notebook is a container (control) that hold Pub::WX::Windows,
# and which presents a tab bar at the top.
#
# It is derived from a Wx::AuiNotebook, which is turn derived from
# Wx::Control, which is basically just a window.
#
# A Pub::WX::Notebook is owned by exactly one Pub::WX::Frame or Pub::WX::FloatingFrame,
# both of which are derived from Pub::WX::Frame and Pub::WX::FrameBase. Pub::WX::FrameBase
# is derived from Wx::EventHandler, and provides a common object that
# gives each frame in our system a Wx::AuiManager.
#
# The Pub::WX::Frame is special in that has a system menu, contains
# functionality, but most imortantly, structurally, it keeps hashes
# and a list of the Pub::WX::FloatingFrames, Pub::WX::Notebooks, and Pub::WX::Windows
# in the entire system.
#
# All Pub::WX::Notebooks begin life as being owned by the Pub::WX::Frame.


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
	EVT_AUINOTEBOOK_PAGE_CHANGED
);
use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::FloatingFrame;
use base 'Wx::AuiNotebook';

#sub CLONE_SKIP { 1 };
	# putting this in a package prevents it from being
	# cloned when the perl interpreter is copied to a new
	# thread, so that, also, the DESTROY methods are not
	# called on the bogus memory object.  This should be
	# in all WxWidgets objects, which should not be
	# touchable, except by the main thread, and all
	# threads should only work on a small set of
	# well known variables, mostly shared.


our $dbg_nb = 1;


sub new
{
	my ($class,$app_frame,$name,$float_frame) = @_;
    my $use_name = $name;
    $use_name =~ s/\(\d+\)$//;
    my $data = ${$resources->{notebook_data}}{$use_name};
	display($dbg_nb,0,"new notebook($name) data=$data");

	# create the notebook

	my $frame = $float_frame ? $float_frame : $app_frame;
	my $this = $class->SUPER::new( $frame, -1, [-1, -1], [300, 300],
		wxAUI_NB_TAB_SPLIT |
		wxAUI_NB_TAB_EXTERNAL_MOVE |
		wxAUI_NB_SCROLL_BUTTONS |
		wxAUI_NB_CLOSE_ON_ACTIVE_TAB |
		wxAUI_NB_TAB_MOVE );

    $this->{data} = $data;
	$this->{name} = $name;
	$this->{frame} = $frame;
    $this->{app_frame} = $app_frame;
	$this->{is_floating} = $float_frame ? 1 : 0;
	$this->{manager} = $frame->{manager};
	$frame->{notebooks}{$name} = $this;

	# add it to the aui manager

	my $pane = Wx::AuiPaneInfo->new
		->Name($name)
		->Caption($$data{title})
		->Row($$data{row})
		->Position($$data{pos})
		->CenterPane
		->Dockable
		->Floatable
		->Movable
		->Resizable
		->CloseButton
		->MinimizeButton;

	# let me document this a little better ...
	# you MUST call Left and Bottom on the resources
	# and output notebooks AFTER the above setup or they
	# WILL NOT initially be floatable.

    my $pane_direction = $$data{direction} || '';
	$pane->Gripper  if ($name !~ /^content/);
	$pane->Left() 	if ($pane_direction =~ /left/);
	$pane->Top() 	if ($pane_direction =~ /top/);
	$pane->Right() 	if ($pane_direction =~ /right/);
	$pane->Bottom() if ($pane_direction =~ /bottom/);
	$this->{manager}->AddPane($this, $pane);
	$this->{manager}->Update();

	# register event handlers

	EVT_AUINOTEBOOK_DRAG_DONE($this, -1, \&onAuiDragDone);
	EVT_AUINOTEBOOK_ALLOW_DND($this, -1, \&onAuiAllowDND);
	EVT_AUINOTEBOOK_PAGE_CLOSE($this, -1, \&onAuiPageClose);
	EVT_AUINOTEBOOK_PAGE_CHANGED($this,-1,\&onPageChanged);
	EVT_CHILD_FOCUS($this,\&onChildFocus);

	# return to caller

	return $this;

}	# Pub::WX::Notebook::new()


#---------------------------------------------
# methods
#---------------------------------------------

sub DESTROY
{
	my ($this) = @_;

	# my ($indent,$file,$line,$tree) = Pub::Utils::get_indent(0,1);
	# display(0,0,$tree);

	my $app_frame = $this->{app_frame};
	my $name = $this->{name};
	display($dbg_nb,0,"DESTROY $this($name)");
	return;

    if ($app_frame && $app_frame->{notebooks} && $app_frame->{notebooks}{$name})
	{
		display($dbg_nb,1,"removing notebook from parent frame($app_frame)");
		delete $app_frame->{notebooks}{$name};
	}

	delete $this->{frame};
    delete $this->{app_frame};
	delete $this->{manager};

}


sub getConfigStr
    # called by the frame during save_state, returns
    # a vertical bar delimited string.  The first element
    # is the perspective for the notebook, followed by
    # four elements per pane (the id, the instance,
	# the data, and the config_str
{
	my ($this) = @_;

    my $pers = $this->SavePerspective() || '';
	my $config_str = $pers.'|';

	for (my $i=0; $i<$this->GetPageCount(); $i++)
	{
		my $page = $this->GetPage($i);
        next if !defined($page);
		next if !$page->saveThisPane();
			# pages (i.e. untitled) decide if they should
			# be saved with the notebook ..

        my $data = $page->{data} || '';
        my $str = $page->getConfigStr() || '';
		my $instance = $page->{instance} || 0;
        $config_str .= $page->{id}.'|'.$instance.'|'.$data.'|'.$str.'|';
	}
	return $config_str;
}


# Misleading at best, these methods are not consistently
# called in Perl.  Pages are added and deleted by WxWidgets
# C++ code in drag and drop
#
# 	sub AddPage
# 		# overidden so we can update the title
# 		# when a page is added or deleted
# 	{
# 		my ($this,$page,$caption,$select,@params) = @_;
# 		display($dbg_nb,0,"$this AddPage($page)");
# 		my $rslt = $this->SUPER::AddPage($page,$caption,$select,@params);
# 	}
#
#
# 	sub RemovePage
# 		# overidden so we can update the title
# 		# when a page is added or deleted
# 	{
# 		my ($this,$idx) = @_;
# 		display($dbg_nb,0,"$this RemovePage($idx)");
# 		my $rslt = $this->SUPER::RemovePage($idx);
# 		return $rslt;
# 	}


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


sub closeSelf
	# closes a notebook when all of the panes are gone.
	# the notebook may be owned by a floating frame, or
	# indirectly by the frame as a managed aui pane.
	# we never close the main content notebook pane
{
	my ($this) = @_;
	my $name = $this->{name};
	my $app_frame = $this->{app_frame};
	return if ($this->{name} eq "content");
	display($dbg_nb,0,"$this closeSelf($name) floating=$this->{is_floating}");

	# if it's owned by one of my floating frames, close it

	my $frame = $this->{frame};
	if ($frame && $this->{is_floating})
	{
		display($dbg_nb,1,"closeSelf calling $frame Close()");
		$frame->Close();
		return;
	}
	elsif ($this->{is_floating})
	{
		error("floating notebook without a parent frame??");
		return;
	}

	# Remove the managed window it from the aui manager by
	# hiding it.  We never really delete the main content windows.
	# Might have to float them first to get drawing to work right.

	my $pane = $this->{manager}->GetPane($this);
	$pane->Hide();
	$this->{manager}->Update();
}


#--------------------------------------
# Event Handlers
#--------------------------------------

sub onPageChanged
{
	my ($this,$event)=@_;
	my $idx = $event->GetSelection();
	display($dbg_nb,0,"Pub::WX::Notebook::onPageChanged(new=$idx)");
	my $page = $this->GetPage($idx);
	$this->{app_frame}->setCurrentPane($page);
	$event->Skip();
}


sub onChildFocus
	# notify the frame that the pane has changed
	# this (apparently) handles switches between floating
	# frames and manager, between notebooks, and between
	# tabs in a notebook.
{
	my ($this,$event) = @_;
	my $sel = $this->GetSelection();
	my $pane = $this->GetPage($sel);
	display($dbg_nb,0,"Pub::WX::Notebook::onChildFocus("._def($pane).") getPageCount=".$this->GetPageCount());;
	$this->{app_frame}->setCurrentPane($pane) if $pane;
	$event->Skip();
}


sub onAuiAllowDND
	# allows the event for external tab drag and drop
{
	my ($this,$event) = @_;
	$event->Allow();
	return;
}

sub onAuiPageClose
	# stop the process if the page is dirty and should not be closed.
	# onClose() methods handle all detaching of frame objects.
	# otherwise, if it's the last page, close the notebook.
{
	my ($this,$event) = @_;
	my $tab_idx = $event->GetSelection();
	my $page = $this->GetPage($tab_idx);
	display($dbg_nb,0,"$this onAuiPageClose(book=$this->{name}) page=$page");
	if ($page->closeOK())
	{
		$this->closeBookPageIDX($page,$tab_idx);
	}
	else
	{
		$event->Veto();
	}
}


sub closeBookPageIDX
{
    my ($this,$page,$idx) = @_;
    display($dbg_nb,1,"$this closeBookPageIDX($page->{label},$idx) isfloat=$this->{is_floating}");
	display($dbg_nb,2,"page=$page");
	display($dbg_nb,2,"getPageCount=".$this->GetPageCount());
	$page->Close();
	$this->{app_frame}->removePane($page);
    $this->DeletePage($idx);
	display($dbg_nb,2,"after DeletePage() getPageCount=".$this->GetPageCount());
	if ($this->{is_floating} && !$this->GetPageCount())
	{
		$this->closeSelf($this);
	}
    display($dbg_nb,1,"$this closeBookPageIDX($page) finishing");
}


sub closeBookPage
{
    my ($this,$page) = @_;
	display($dbg_nb,0,"$this closeBookPage($page)");
    my $idx = $this->GetPageIndex($page);
    $this->closeBookPageIDX($page,$idx);
	display($dbg_nb,0,"$this closeBookPage($page) finished");

}



sub onAuiDragDone
	# Uses modified wxWidgets to allow drop in space
	# to create new floating frame. Also updates titles.
{
	my ($this,$event) = @_;
	my $flag = $event->GetSelection();
	display($dbg_nb,0,"$this onAuiDragDone(flag=$flag)");

	# drop over empty space indicated by -1
	# we create new floating frame for the page

	if ($flag == -1)
	{
        my $pt = Wx::GetMousePosition();
		my $page = $event->GetEventObject();
		my $idx = $this->GetPageIndex($page);
		display($dbg_nb,1,"drop_in_space book=$this->{name}($idx) page=$page->{label}");
		$this->RemovePage($idx);
		my $frame = Pub::WX::FloatingFrame->new($this->{app_frame}, $pt->x, $pt->y, $page);
		$frame->Show(1);
	}

	# otherwise, close self if no pages left

    display($dbg_nb,3,"pagecount=".$this->GetPageCount()." isfloat=$this->{is_floating}");
	$this->closeSelf() if ($this->GetPageCount()==0 && $this->{is_floating});
}





1;
