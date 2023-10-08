#!/usr/bin/perl
#-------------------------------------------------------------------------
# the main application object
#-------------------------------------------------------------------------
# Currently uses 'buddy' standard data dir to hold the fileClient.prefs file

# PRH - need to implement prefsDlg
# PRH - I think buddy prefs go in fileClient.prefs (it's all one big thing?)

package Pub::FC::AppFrame;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(EVT_MENU_RANGE);
use Pub::Utils;
use Pub::WX::Frame;
use Pub::FC::Resources;
use Pub::FC::Window;
use Pub::FC::Prefs;
use Pub::FC::PrefsDialog;
use Pub::FC::ConnectDialog;
use base qw(Pub::WX::Frame);

my $dbg_app = 0;

sub new
{
	my ($class, $parent) = @_;
	my $this = $class->SUPER::new($parent);
	return $this;
}


sub onInit
    # derived classes MUST call base class!
{
    my ($this) = @_;

    return if !$this->SUPER::onInit();
	EVT_MENU_RANGE($this, $COMMAND_PREFS, $COMMAND_CONNECT, \&onCommand);

	warning($dbg_app,-1,"FILE CLIENT STARTED WITH PID($$)");

	# yet another extreme weirdness.
	# before and after messages have color and no timestamps
	# messages IN initPrefs() have no color and have timestamps
	# as-if Utils.pm has not been parsed.  Must be some kind of
	# magic in WX with eval() or mucking around with Perl itself.

	return if !initPrefs();

	# same with (and especially) the call to parseCommandLine
	# setAppFrame($this);

	if (@ARGV)
	{
		my $connection = parseCommandLine();
		return if !$connection;
		$this->createPane($ID_CLIENT_WINDOW,undef,$connection)
	}
	else
	{
		my @start_connections;
		return if !waitPrefs();
		for my $shared_connection (@{getPrefs()->{connections}})
		{
			push @start_connections,getPrefConnection(
				$shared_connection->{connection_id})
				if $shared_connection->{auto_start};
		}
		releasePrefs();
		for my $connection (@start_connections)
		{
			$this->createPane($ID_CLIENT_WINDOW,undef,$connection);
		}
	}

    return $this;
}


sub createPane
	# we never save/restore any windows
	# so config_str is unused
{
	my ($this,$id,$book,$data,$config_str) = @_;
	display($dbg_app+1,0,"fileClient::createPane($id)".
		" book="._def($book).
		" data="._def($data));

	if ($id == $ID_CLIENT_WINDOW)
	{
		return error("No data specified in fileClient::createPane()") if !$data;
	    $book = $this->getOpenDefaultNotebook($id) if !$book;
        return Pub::FC::Window->new($this,$id,$book,$data);
    }
    return $this->SUPER::createPane($id,$book,$data,$config_str);
}


sub onCommand
{
	my ($this,$event) = @_;
	my $id = $event->GetId();

	Pub::FC::ConnectDialog->connect() if $id == $COMMAND_CONNECT;
	Pub::FC::PrefsDialog->editPrefs() if $id == $COMMAND_PREFS;
}



#----------------------------------------------------
# CREATE AND RUN THE APPLICATION
#----------------------------------------------------

package Pub::FC::App;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::WX::Main;
use Pub::FC::Prefs;
use base 'Wx::App';

# Stuff to begin my 'standard' application

$debug_level = -5 if Cava::Packager::IsPackaged();
	# set release debug level
openSTDOUTSemaphore("buddySTDOUT") if $ARGV[0];
setStandardDataDir("buddy");
$prefs_filename = "$data_dir/fileClient.prefs";


my $frame;


sub OnInit
{
	$frame = Pub::FC::AppFrame->new();
	if (!$frame)
	{
		warning(0,0,"unable to create frame");
		return undef;
	}
	$frame->Show( 1 );
	display(0,0,"fileClient.pm started");
	return 1;
}

my $app = Pub::FC::App->new();
Pub::WX::Main::run($app);

# This little snippet is required for my standard
# applications (needs to be put into)

display(0,0,"ending fileClient.pm ...");
$frame->DESTROY() if $frame;
$frame = undef;
# display(0,0,"finished fileClient.pm");
print "fileClient closed\r\n";



1;
