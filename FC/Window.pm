#!/usr/bin/perl
#------------------------------------------------------------
# fileClientWindow
#------------------------------------------------------------
# Creates a connection (ClientSession) to a SerialBridge
# Handles asyncrhonouse messages from the SerialBridge
# Is assumed to be Enabled upon connection.

#    EXIT - close the window, and on the last window, closes the App
#    DISABLE/ENABLE - posts a RED or GREEN message and enables or
#    disables the remote pane


package Pub::FC::Window;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_SIZE
	EVT_CLOSE );
use Pub::Utils;
use Pub::WX::Window;
use Pub::FS::ClientSession;		# for $DEFAULT_PORT
use Pub::FC::Pane;
use Pub::FC::Prefs;
use Pub::FC::Resources;
use Pub::FC::PaneThread;
use Pub::FC::PaneCommand;
use base qw(Wx::Window Pub::WX::Window);


my $dbg_fcw = 0;


my $PAGE_TOP = 30;
my $SPLITTER_WIDTH = 10;
my $INITIAL_SPLITTER = 460;

my $instance = 0;

my $title_font = Wx::Font->new(9,wxFONTFAMILY_DEFAULT,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);
my $color_red  = Wx::Colour->new(0xc0 ,0x00, 0x00);  # red


sub getBestPaneName
	# getAppFrame()has all the panes
	# same for the concept of the active frame ...
{
	my ($this,$name) = @_;
	$name ||= 'untitled';
	display(0,0,"getBestPaneName($name)");

	my %other_nums;
	my $app_frame = getAppFrame();
    for my $pane (@{$app_frame->{panes}})
	{
		my $other_name = $pane->{name};
		display(0,1,"other_name=$other_name");

		if ($other_name =~ /^$name(.*)$/)
		{
			my $with_parens = $1 || '';
			my $other_num = $with_parens =~ /^\((\d+)\)$/ ? $1 : 0;
			display(0,2,"other_num=$other_num");
			$other_nums{$other_num} = 1;
		}
	}

	my $num = 0;
	while ($other_nums{$num}) {$num++};

	$name .= "($num)" if $num;
	return $name;
}


sub getWinConnection
{
	my ($this) = @_;
	return $this->{connection};
}


#---------------------------
# new
#---------------------------

sub new
	# the 'data' member is the name of the connection information
{
	my ($class,$frame,$id,$book,$connection) = @_;

	if (!$connection)
	{
		error("No connection specified");
		return;
	}

	my $this = $class->SUPER::new($book,$id);
	my $name = $this->getBestPaneName($connection->{connection_id});

	$instance++;
	display($dbg_fcw+1,0,"new FC::Window($name) instance=$instance");
	$this->MyWindow($frame,$book,$id,$name,$connection,$instance);
	$this->{name} = $name;

	$this->{connection} = $connection;
    $this->{follow_dirs} = Wx::CheckBox->new($this,-1,'follow dirs',[10,5],[-1,-1]);

	my $ctrl1 = Wx::StaticText->new($this,-1,'',[100,5]);
	$ctrl1->SetFont($title_font);
	my $ctrl2 = Wx::StaticText->new($this,-1,'',[$INITIAL_SPLITTER + 10,5]);
	$ctrl2->SetFont($title_font);

	my $params0 = $connection->{params}->[0];
	my $params1 = $connection->{params}->[1];
	$params0->{pane_num} = 0;
	$params1->{pane_num} = 1;
	$params0->{enabled_ctrl} = $ctrl1;
	$params1->{enabled_ctrl} = $ctrl2;

    $this->{splitter} = Wx::SplitterWindow->new($this, -1, [0, $PAGE_TOP]); # ,[400,400], wxSP_3D);
    my $pane1 = $this->{pane1} = Pub::FC::Pane->new($this,$this->{splitter},$params0);
    my $pane2 = $this->{pane2} = Pub::FC::Pane->new($this,$this->{splitter},$params1);

	if (!$pane1 || !$pane2)
	{
		error("Could not create pane1("._def($pane1)." or pane2("._def($pane2).")");
		return;
	}

    $this->{splitter}->SplitVertically($pane1,$pane2,$INITIAL_SPLITTER);

	$pane1->{other_pane} = $pane2;
	$pane2->{other_pane} = $pane1;

    $this->doLayout();

	$pane1->setContents();
	$pane2->setContents();

	$this->populate();

    # Finished

	EVT_CLOSE($this,\&onClose);
    EVT_SIZE($this,\&onSize);
	return $this;
}


sub populate
{
	my ($this) = @_;
	if (!$this->{pane1}->{thread} &&
		!$this->{pane2}->{thread})
	{
		$this->{pane1}->populate(1);
		$this->{pane2}->populate(1);
	}
}


sub onClose
{
	my ($this,$event) = @_;
	display($dbg_fcw,-1,"FC::Window::onClose(".scalar(@{$this->{frame}->{panes}}).") called");
	$this->{pane1}->onClose($event);
	$this->{pane2}->onClose($event);
	if ($this->{connection}->{connection_id} eq 'buddy' &&
		@{$this->{frame}->{panes}} == 0)
	{
		# no warnings 'threads';
			# tries to eliminate Perl exited with XXX threads running
			# if we don't use detach in ThreadedSession.pm
		display($dbg_fcw,-1,"Exiting fileClient(buddy) as last window");
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




1;
