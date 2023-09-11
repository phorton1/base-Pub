#!/usr/bin/perl
#-------------------------------------------------------------------------
# Pub::WX::FrameBase
#-------------------------------------------------------------------------

package Pub::WX::FrameBase;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_CLOSE);
use Wx::AUI;
use Pub::Utils;
use Pub::WX::Resources;
use base 'Wx::EvtHandler';



our $dbg_fb = 2;


sub FrameBase
	# mixin method was previously "appFrameBase"
    # returns value from onInit()
{
	my ($this,$app_frame,$instance) = @_;

    $instance = 0 if (!$instance);

	$this->{app_frame} = $app_frame;
	$this->{instance} = $instance;
    $this->{title} = $resources->{app_title} if (!$this->{title});

	display($dbg_fb,0,"Pub::WX::FrameBase($this->{title}) instance=$instance");

	$this->SetIcon(Wx::Icon->new($$resources{app_icon}, wxBITMAP_TYPE_ICO))
        if ($$resources{app_icon});

	# add ourselves to the mainFrame

	if ($instance)
	{
		$app_frame->addFloatingFrame($instance,$this);
	}

	# setup the manager user interface

	$this->{manager} = Wx::AuiManager->new($this,
	    wxAUI_MGR_TRANSPARENT_HINT |
		wxAUI_MGR_ALLOW_FLOATING |
    	wxAUI_MGR_ALLOW_ACTIVE_PANE );

	# call class specific "initialize" method
    # register event handlers

	$this = $this->onInit();
    if ($this)
    {
        $this->{manager}->Update();
        EVT_CLOSE($this, 'onCloseFrame');  # pure virtual ... note use of quotes
    }

    return $this;

}	# frameBase()



sub DESTROY
{
	my ($this) = @_;
	display($dbg_fb,0,"DESTROY Pub::WX::FrameBase("._def($this->{instance}).")");
	if ($this->{manager})
	{
		display($dbg_fb+1,1,"Pub::WX::FrameBase::DESTROY() deleting this->{manager}");
		$this->{manager}->UnInit();
		delete $this->{manager};
	}
}





1;
