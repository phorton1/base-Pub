#!/usr/bin/perl
#---------------------------------------------------------------------
# There is a one to one correlation between frames and notebooks
# A frame is the main frame and has it's 'book'
# all other frames are floating, and have their 'book'
# The only time I need to know about multiple notebooks is in save/restore
# but really, the notebook data is subservient to the frame data.
# I'm getting rid of {notebooks}


package Pub::WX::Frame;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
    EVT_MENU
    EVT_UPDATE_UI
    EVT_COMMAND );
use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::AppConfig;
use Pub::WX::FrameBase;
use Pub::WX::FloatingFrame;		# has to be included somewhere
use Pub::WX::Notebook;
use Pub::WX::Menu;
use Pub::WX::Dialogs;
use base qw(Wx::Frame Pub::WX::FrameBase);


my $dbg_frame = 0;
    # 0 = main lifecycle events
	# -1 = main pane events
	# -2 = all details
my $dbg_sr = 0;
    # 0 = show saveState() and restoreState() calls
	# -1 = show details


our $RESTORE_NONE 		= 0;
our $RESTORE_MAIN_RECT  = 1;
our $RESTORE_MAIN_WIN   = 2;
our $RESTORE_ALL        = 3;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
		$RESTORE_NONE
		$RESTORE_MAIN_RECT
		$RESTORE_MAIN_WIN
		$RESTORE_ALL
	);
}


my $how_restore = $RESTORE_NONE;

sub setHowRestore
{
	my ($how) = @_;
	$how_restore = $how;
}


#---------------------------------------------------
# Known WX debugging constants
#--------------------------------------------------
#
# You can set the global debug level via PRH_WX_DEBUG environment variable.
#    It defaults to 0
# You can set groups of functions debug levels via environment variables
#    PRH_WX_DEBUG_DD = 0
# The messages go to STDOUT, formatted to look somewhat like
#    those from appUtils::display(). They do NOT go to the
#    appUtils logfile.
#
# Set PRH_WX_DEBUG = 0       global debugging level or
# Set PRH_WX_DEBUG_DD = 2    dbg_dd debug level (default = 5)
#
# Probably want to figure out backtrace and stack indentation
#
#    dbg_dd  		"DD"     	drag and drop debugging flag
#    dbg_ddd 		"DDD"    	drag and drop details flag
#    dbg_sl  		"SL"     	save/load perspective
#    dbg_sld 		"SLD"    	save/load perspective details
#    dbg_rs 		"_RS"     	richTextBuffer styling
#    dbg_rsd 		"_RSD"   	richTextBuffer details
#    dbg_rsdd 		"_RSDD" 	richTextBuffer gruesome details
#    dbg_rsp  		"_RSP"  	debug paragraph pasting
#    dbg_undo  		"_UNDO"  	richTextBuffer/stc "undo" scheme
#    dbg_undod 		"_UNDOD" 	richTextBuffer/stc "undo" scheme details
#    dbg_print 		"PRINT"  	html easy printing, etc


# sub CLONE_SKIP { 1 };
	# putting this in a package prevents it from being
	# cloned when the perl interpreter is copied to a new
	# thread, so that, also, the DESTROY methods are not
	# called on the bogus memory object.  This should be
	# in all WxWidgets objects, which should not be
	# touchable, except by the main thread, and all
	# threads should only work on a small set of
	# well known variables, mostly shared.


#----------------------------
# Display Methods
#----------------------------

sub showError
{
    my ($this,$msg) = @_;
	my $dlg = Wx::MessageDialog->new($this,$msg,"Error",wxOK|wxICON_EXCLAMATION);
	$dlg->ShowModal();
}



#--------------------------------------------
# new() and onInit()
#--------------------------------------------

