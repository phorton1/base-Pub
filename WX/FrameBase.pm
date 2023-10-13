#!/usr/bin/perl
#-------------------------------------------------------------------------
# Pub::WX::FrameBase
#-------------------------------------------------------------------------

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

	# PRH - invariantly create the notebook, add page if needed
	# and call Update();

	$this->{book} = Pub::WX::Notebook->new($app_frame, $instance);
	$this->{book}->AddPage( $page, $page->{label}, 0) if $page;
	$this->{manager}->Update();

    # register event handlers

	EVT_CLOSE($this, 'onCloseFrame');  # pure virtual ... note use of quotes

}	# frameBase()



sub DESTROY
{
	my ($this) = @_;
	display($dbg_fb,0,"DESTROY Pub::WX::FrameBase("._def($this->{instance}).")");
	return;

	if ($this->{book})
	{
		$this->{book}->DESTROY();
		$this->{book} = '';
	}
	if ($this->{manager})
	{
		display($dbg_fb+1,1,"Pub::WX::FrameBase::DESTROY() deleting this->{manager}");
		$this->{manager}->UnInit();
		delete $this->{manager};
	}
}





1;
