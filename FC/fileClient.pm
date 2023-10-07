#!/usr/bin/perl
#-------------------------------------------------------------------------
# the main application object
#-------------------------------------------------------------------------
# PRH - need to setup real data_dir esp for prefs
# PRH - need to implement prefsDlg
# PRH - I think buddy prefs go in fileClient.prefs (it's all one big thing?)

package Pub::FC::AppFrame;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(EVT_MENU);
use Pub::Utils;
use Pub::WX::Frame;
use Pub::FC::Resources;
use Pub::FC::Window;
use Pub::FC::Prefs;
use Pub::FC::ConnectDialog;
use base qw(Pub::WX::Frame);



my $dbg_app = 0;

$temp_dir = '/base/temp';
$prefs_filename = "$temp_dir/fileClient.prefs";


# $data_dir = '/base/temp';
# $logfile = "$temp_dir/fileClient2.log";
# $Pub::WX::AppConfig::ini_file = "$temp_dir/fileClient2.ini";
# unlink $Pub::WX::AppConfig::ini_file;


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
	EVT_MENU($this, $COMMAND_CONNECT, \&commandConnect);

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


sub commandConnect
{
	my ($this,$event) = @_;
	Pub::FC::ConnectDialog->connect();
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
use base 'Wx::App';

openSTDOUTSemaphore("buddySTDOUT") if $ARGV[0];


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
display(0,0,"finished fileClient.pm");




1;