sub new
{
	my ($class, $parent) = @_;

	# has to go somewhere

	Wx::InitAllImageHandlers();

	# get a useable windows size to start
    # and note if we've run before

	Pub::WX::AppConfig::initialize();

	my $rect;
	my $config;

	display($dbg_sr+1,0,"Pub::WX::Frame::new() how_restore=$how_restore");

	if ($how_restore >= $RESTORE_MAIN_RECT)
	{
		$rect = $config = readConfigRect("rect_0");
		display($dbg_sr+1,2,"rect_0="._def($rect));
	}
	$rect = Wx::Rect->new(200,100,900,600) if !$rect;

    # create super class, populate, call standard FrameBase
	# setup method which invariantly sets {title} and creates
	# the {book} noteBook

    my $title = $$resources{app_title};
	my $this = $class->SUPER::new(
		$parent,
		-1,
		$title,
        [ $rect->x, $rect->y ],
        [ $rect->width, $rect->height ] );
    setAppFrame($this);
 	$this->FrameBase($this);

	$this->{frames}  = {};		# these are the floating_frames
    $this->{panes}   = [];		# this is all windows in the system

	# restore the state if $rect was found

    $this->restoreState() if
		$config && $how_restore > $RESTORE_MAIN_RECT;

    # create the system menu

	$this->setMainMenu();

    # register event handlers

	EVT_MENU($this, $CLOSE_ALL_PANES, \&onCloseWindows);
	EVT_MENU($this, $CLOSE_OTHER_PANES, \&onCloseWindows);
    EVT_UPDATE_UI($this, $CLOSE_ALL_PANES, \&onCloseUpdateUI);
	EVT_UPDATE_UI($this, $CLOSE_OTHER_PANES, \&onCloseUpdateUI);

    # become the main application frame and return

	$this->{running} = 1;
    return $this;

}   # Pub::WX::Frame::new()



#------------------------------------------------------
# onCloseFrame(), onCloseWindows(), and DESTROY()
#------------------------------------------------------

sub onCloseFrame
	# save the state of the windows and frames.
	# clear the running flag to indicate we are shutting down,
	# close the windows, and if anybody objects reset the flag
	# returns 0 if anybody objected, 1 if everybody was closed
{
	my ($this,$event) = @_;
	display($dbg_frame,0,"Pub::WX::Frame::onCloseFrame()");

	$this->saveState();

	$this->{running} = 0;
	my $rslt = $this->onCloseWindows($event);
	display($dbg_frame+1,0,"Pub::WX::Frame::onCloseFrame() rslt="._def($rslt));

	if (!$rslt)
	{
		$this->{running} = 1;
		$event->Veto();
	}
	else
	{
		$event->Skip();
	}
    return $rslt;
}


sub onCloseWindows
	# Close all, or most of the windows in the system.
	# Called by events $CLOSE_ALL_PANES and $CLOSE_OTHER_PANES
	# and frame::onClose(), or explicitly with no event i.e.
	# when changing logins or re-initialize database, etc.
	#
	# For each window we call it's closeOK() method
	# where it returns:
	#
	#  	0 to not close the window and stop the loop.
	#  	1 to close the window and continue the loop.
	#  -1 to close the window, and continue the loop,
	#     but not call closeOK() any more (abandon all changes).
{
	my ($this,$event) = @_;
    my $id = $event ? $event->GetId() : 0;
    my $skip = ($id == $CLOSE_OTHER_PANES) ? $this->getCurrentPane() : undef;

	display($dbg_frame,0,"onCloseWindows($id) skip="._def($skip));

	my $rslt = 1;
	my @panes = @{$this->{panes}};
    for my $pane (@panes)
    {
		if ($pane)
		{
			display($dbg_frame+1,1,"checking($rslt) $pane(".$pane->GetId().") title="._def($pane->{title}));
			if ( (!$skip || $pane != $skip) &&
			     ($rslt == -1 || ($rslt = $pane->closeOK())) )
			{
				my $book = $pane->GetParent();
				$book->closeBookPage($pane);
			}
			last if !$rslt;
		}
		else
		{
			warning(0,0,"NULL pane in onCloseWindows()");
		}
	}

	$event->Skip() if $event && $rslt;
	display($dbg_frame+1,0,"onCloseWindows() reutrning rslt="._def($rslt));
	return $rslt;
}


