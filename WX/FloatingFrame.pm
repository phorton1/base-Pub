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

our $dbg_ff = 2;

my $next_floating_frame = 0;


sub new
{
	my ($class,$app_frame,$mouse_x,$mouse_y,$page) = @_;

	my $instance = ++$next_floating_frame;
	my $bname = "content($instance)";
	my $title = "$resources->{app_title}($instance)";
	display($dbg_ff,0,"new Pub::WX::FloatingFrame($instance) page=".($page?$page:'undef'));

    my $size = $app_frame->GetSize();  # [300,300];
	# $size = $page->recommendedSize() if ($page);
	my $this = $class->SUPER::new( $app_frame, -1, $title, [$mouse_x,$mouse_y],
		[int($size->GetWidth() * 0.80),
		 int($size->GetHeight() * 0.80)]);

    $this->{title} = $title;
	$this->{bname} = $bname;
	$this->{init_page} = $page;

	$this->FrameBase($app_frame,$instance);
    return $this;
}


sub onInit
	# called from frameBase()
	# initialize the floating frame with a single content notebook
	# init_page only used as pass thru, get rid of ref to page
{
	my ($this) = @_;
    display($dbg_ff,1,"Pub::WX::FloatingFrame::onInit($this)");
	my $app_frame = $this->{app_frame};
	my $bname = $this->{bname};
	my $page = $this->{init_page};
	my $book = $app_frame->getOpenNotebook($bname,$this);

	$this->{book} = $book;
	$book->{frame} = $this;

	if ($page)
	{
		$book->AddPage( $page, $page->{label}, 0);
		delete $this->{init_page};
	}
    return $this;
}


sub DESTROY
	# debugging only at this time
{
	my ($this) = @_;
	display($dbg_ff,0,"DESTROY Pub::WX::FloatingFrame($this->{instance})");
	return;

	$this->{book}->DESTROY()
		if $this->{book};
	delete $this->{book};
	$this->Pub::WX::FrameBase::DESTROY();
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
			display($dbg_ff,1,"dirty_pane=$pane");
			$book->RemovePage($pane);
			$app_frame->removePane($pane);
			$pane->DESTROY();
		}
	}

	if ($rslt)
	{
		display($dbg_ff,2,"detaching frame($this->{instance}) $book->{name}");
		$this->{manager}->DetachPane($book);
		delete $app_frame->{notebooks}->{$book->{name}};
		$app_frame->deleteFloatingFrame($this->{instance});

		$this->DESTROY();
		$event->Skip();
	}


}	# Pub::WX::FloatingFrame::onCloseFrame



1;
