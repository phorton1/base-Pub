#!/usr/bin/perl
#-------------------------------------------------------------------------
# Pub::WX::Window
#-------------------------------------------------------------------------
# Mixin base class for Panes -- the content windows that live as tabs
# inside a Pub::WX::Notebook.
#
# "Pane" is this codebase's term for what Wx documentation calls a
# "page" (a notebook tab).  See the full terminology note in
# Pub::WX::FrameBase.
#
# A Pane is logically owned by the AppFrame ({panes} list) for its
# entire lifetime, regardless of which Notebook it is physically
# parented to at any given moment.  This includes Panes that live in
# a toolbar-style Notebook on the AppFrame -- they are in {panes} and
# participate in closeOK() on application shutdown, just like any other
# Pane.  Toolbar Panes should therefore not carry dirty state that
# requires user prompting, since the user does not think of them as
# documents.
#
# Panes can be reparented -- dragged from the AppFrame's content Notebook
# into a FloatingFrame's Notebook and back -- without changing their
# logical ownership.
#
#
# CREATING A PANE
#
# Derive from both Wx::Window (or a subclass) and Pub::WX::Window.
# After SUPER::new(), call MyWindow($frame,$book,$id,$label,$data).
# MyWindow() adds the Pane to the Notebook as a tab, registers it in
# the AppFrame's {panes} list, and sets up EVT_CLOSE and EVT_CHILD_FOCUS.
#
#
# WHAT DERIVED CLASSES SHOULD OVERRIDE
#
#   getDataForIniFile()  Return a scalar, hash, or array to be JSON-
#                        encoded and stored in the ini file.  It will be
#                        decoded and passed back as $data to the
#                        constructor on restore.  Default returns ''.
#
#   saveThisPane()       Return 0 to exclude this Pane from save/restore.
#                        Default returns 1.
#
#   closeOK()            Called before closing this Pane.  Return 0 to
#                        block (e.g. unsaved changes), 1 to allow and
#                        continue, -1 to allow and abandon all remaining
#                        dirty checks.  Default returns 1.
#
#   autoClose()          Return 0 if this Pane should be exempt from
#                        CLOSE_ALL_PANES and CLOSE_OTHER_PANES menu
#                        events -- i.e. it is a persistent Pane that
#                        the user does not expect to be dismissed by
#                        those commands.  Default returns 1 (closeable).
#                        NOTE: autoClose() is not yet checked by
#                        Pub::WX::Frame::onCloseWindows() -- that is a
#                        known gap to be addressed in the machinery.


package Pub::WX::Window;
use strict;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(EVT_CHILD_FOCUS EVT_CLOSE);
use Pub::Utils;
use base qw(Wx::Window);

my $debug_aw = 1;


sub MyWindow
	# legacy method name was appWindow
	# 'become" a Pub::WX::Window and adds elf to the Pub::WX::Notebook
{
	my ($this,$frame,$book,$id,$label,$data,$instance) = @_;

	$instance ||= 0;
	$this->SetId($id);
		# hmmm ... I previously encoded the instance into the id.
		# 		$this->SetId($id + $instance);
		# but that doesn't work with retoreState(), so I am removing it

	# set member variables

	$this->{instance} = $instance;
	$this->{id} = $id;	#  + $instance;
	$this->{frame} = $frame;
    $this->{app_frame} = $frame->{app_frame};
	$this->{label} = $label;
	$this->{data} = $data;
	$this->{pending_populate} = 0;
		# scheme implemented in derived class usage

	display($debug_aw,0,"adding MyMX::Window($this) to notebook($book->{name})");
	$book->AddPage( $this, $label, 1);
	$frame->addPane($this);

	# register event handlers

	EVT_CLOSE($this,'onClose');
	EVT_CHILD_FOCUS($this,\&onChildFocus);
}


sub closeSelf
{
	my ($this) = @_;
	my $book = $this->GetParent();
	display($debug_aw,0,"closeSelf ".ref($this));
	$book->closeBookPage($this);
	display($debug_aw,0,"closeSelf finishing".ref($this));
}


sub onClose
{
	my ($this,$event) = @_;
	my $id = $this->GetId();
	display($debug_aw,0,"Pub::WX::Window::onClose(".ref($this)."($id) $this->{caption})");
	$this->{frame}->removePane($this);
	$event->Skip();
}


sub onChildFocus
{
	my ($this,$event) = @_;
	$this->{frame}->setCurrentPane($this);
	display($debug_aw+1,0,"Pub::WX::Window::onChildFocus($this->{label}) pending_populate=$this->{pending_populate}");
	$event->Skip();
}


sub closeOK
	# Called by framework before closing window.
	# By default it is ok to close a window.
	# Classes that have dirty states should implement this method
	#    and prompt to Abandon Changes? (or save the file), and
	#    return 1 if it is ok to continue with closing this and
	#    subsequent windows.
	# Return 0 to not close the window and stop the loop.
	# Return 1 to close the window and continue the loop.
	# Return -1 to close the window, and continue the loop,
	#    but not call closeOK() any more (abandon all changes).
{
	my ($this,$more_dirty) = @_;
	display($debug_aw,0,"Pub::WX::Window::closeOK($this->{label}) returning 1");
	return 1;
}




sub getDataForIniFile
	# Return a data object (or '') to be jsonified
	# and stored in the ini file to later be de-jsonified
	# and retured as the $data param during window ctor.
	# DATA CANNOT CONTAIN \n and
	# MUST BE PURE SIMPLE PERL scalar, hash, or array
{
	my ($this) = @_;
	return '';
}


sub saveThisPane
	# The default is that panes are saved and restored
{
	my ($this) = @_;
	return 1;
}


sub recommendedSize
	# derived class may implement this
	# it will be called when a window is dropped into a new floating frame
	# as the recommended size for the new floating frame
{
   return [300,300];
}



1;