sub onCloseUpdateUI
{
	my ($this,$event) = @_;
    my $id = $event->GetId();
    my $panes = $this->{panes};
    my $skip = ($id == $CLOSE_OTHER_PANES) ? $this->getCurrentPane() : undef;

	my $enable = 0;
	for my $pane (@$panes)
	{
		if ($pane && (!$skip || $pane != $skip))
		{
			$enable = 1;
			last;
		}
	}
	$event->Enable($enable);
}


sub DESTROY
	# bypassing months of work years ago,
	# the entire DESTORY call chain is now
	# short returning
{
	my ($this) = @_;
	display($dbg_frame,0,"DESTROY Pub::WX::Frame");
	setAppFrame(undef);
	return;
}



#------------------------------------------------------------
# create the Main menu
#------------------------------------------------------------

sub setMainMenu
{
	my ($this) = @_;
	display($dbg_frame+1,0,"setMainMenu()");

    my $menu_items = $resources->{main_menu};
    my $menubar= Wx::MenuBar->new();
	display($dbg_frame+2,1,"found ".scalar(@$menu_items)." menu items");

	foreach my $menu_title (@$menu_items)
	{
		my ($menu_name,$menu_title) = split(/,/,$menu_title);
		display($dbg_frame+2,2,"menu_item($menu_name,$menu_title)");
		my $menu = Pub::WX::Menu::createMenu($menu_name);
		$menubar->Append($menu,$menu_title);
	}
	$this->SetMenuBar($menubar);
}



#------------------------------------------------------
# Frames and Notebooks
#------------------------------------------------------

sub addFloatingFrame
{
	my ($this,$instance,$frame) = @_;
	warning($dbg_frame,0,"$this addFloatingFrame($instance)=$frame");
	$this->{frames}->{$instance} = $frame;
}

sub deleteFloatingFrame
{
	my ($this,$instance) = @_;
	warning($dbg_frame,0,"$this deleteFloatingFrame($instance)="._def($this->{frames}->{$instance}));
	delete $this->{frames}->{$instance};
	display($dbg_frame,0,"deleteFloatingFrame() finished");
}





#------------------------------------------------------
# panes
#------------------------------------------------------

sub createPane
	# base class factory does nothing and should probably be removed
	# would like to remove base class createPane method?
{
	my ($this,$id,$book,$data) = @_;
	error("Your application must implement createPane!!");
	return;
}



sub activateSingleInstancePane
	# Called by derived classes createPane() method for
	# 	  single instance panes that may be re-activated
	#     by menu or with new 'data'
	# Single instance panes may have a setPaneData() method
	# 	  that gets called upon their activation,
{
	my ($this,$id,$book,$data) = @_;
	display($dbg_frame+1,0,"gitUI::Frame::activateSingleInstancePane($id)".
		" book="._def($book).
		" data="._def($data) );
	if (!$this->{running})
	{
		display($dbg_frame+1,1,"not running: short return");
		return undef;
	}
	my $pane = $this->findPane($id);
	if ($pane)
	{
		$pane->setPaneData($data) if $pane->can('setPaneData');
		$pane->SetFocus();
	}
	return $pane;
}





sub getCurrentPane
{
	my ($this) = @_;
	return $this->{current_pane};
}


sub findPane
{
	my ($this,$id) = @_;
	return if (!$id);
    for my $pane (@{$this->{panes}})
	{
		return $pane if ($pane->{id}==$id);
	}
}


sub addPane
	# set pane into list of all panes, and make it current
{
	my ($this,$pane) = @_;
	push @{$this->{panes}},$pane;
	display($dbg_frame+1,0,"added $pane");
	$this->setCurrentPane($pane);
}


sub removePane
{
	my ($this,$del_pane) = @_;
	display($dbg_frame+1,0,"removing $del_pane from frame::panes");

	if (_def($del_pane) eq _def($this->{current_pane}))
	{
		display($dbg_frame+1,1,"setting this->{current_pane} to undef");
		$this->{current_pane} = undef;
	}

	my $found = 0;
	for my $idx (0..@{$this->{panes}})
	{
		my $pane = @{$this->{panes}}[$idx];
		if ($pane && $pane == $del_pane)
		{
			$found = 1;
			display($dbg_frame+2,1,"-->found $del_pane");
			splice @{$this->{panes}},$idx,1;
			last;
		}
	}
	if (!$found)
	{
		display($dbg_frame+2,0,"note: could not find $del_pane for removal");
	}
	# $this->setCurrentPane(undef);
}


