#---------------------------------------
# Pub::FS::Prefs.pm
#---------------------------------------
# fileClient preferences
# shared data structure
#	{
#		restore_windows_at_startup => 0,
#	  	default_local_dir => /junk/data/
#	  	default_remote_dir =? /data,
#
#	    Connections =>
#       [
#			{
#				connection_id => 'LocalServerConnection'
#				auto_start => 0
#				session1 => 'local',
#				dir1 => '',
#				session2 => 'LocalServer',
#				dir2 = '',
#           },
#			{
#				connection_id => 'FavoriteConnection',
#				auto_start => 0,
#				session1 => 'local',
#				dir1 => '',
#				session2 => 'FavoriteSession',
#				dir2 = '',
#           },
#			{
#				connection_id => 'LocalServerToFavoriteConnection'
#				auto_start => 0
#				session1 => 'LocalServer',
#				dir1 => '/some/local/path',
#				session2 => 'FavoriteSession',
#				dir2 = 'other_relative',
#           },
#       ],
#	    Sessions =>
#       [
#			{
#				session_id => 'FavoriteSession',
#				dir => 'relative/favorite',
#               port => 5872
#               host -> '192.168.0.123',
#				last_SERVER_ID => ''
#           },
#			{
#				connection_id => 'LocalServer'
#               dir = '',
#               port => 5872
#               host =? ''
#				last_SERVER_ID => ''
#           },
#       ],
#
#       connectionsById => { ... }
#       sessionsById => { ... }
#	};
#
#
#
# Would result in specifying three Connections with the following Panes
#
#	LocalServerConnection
#		Pane1
#			local
#           dir = /junk/data
#       Pane2
#           connected to localhost:5872
#           dir = /data
#	FavoriteConnection
#		Pane1
#			local
#           dir = /junk/data
#       Pane2
#           connected to 192.168.0.123:5872
#           dir = /data/relative/favorite
#	LocalServerToFavoriteConnection
#       Pane1
#           connected to localhost:5872
#           dir = /some/local/path
#       Pane2
#           connected to 192.168.0.123:5872
#           dir = /data/relative/favorite/other_relative


package Pub::FC::Prefs;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;


my $dbg_prefs = 0;

our $prefs_filename;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

		$prefs_filename

		initPrefs
		getPref
		parseCommandLine
		getConnections

		setSessionServerId

		waitPrefs
		releasePrefs
		getPrefs
		writePrefs

    );
};


my $PREFS_MUTEX_NAME:shared = ''; # 'fileClientPrefsMutex';
	# set to '' to turn feature off
my $PREFS_SEM;


my $prefs_dt:shared;
my $prefs:shared = shared_clone({
	restore_windows_at_startup => 0,
	default_local_folder => "/",
	default_start_folder => "/",
	connections => shared_clone([]),
	sessions => shared_clone([]),
	connectionById => shared_clone({}),
	sessionById => shared_clone({}),
});




sub getPref
	# should only be used for unary prefs
{
	my ($id) = @_;
	return shared_clone($prefs->{$id});
}


#----------------------------------------------------
# Mutex
#----------------------------------------------------

sub waitPrefs
{
	return if !$PREFS_MUTEX_NAME;
	return $PREFS_SEM->wait();  # undef == forever
}


sub releasePrefs
{
	return if !$PREFS_MUTEX_NAME;
	return $PREFS_SEM->release();
}


sub startPrefSemaphore
{
	return if !$PREFS_MUTEX_NAME;
	$PREFS_SEM = Win32::Mutex->new(0,$PREFS_MUTEX_NAME);
	error("Could not CREATE $PREFS_MUTEX_NAME SEMAPHORE") if !$PREFS_SEM;
}




#---------------------------------------------
# parseCommandLine()
#---------------------------------------------

sub argError
{
	my ($msg) = @_;
	error($msg);
	releasePrefs();
	return '';
}


sub argOK
{
	my ($connection,$what,$ppane_num,$got_arg,$lval,$rval) = @_;
	if ($got_arg->{$lval})
	{
		$$ppane_num++;
		display($dbg_prefs,0,"ADVANCE PANE_NUM($$ppane_num)");
	}
	$got_arg->{$lval} = 1;
	return argError("too many session parameters")
		if $$ppane_num > 1;
	$connection->{panes}->[$$ppane_num]->{$what} = $rval;
	return $connection->{panes}->[$$ppane_num];
}


