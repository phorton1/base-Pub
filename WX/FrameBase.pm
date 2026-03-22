#!/usr/bin/perl
#-------------------------------------------------------------------------
# Pub::WX::FrameBase
#-------------------------------------------------------------------------
# This file defines the conventions that shape what a Pub::WX application
# looks like and how it behaves.  It is a mixin applied to both
# Pub::WX::Frame (the application window) and Pub::WX::FloatingFrame
# (user-detached secondary windows).
#
#
# THE SHAPE OF A Pub::WX APPLICATION
#
# A Pub::WX application consists of one AppFrame and zero or more
# FloatingFrames.  Both are real OS top-level windows (Wx::Frame
# subclasses).  They differ in role and in what they contain:
#
#   AppFrame      - IS the application.  Closing it ends everything.
#                   Has a main menu (File, View, Edit, etc).
#                   Logically owns all Panes in the entire system,
#                   including those currently displayed in FloatingFrames.
#                   May have one or more Notebooks (see below).
#
#   FloatingFrame - A detached secondary window.  Closing it closes
#                   only the Panes it contains.  Has no main menu.
#                   Always has exactly one Notebook (content only).
#                   Created when the user drags a Pane into empty space.
#                   Destroys itself automatically when its last Pane
#                   is removed.
#
#
# WHAT FRAMEBASE GIVES EACH FRAME
#
# FrameBase() creates two things inside every frame:
#
#   {manager}  - A Wx::AuiManager.  One per frame, owned by that frame,
#                destroyed with it.  An invisible layout engine that
#                manages the frame's child Notebooks -- positioning,
#                docking, floating, and resizing them.  It can save and
#                restore the entire layout as a perspective string.
#                Note: Wx documentation uses "pane" to mean the things
#                the AuiManager manages (i.e. Notebooks).  See the
#                terminology note below.
#
#   {book}     - A single Pub::WX::Notebook registered with {manager}
#                as the center pane.  This is the primary content
#                Notebook.  Panes (content windows) live here as tabs.
#
#
# NOTEBOOKS: THE CONTENT NOTEBOOK AND OPTIONAL TOOLBOOKS
#
# Every frame has exactly one content Notebook ({book}), which fills
# the frame and holds open Panes as tabs.  The content Notebook is not
# declared in resources because it is not a choice -- every Pub::WX
# frame has exactly one and its parameters are framework constants.
# Only toolbooks, which represent deliberate application-specific design
# decisions, are declared in resources.
#
# A toolbook is an additional Notebook on the AppFrame, docked to a
# side (typically left) and styled with a gripper handle.  It houses
# Panes that are tools operating on or navigating content, rather than
# content itself.  The distinction is semantic, not visual -- a toolbook
# might look like a sidebar panel, a category browser, or a traditional
# toolbar depending on the application.  What makes it a toolbook is
# that its Panes are persistent and application-scoped rather than
# transient and data-scoped.  Key characteristics:
#
#   - Only on the AppFrame, never on a FloatingFrame
#   - Its Panes are persistent -- not casually opened and closed
#   - Does not accept ordinary content Panes dragged into it
#   - Can be floated by the user but retains its toolbook identity
#   - Typically styled without per-tab close buttons so the user
#     cannot accidentally dismiss a persistent tool
#
# Toolbook Panes ARE registered in the AppFrame's {panes} list and DO
# participate in closeOK() on application shutdown.  They should not
# carry dirty state requiring user prompting, since the user does not
# think of them as documents.
#
# Toolbooks are declared in $resources->{toolbooks} as an ordered array
# of hashrefs.  The ordering is stable across sessions and is used as
# the index when saving and restoring state.  Apps with no toolbooks
# omit the member entirely.
#
#
# TERMINOLOGY: "PANE" IN THIS CODEBASE vs WX DOCUMENTATION
#
# This codebase uses "Pane" to mean a content window -- the things that
# live as tabs inside a Notebook.  They are owned logically by the
# AppFrame ({panes} list) and parented physically to whatever Notebook
# currently holds them.  They can be reparented from one Notebook to
# another (e.g. dragged into a FloatingFrame).
#
# Wx documentation uses "pane" differently -- to mean any child window
# managed by an AuiManager, which includes Notebooks themselves.
# Wx calls what we call Panes "pages" (notebook pages/tabs).
#
# This collision is intentional and accepted.  Within this codebase,
# "Pane" always means a content window / notebook tab.  When reading
# Wx documentation: Wx "pane" = our Notebook, Wx "page" = our Pane.

package Pub::WX::FrameBase;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(EVT_CLOSE);
use Wx::AUI;
use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::Notebook;
use base 'Wx::EvtHandler';



our $dbg_fb = 1;


sub FrameBase
	# mixin method was previously "appFrameBase"
    # returns value from onInit()
{
	my ($this,$app_frame,$instance, $page) = @_;

    $instance ||= 0;
	$page ||= '';

	$this->{app_frame} = $app_frame;
	$this->{instance} = $instance;
    $this->{title} ||= $resources->{app_title};

	display($dbg_fb,0,"Pub::WX::FrameBase($this->{title}) instance=$instance page=".($page?$page->{label}:''));

	$this->SetIcon(Wx::Icon->new($$resources{app_icon}, wxBITMAP_TYPE_ICO))
        if $resources->{app_icon};

	# add ourselves to the mainFrame


	# setup the manager user interface

	$this->{manager} = Wx::AuiManager->new($this,
	    wxAUI_MGR_TRANSPARENT_HINT |
		wxAUI_MGR_ALLOW_FLOATING |
    	wxAUI_MGR_ALLOW_ACTIVE_PANE );

	# invariantly create the notebook, add page if needed
	# and call Update();

	$this->{book} = Pub::WX::Notebook->new($app_frame, $instance);
	$this->{book}->AddPage( $page, $page->{label}, 0) if $page;

	# create additional toolbook notebooks if this is the AppFrame
	# and $resources->{toolbooks} declares any

	$this->{toolbooks} = {};
	if ($this == $app_frame && $resources->{toolbooks})
	{
		for my $tb (@{$resources->{toolbooks}})
		{
			my $nb = Pub::WX::Notebook->new($app_frame, undef, $tb);
			$this->{toolbooks}{$tb->{name}} = $nb;
		}
	}

	$this->{manager}->Update();

    # register event handlers

	EVT_CLOSE($this, 'onCloseFrame');  # pure virtual ... note use of quotes

}	# frameBase()







1;