sub setCurrentPane
{
	my ($this,$new_cur) = @_;
	display($dbg_frame+1,0,"setCurrentPane(pane=".($new_cur?$new_cur:'undef').")"); # ,1);

	# Notebook may call this with a stale pane.
	# We only accept the pane if it is our {panes} array
	# Note if it is already the current pane

	my $found = undef;
	if (!$this->{running})
	{
		display($dbg_frame+1,1,"not running: setting current_pane to undef");
	}
	elsif ($new_cur)
	{
		for my $pane (@{$this->{panes}})
		{
			$found = $pane if $pane == $new_cur;
		}
		if (!$found)
		{
			display($dbg_frame+1,1,"setCurrentPane() could not find $new_cur; setting undef");
		}
		else
		{
			my $cur = $this->getCurrentPane();
			if (_def($found) eq _def($cur))
			{
				display($dbg_frame+9,1,"note: "._def($cur)." is already the current pane");
			}
		}
	}

	# set the member and call activation method

	$this->{current_pane} = $found;
	$found->onActivate() if $found && $found->can("onActivate");


	# implement a pending_populate scheme.
	# this is called anytime the window comes into focus

	if ($found &&
		$found->{pending_populate} &&
		$found->can("populate"))
	{
		display($dbg_frame,1,"setCurrentPane($found->{label}) calling pending populate() ");
		$found->populate();
		$found->{pending_populate} = 0;
	}
}



#------------------------------------------------------------
# Save and Restore window state
#------------------------------------------------------------


sub saveFrame
{
	my ($frame,$num) = @_;

	# save the window rectangle

	my $rect = $frame->GetScreenRect();
	display_rect($dbg_sr+1,0,"saveFrame($num) rect_$num=",$rect);
	writeConfigRect("rect_$num",$rect);

	# have the Notebook store its information

	$frame->{book}->saveBook($num);

	# save the manager perpective
	# manager perspectives are black boxes that we pass pack in restore

	my $perspective = $frame->{manager}->SavePerspective();
	display($dbg_sr+1,1,"writing pers_$num=$perspective'");
	writeConfig("pers_$num",$perspective);
}


sub saveState
{
    my ($this) = @_;
	return if !$Pub::WX::AppConfig::ini_file;
    warning($dbg_sr,0,"Pub::WX::Frame::saveState() called");

	clearConfigFile();
	saveFrame($this,0);

	my $num = 0;
	display($dbg_sr,1,"saving ".scalar(keys %{$this->{frames}})." FloatingFrames");
	foreach my $instance (sort {$a <=> $b} keys %{$this->{frames}})
	{
		my $frame = $this->{frames}->{$instance};
		saveFrame($frame,++$num);
	}

	Pub::WX::AppConfig::save();
    display($dbg_sr+1,0,"Pub::WX::Frame::saveState() done");
}



sub restoreFrame
	# The frame's rectangle has already been done
{
	my ($frame,$num) = @_;
	$frame->{book}->restoreBook($num);

	# restore the manager perspective

	my $manager_pers = readConfig("pers_$num");
	display($dbg_sr+1,1,"manager->LoadPerspective($manager_pers)");
	$frame->{manager}->LoadPerspective($manager_pers);
    $frame->{manager}->Update();
}


sub restoreState
{
    my ($this) = @_;
	return if !$Pub::WX::AppConfig::ini_file;
    display($dbg_sr,0,"Pub::WX::Frame::restoreState() called");

	restoreFrame($this,0);

	if ($how_restore >= $RESTORE_ALL)
	{
		my $num=1;
		while (my $rect = readConfigRect("rect_$num"))
		{
			display_rect($dbg_sr,1,"restoring floatingFrame($num) rect=",$rect);
			my $frame = new Pub::WX::FloatingFrame(
				$this,
				$rect,
				undef);
			restoreFrame($frame,$num++);
			$frame->Show(1);
		}
	}

    display($dbg_sr+1,0,"Pub::WX::Frame::restoreState() done");
}





1;