sub getSession
{
	my ($pane_num,$session_id) = @_;
	my $retval = {
		pane_num => $pane_num,
		session_id => $session_id,
		host => '',
		port => '',
		dir  => '' };
	return $retval if $session_id eq 'local';
	my $session = $prefs->{sessionById}->{$session_id};
	return argError("Could not find session $session_id")
		if !$session;
	mergeHash($retval,$session);
	return $retval;
}


sub fixSession
{
	my ($session,$dir) = @_;
	$session->{dir} =
		$dir ? $dir :
		$session->{dir} ? $session->{dir} :
		$session->{port} ?
			$prefs->{default_remote_dir} :
			$prefs->{default_local_dir};
}


sub parseCommandLine
	# returns '' or a connection
{
	return '' if !@ARGV;
	waitPrefs();

	my $retval = {
		connection_id => 'untitled',
		dir1 => '',
		dir2 => '',
		panes => [
			getSession(1,'local'),
			getSession(2,'local') ]};

	my $i = 0;
	my %got_arg;
	my $pane_num = 0;
	while ($i<@ARGV)
	{
		my $lval = $ARGV[$i++];
		my $rval = $ARGV[$i++];
		return argError("invalid command line: "._def($lval)." = '"._def($rval)."'")
			if !$lval || !defined($rval);

		if ($lval eq '-c')
		{
			# create unshared copy of the connection

			my $connection = $prefs->{connectionById}->{$rval};
			return argError("Could not find connection($rval)")
				if !$connection;
			$retval = {};
			mergeHash($retval,$connection);
			$retval->{panes} = [];
			$retval->{panes}->[0] = getSession(1,$retval->{session1});
			return if !$retval->{panes}->[0];
			$retval->{panes}->[1] = getSession(2,$retval->{session2});
			return if !$retval->{panes}->[1];
		}
		elsif ($lval eq '-cid')
		{
			$retval->{connection_id} = $rval;
		}
		elsif ($lval eq '-s')
		{
			$pane_num++ if keys %got_arg;
			return argError("too many session parametrs")
				if $pane_num > 1;

			$retval->{panes}->[$pane_num] = getSession(1,$rval);
			return if !$retval->{panes}->[$pane_num];
			$got_arg{$lval} = 1;
		}
		elsif ($lval eq '-sid')
		{
			return if !argOK($retval,'session_id',\$pane_num,\%got_arg,$lval,$rval);
		}
		elsif ($lval eq '-d')
		{
			if ($rval !~ /^\//)
			{
				warning($dbg_prefs,0,"fixing relative dir '$rval'");
				$rval = '/'.$rval;
			}
			return if !argOK($retval,'dir',\$pane_num,\%got_arg,$lval,$rval);
		}
		elsif ($lval eq '-h')
		{
			my $session = argOK($retval,'host',\$pane_num,\%got_arg,$lval,$rval);
			return if !$session;

			if ($session->{host} =~ s/:(.*)$//)
			{
				$session->{port} = $1;
				$got_arg{'-p'} = 1;
			}
		}
		elsif ($lval eq '-p')
		{
			return if !argOK($retval,'port',\$pane_num,\%got_arg,$lval,$rval);
		}
		elsif ($lval eq '-M')
		{
		}
		else
		{
			return argError("Unknown command line params: '$lval $rval'");
		}

	}

	fixSession($retval->{panes}->[0],$retval->{dir1});
	fixSession($retval->{panes}->[1],$retval->{dir2});

	releasePrefs();
	return $retval;
}




#-----------------------------------------------------
# Accessors
#-----------------------------------------------------


sub resolveSession
{
	my ($pane_num,$session_id,$dir) = @_;
	display($dbg_prefs,0,"resolveSession($session_id,$dir)");
	my $retval ={
		pane_num => $pane_num,
		session_id => $session_id,
		port => '',
		host => '' };
	if ($session_id eq 'local')
	{
		$retval->{dir} = $dir ?	$dir :
			$prefs->{default_local_dir};
	}
	else
	{
		my $session = $prefs->{sessionById}->{$session_id};
		if (!$session)
		{
			error("Could not find session $session_id");
			return '';
		}
		mergeHash($retval,$session);
		$retval->{dir} =
			$dir ? $dir :
			$retval->{dir} ? $retval->{dir} :
			$retval->{port} ?
				$prefs->{default_remote_dir} :
				$prefs->{default_local_dir};
	}
	return $retval;
}


sub resolveConnection
{
	my ($connection) = @_;
	my $retval = {
		auto_start => $connection->{auto_start},
		connection_id => $connection->{connection_id},
		panes => [] };
	display($dbg_prefs,0,"resolveConnection($connection->{connection_id})");
	my $val = resolveSession(1,$connection->{session1},$connection->{dir1});
	return '' if !$retval;
	push @{$retval->{panes}},$val;
	$val = resolveSession(2,$connection->{session2},$connection->{dir2});
	return '' if !$retval;
	push @{$retval->{panes}},$val;
	return $retval;
}



sub getConnections
	# returns a list of resolved connections for the
	# Connection dialog box
{
	waitPrefs();
	my $retval = [];							# doesn't need to be shared
	my $connections = $prefs->{connections};
	for my $connection (@$connections)
	{
		push @$retval,resolveConnection($connection);
	}
	releasePrefs();
	return $retval;
}






#-----------------------------------------------------
# initPrefs()
#-----------------------------------------------------

# use Data::Dumper;

sub initPrefs()
	# if init_prefs(multi_process=1) a thread will be started
	# which can be paused via a lock on the %prefs variable
	# and/or via a Mutex between processes.
	#
	# The thread will check if the DT of the prefs have changed,
	# and read the modified prefs into memory if they have.
	#
	# The thread will be locked out and the Mutex gotten while
	# in the Preferences dialog, ensuring that only one process
	# at a time can change the Preferences. When done, the dialog
	# will possibly write the preferences than unlock %prefs
	# and give up the Mutex.
	#
	# Similar protection will wrap the call to setSessionServerId()
	# as it writes the preferences as well.
{
	my ($multi_process) = @_;

	display($dbg_prefs,0,"init_prefs()");

	return if !$prefs_filename;
	waitPrefs();

	my $text = getTextFile($prefs_filename);
	if ($text)
	{
		$prefs = shared_clone({
			connectionById => shared_clone({}),
			sessionById => shared_clone({}) });

		my $array;
		my $by_id;
		my $id_field = '';;
		my $thing = $prefs;
		my @lines = split(/\n/,$text);
		for my $line (@lines)
		{
			$line =~ s/^\s+|\s$//g;
			if ($line =~ /^(connections|sessions)$/)
			{
				my $name = $1;
				display($dbg_prefs+1,1,"$name");
				$array = shared_clone([]);
				$prefs->{$name} = $array;

			}
			elsif ($line =~ /^(connection|session)$/)
			{
				my $name = $1;
				$id_field = $name."_id";
				$by_id = $prefs->{$name."ById"};
				display($dbg_prefs+1,2,"$name id_field=$id_field");
				$thing = shared_clone({});
				push @$array,$thing;
			}
			elsif ($line =~ /^(.+?)\s*=\s*(.*)$/)
			{
				my ($lvalue,$rvalue) = ($1,$2);

				display($dbg_prefs+1,3,"$lvalue <= $rvalue");

				$rvalue ||= '';
				$thing->{$lvalue} = $rvalue;
				if ($lvalue eq $id_field)
				{
					display($dbg_prefs+1,4,"byId($id_field} $thing->{$id_field}");
					$by_id->{$rvalue} = $thing ;
				}
			}
		}
	}
	else
	{
		warning($dbg_prefs,-1,"Empty or missing $prefs_filename");
	}

	# print Dumper($prefs);

	releasePrefs();
}



sub writePrefs
{
	display($dbg_prefs,0,"write_prefs()");

	waitPrefs();
	my $text = '';
	for my $key qw(
		restore_windows_at_startup
		default_local_dir
		default_dir)
	{
		$text .= "$key = $prefs->{$key}\n";
	}

	for my $what qw(connections sessions)
	{
		$text .= "$what\n";
		my $subwhat = $what;
		$subwhat =~ s/s$//;
		for my $thing (@{$prefs->{$what}})
		{
			$text .= "    $subwhat\n";
			for my $key (sort keys (%$thing))
			{
				$text .= "        $key = $thing->{$key}\n";
			}
		}
	}

	if (!printVarToFile(1,$prefs_filename,$text))
	{
		warning($dbg_prefs,-1,"Could not write to $prefs_filename");
	}

	releasePrefs();
}



1;
