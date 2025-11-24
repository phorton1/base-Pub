#!/usr/bin/perl
#-------------------------------------------------------------------------
# FloatingFrame
#-------------------------------------------------------------------------


package Pub::WX::FloatingFrame;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::FrameBase;
use base qw(Wx::Frame Pub::WX::FrameBase);

my $dbg_ff = 1;
	# 0 = lifecyle
	# -1 = operations

my $next_floating_frame = 0;


sub new
{
	my ($class,$app_frame,$rect,$page) = @_;

	my $instance = ++$next_floating_frame;
	display($dbg_ff,0,"new Pub::WX::FloatingFrame($instance) page=".($page?$page:'undef'));

	my $this = $class->SUPER::new(
		$app_frame,
		-1,
		'',			# no $title,
		[$rect->x,$rect->y],
		[$rect->width, $rect->height]);;

	$this->FrameBase($app_frame,$this,$page);
	$app_frame->addFloatingFrame($instance,$this);

	my $title = $app_frame->GetLabel();
	$this->SetLabel($title."-$instance");
    return $this;
}



#--------------------------------------------
# methods
#--------------------------------------------

sub onCloseFrame
	# virtual - called from frameBase EVT_CLOSE
	# onClose, we ask all tool panes if we can close
	# and if any says no, we don't process the event
{
	my ($this,$event) = @_;
	my $book = $this->{book};
	my $app_frame = $this->{app_frame};

	display($dbg_ff,0,"Pub::WX::FloatingFrame($this->{instance})::onCloseFrame()");

	my $rslt = 1;
	my $page_count = $book->GetPageCount();
	for (my $idx=0; $idx<$page_count; $idx++)
	{
		my $pane = $book->GetPage($idx);
        if ($pane &&
			($rslt == -1 || ($rslt = $pane->closeOK())))
		{
			display($dbg_ff+1,1,"dirty_pane=$pane");
			$book->RemovePage($pane);
			$app_frame->removePane($pane);
		}
	}

	if ($rslt)
	{
		display($dbg_ff+1,2,"detaching frame($this->{instance}) $book");
		$this->{manager}->DetachPane($book);
		$app_frame->deleteFloatingFrame($this->{instance});
		$event->Skip();
	}


}	# Pub::WX::FloatingFrame::onCloseFrame



1;
