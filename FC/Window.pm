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
use Pub::FC::Resources;
use Pub::FC::Pane;
use Pub::FC::PaneCommand;
use Pub::FC::PaneThread;
use base qw(Wx::Window Pub::WX::Window);


my $dbg_fcw = 0;


my $PAGE_TOP = 30;
my $SPLITTER_WIDTH = 10;
my $INITIAL_SPLITTER = 460;

my $instance = 0;

my $title_font = Wx::Font->new(9,wxFONTFAMILY_DEFAULT,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);


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
	display($dbg_fcw+1,0,"new FC::Window($data) instance=$instance");
	my $name = "Connection #$instance";

	my $this = $class->SUPER::new($book,$id);
	$this->MyWindow($frame,$book,$id,$name,$data,$instance);

    $this->{name} = $data;    # should already be done
	$this->{follow_dirs} = Wx::CheckBox->new($this,-1,'follow dirs',[10,5],[-1,-1]);

	$this->{enabled_ctrl1} = Wx::StaticText->new($this,-1,'',[60,5]);
	$this->{enabled_ctrl1}->SetFont($title_font);
	$this->{enabled_ctrl2} = Wx::StaticText->new($this,-1,'',[$INITIAL_SPLITTER + 10,5]);
	$this->{enabled_ctrl2}->SetFont($title_font);

	# Create splitter and panes

	my $params1 = {
		pane_num => 1,
		dir => '/junk/data',
		port => 0 };				# equivilant to 'is_local'

	my $params2 = {
		pane_num => 2,
		dir => $ARGV[0] ? '/' : "/junk",
		host => 'localhost',
		port => $ARGV[0] || $DEFAULT_PORT,		# !is_local
		is_bridged => $ARGV[0] ? 1 : 0 };		# will need this later


	if (0)
	{
		$params2 = {
			pane_num => 2,
			dir => '/junk/data',
			port => 0 };			# equivilant to 'is_local'
	}

    $this->{splitter} = Wx::SplitterWindow->new($this, -1, [0, $PAGE_TOP]); # ,[400,400], wxSP_3D);
    $this->{pane1}    = Pub::FC::Pane->new($this,$this->{splitter},$params1);
    $this->{pane2}    = Pub::FC::Pane->new($this,$this->{splitter},$params2);

    $this->{splitter}->SplitVertically(
        $this->{pane1},
        $this->{pane2},$INITIAL_SPLITTER);

    $this->doLayout();

    # Populate

    $this->{pane1}->populate();
    # $this->{pane2}->populate();

    # Finished

	EVT_CLOSE($this,\&onClose);
    EVT_SIZE($this,\&onSize);
	return $this;
}



sub onClose
{
	my ($this,$event) = @_;
	display($dbg_fcw,-1,"FC::Window::onClose(".scalar(@{$this->{frame}->{panes}}).") called");
	$this->{pane1}->onClose($event);
	$this->{pane2}->onClose($event);
	if (@{$this->{frame}->{panes}} == 0)
	{
		no warnings 'threads';
			# tries to eliminate Perl exited with XXX threads running
			# if we don't use detach in ThreadedSession.pm
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




1;
