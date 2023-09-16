#!/usr/bin/perl
#------------------------------------------------------------
# fileClientWindow
#------------------------------------------------------------
# This is a multiple instance window
# who's data is the name of a host
# in fileClientHostDialog.pm.


package Pub::FS::fileClientWindow;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_SIZE
	EVT_IDLE
	EVT_CLOSE );
use Pub::Utils;
use Pub::WX::Window;
use Pub::FS::SessionClient;
use Pub::FS::fileClientResources;
use Pub::FS::fileClientPane;
use Pub::FS::fileClientHostDialog;
use base qw(Wx::Window Pub::WX::Window);


our $dbg_fcw = 0;

my $PAGE_TOP = 40;
my $SPLITTER_WIDTH = 10;

my $instance = 0;


#---------------------------
# new
#---------------------------

sub new
	# the 'data' member is the name of the connection information
{
	my ($class,$frame,$id,$book,$data) = @_;

	if (!$data)
	{
		error("No data (name) specified");
		return;
	}

	$instance++;
	display($dbg_fcw,0,"new fileClientWindow($data) instance=$instance");
	my $name = "Connection #$instance";

	my $this = $class->SUPER::new($book,$id);
	$this->MyWindow($frame,$book,$id,$name,$data,$instance);

    $this->{name} = $data;    # should already be done
    $this->{local_dir} = '/src/Arduino/teensyExpression2/data';
    $this->{remote_dir} = '/';

	my $port = $ARGV[0] || $DEFAULT_PORT;
	display($dbg_fcw,0,"creating session on port($port)");
    $this->{session} = Pub::FS::SessionClient->new({ PORT => $port});
    if (!$this->{session})
    {
        error("Could not create client session!");
        return;
    }

    # Create controls, windows, etc

    $this->{follow_dirs} = Wx::CheckBox->new($this,-1,'follow dirs',[10,10],[-1,-1]);
    $this->{splitter} = Wx::SplitterWindow->new($this, -1, [0, $PAGE_TOP]); # ,[400,400], wxSP_3D);
    $this->{pane1}    = Pub::FS::fileClientPane->new($this,$this->{splitter},$this->{session},1,$this->{local_dir});
    $this->{pane2}    = Pub::FS::fileClientPane->new($this,$this->{splitter},$this->{session},0,$this->{remote_dir});

    $this->{splitter}->SplitVertically(
        $this->{pane1},
        $this->{pane2},460);

    $this->doLayout();

    # Populate

    $this->{pane1}->populate();
    # $this->{pane2}->populate();

    # Finished

	EVT_CLOSE($this,\&onClose);
	EVT_IDLE($this,\&onIdle);
    EVT_SIZE($this,\&onSize);
	return $this;
}



sub onClose
	# the bane of my existence.
	# onClose seems to get called twice,  once before deleting the pane
	# and once after ... I may try to figure that out later, but for
	# now I exit the whole program when it reaches zero
{
	my ($this,$event) = @_;
	display($dbg_fcw,-1,"fileClientWindow::onClose(".scalar(@{$this->{frame}->{panes}}).") called");
	if (@{$this->{frame}->{panes}} == 0)
	{
		display($dbg_fcw,-1,"Exiting Program as last window");
		exit(0);
	}
	$this->SUPER::onClose();
	$event->Skip();
}



sub doLayout
{
	my ($this) = @_;
	my $sz = $this->GetSize();
    my $width = $sz->GetWidth();
    my $height = $sz->GetHeight();
    $this->{splitter}->SetSize([$width,$height-$PAGE_TOP]);
}



sub onSize
{
    my ($this,$event) = @_;
	$this->doLayout();
    $event->Skip();
}



sub onIdle
{
    my ($this,$event) = @_;

	# the EXIT is directed to the window, so we close ourselves,
	# and let the last window close the app.

	my $do_exit = 0;
	if ($this->{session})
	{
		if ($this->{session}->{SOCK})
		{
			my $packet = $this->{session}->get_packet();
			if ($packet)
			{
				display($dbg_fcw,-1,"got packet $packet");
				if ($packet eq 'EXIT')
				{
					display($dbg_fcw,-1,"onIdle() EXIT");
					$do_exit = 1;
				}
			}
		}
		else
		{
			display($dbg_fcw,-1,"fileClientWindow lost SOCKET");
			$do_exit = 1;
		}
	}

	if ($do_exit)
	{
		warning(0,0,"Closing self");
		$this->closeSelf();

		# Wx::App::ExitMainLoop();
		# kill 15,$$;
		# exit(0);
	}
	else
	{
		$event->RequestMore(1);
	}
}


1;
