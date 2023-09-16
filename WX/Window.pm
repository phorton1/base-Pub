#!/usr/bin/perl
#------------------------------------------------------
# Pub::WX::Window
#------------------------------------------------------
# add-in base class for windows that are added to My::Notbooks
#
# It's easy to create a new window that corresponds to a command.
# Just add the id's to the resources in the range for window-commands
# and use the window, and create it in the application frame
# onCreatePane() method.
#
# Similarly, it's easy to create a window that is associated
# with some user data (i.e. client_num or filename).  Just
# provide a getConfigStr() method that returns the data
# associated with the window, and call the constructor
# with the config_str.
#
# Multiple instance windows are trickier.
# The pm file for the window should have a static instance_number.
# The first instance number should be 1.
# Pass that instance number into the Pub::WX::Window::become() method.
#
#    The window ID passed in is the 'base' ID of the window
#    so you should be sure to reserve a range in mbeResources.pm
#
#    There must be an explicit command event handler in mbeManager.pm
#    and mbeManagerMisc.pm to instantiate a new one. It is no longer
#    a simple ranged window command.
#
#    The data element must be set to the instance data as well.


package Pub::WX::Window;
use strict;
use Wx qw(:everything);
use Wx::Event qw(EVT_CHILD_FOCUS EVT_CLOSE);
use Pub::Utils;
use base qw(Wx::Window);

our $debug_aw = 2;


sub MyWindow
	# legacy method name was appWindow
	# 'become" a Pub::WX::Window and adds elf to the Pub::WX::Notebook
{
	my ($this,$frame,$book,$id,$label,$data,$instance) = @_;

	$instance ||= 0;
	$this->SetId($id + $instance);

	# set member variables

	$this->{instance} = $instance;
	$this->{id} = $id + $instance;
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

	EVT_CLOSE($this,'onClose');	 # \&onSuperClose);
	EVT_CHILD_FOCUS($this,\&onChildFocus);
}


sub closeSelf
{
	my ($this) = @_;
	my $book = $this->GetParent();
	$book->closeBookPage($this);

}

sub DESTROY
	# debug only
{
	my ($this) = @_;
	my $id = $this->GetId();
	display($debug_aw,0,"DESTROY ".ref($this));
	delete $this->{frame};
}


sub onSuperClose
	# So that classes that implement onClose do not all need their
	# own event handler, we get the event in this base class, and then
	# call the virtual onClose() call chain.
{
	my ($this,$event) = @_;
	display($debug_aw,0,"Pub::WX::Window::onSuperClose($this) called");
	$this->onClose($event);	  # turn it into a virtual call
}


sub onClose
{
	my ($this,$event) = @_;
	my $id = $this->GetId();
	display($debug_aw,0,"Pub::WX::Window::close(".ref($this)."($id) $this->{caption})");
	my $frame = $this->{frame};
	$frame->removePane($this);
}


sub onChildFocus
{
	my ($this,$event) = @_;
	$this->{frame}->setCurrentPane($this);
	display($debug_aw,0,"Pub::WX::Window::onChildFocus($this->{label}) pending_populate=$this->{pending_populate}");
	$event->Skip();
}


sub closeOK
	# Called by framework before closing window.
	# By default it is ok to close a window.
	# Classes that have dirty states should implement this method
	#    and prompt to Abandon Changes? (or save the file), and
	#    return 1 if it is ok to continue with closing this and
	#    subsequent windows.
	#
	# Return 0 to not close the window and stop the loop.
	# Return 1 to close the window and continue the loop.
	# Return -1 to close the window, and continue the loop,
	#    but not call closeOK() any more (abandon all changes).
{
	my ($this,$more_dirty) = @_;
	display($debug_aw,0,"Pub::WX::Window::closeOK($this->{label}) called");
	return 1;
}



sub autoClose
	# By default, windows are closed by calls to onCloseWindows()
	# via the $CLOSE_ALL_PANES and $CLOSE_OTHER_PANES comamnds.
	#
	# Windows that do not wish to be closed in this way should
	# impelement this method and return 0.
	#
	# Note that this window's closeOK() and onClose() methods
	# will still be called the frame onClose(), ignoring this
	# setting.
{
	return 1;
}





sub getConfigStr
	# Return a string to be saved in the ini file
	# representing instance data for this window.
	#
	# The string MAY NOT USE, or INCLUDE '|' vertical bars,
	# or carriages returns, which are the delimiter in the
	# ini file for the Pub::WX::Notebook containing this window.
	#
	# Examples include a client_number, a comma delimited list
	# of expanded tab identiferes, dot and colon delimited strings.
{
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
