#!/usr/bin/perl
#---------------------------------------
# ServiceMain.pm
#---------------------------------------
# A standardized "Main" loop for Services.
#
# Standard functions include a 'restartService()'
# method that can be called by client code that
# will restart the Service after 1 second in
# the main loop


package Pub::ServiceMain;
use strict;
use warnings;
use threads;
use threads::shared;
use Error qw(:try);
use IO::Select;
use Pub::Utils;
use Pub::Prefs;
use if is_win, 'Win32::Console';
use if !is_win, 'Term::ReadKey';
use Time::HiRes qw(sleep time);
use sigtrap 'handler', \&onMainSignal, 'normal-signals';


my $dbg_main = 0;

BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
		restartService
	);
};



my $sig_terminate_cb;
my $service_name:shared = '';
my $restart_service:shared = 0;


sub onMainSignal
{
    my ($sig) = @_;			# 15 = SIGTERM, 2=SIGINT
    if ($sig eq 'PIPE')		# 13 = SIGPIPE
    {
		warning(0,0,"onMainSignal() skipping SIG$sig");
		return;
	}

    LOG(-1,"onMainSignal(SIG$sig)");

	my $ignore = $sig_terminate_cb ?
		&$sig_terminate_cb($sig) : 0;

    LOG(-1,"onMainSignal() ".($ignore?"ignoring":"terminating on")." SIG$sig");
	kill 9, $$ if !$ignore;		# 9 == SIGKILL
}




sub restartService
{
	my ($name) = @_;
	LOG(-1,"restartService($name)");
	$service_name = $name;
	$restart_service = time();
}


sub doRestartService
{
	LOG(0,"RESTARTING $service_name SERVICE AS_SERVICE=$AS_SERVICE");
	return if !$AS_SERVICE;
	if (is_win())
	{
		kill 9, $$;		# 9 == SIGKILL
	}
	else
	{
		system("sudo systemctl restart $service_name");
	}
}


sub doRebootMachine
	# added for portForwarder critical timeout
{
	LOG(0,"REBOOTING MACHINE $service_name SERVICE AS_SERVICE=$AS_SERVICE");
	if (is_win())
	{
		return if !$AS_SERVICE;
		kill 9, $$;		# 9 == SIGKILL
	}
	else
	{
		system("sudo reboot");
	}
}



sub main_loop
{
	my ($params) = @_;

	getObjectPref($params,'MAIN_LOOP_SLEEP',0.2);
	getObjectPref($params,'MAIN_LOOP_CB_TIME',1);
	getObjectPref($params,'MAIN_LOOP_CONSOLE',1);

	my $loop_cb = $params->{MAIN_LOOP_CB};
	my $terminate_cb = $sig_terminate_cb = $params->{MAIN_LOOP_TERMINATE_CB};
	my $key_cb ||= $params->{MAIN_LOOP_KEY_CB};

	display_hash($dbg_main,0,"main_loop() params",$params);

	my $LOOP_SLEEP = $params->{MAIN_LOOP_SLEEP} || 0;
	my $LOOP_CB_TIME = $params->{MAIN_LOOP_CB_TIME} || 0;

	my $CONSOLE_IN;
	my $linux_keyboard;

	if (!$AS_SERVICE && $params->{MAIN_LOOP_CONSOLE})
	{
		if (is_win())
		{
			$CONSOLE_IN = Win32::Console->new(
				Win32::Console::STD_INPUT_HANDLE());
			$CONSOLE_IN->Mode(
				Win32::Console::ENABLE_MOUSE_INPUT() |
				Win32::Console::ENABLE_WINDOW_INPUT() );
		}
		else
		{
			$linux_keyboard = 1;
		}
	}

	my $last_loop_cb = 0;
	while (1)
	{
		display($dbg_main+1,0,"main loop");

		try
		{
			if ($AS_SERVICE && $restart_service &&
				time() > $restart_service + 1)
			{
				doRestartService();
			}

			if ($loop_cb && time() >= $last_loop_cb + $LOOP_CB_TIME)
			{
				$last_loop_cb = time();
				&$loop_cb();
			}

			if ($CONSOLE_IN)
			{
				# display_hash(0,0,"mp",$mp);

				if ($CONSOLE_IN->GetEvents())
				{
					my @event = $CONSOLE_IN->Input();
					if (@event &&
						$event[0] &&
						$event[0] == 1) # key event
					{
						my $key = $event[5];

						# print "got event down(" . $event[1] . ") char(" . $event[5] . ")\n";

						if ($key == 3)        # key = ctrl-C
						{
							display($dbg_main,0,"main_loop() got CTRL-C");
							my $ignore = $terminate_cb ?
								&$terminate_cb('CTRL-C') : 0;
							LOG(-1,"main_loop() ".($ignore?"ignoring":"terminating on")." CTRL-C");
							exit(0) if !$ignore;
						}
						elsif ($event[1] == 1)       # key down
						{
							if ($Pub::Utils::CONSOLE && $key == 4)            # CTRL-D
							{
								$Pub::Utils::CONSOLE->Cls();    			  # clear the screen
							}
							elsif ($key_cb)
							{
								&$key_cb($key);
							}
						}
					}
				}
				sleep($LOOP_SLEEP);
			}

			elsif ($linux_keyboard)
			{
				# print "kbd loop\n";

				ReadMode("raw");
				my $char = ReadKey($LOOP_SLEEP, *STDIN);
				ReadMode("normal");

				if (defined($char))
				{
					my $key = ord($char);
					# print "got char($char) key($key)\n";

					if ($key == 3)       # ctrl-C
					{
						display($dbg_main,0,"main_loop() got CTRL-C");
						my $ignore = $terminate_cb ?
							&$terminate_cb('CTRL-C') : 0;
						LOG(-1,"main_loop() ".($ignore?"ignoring":"terminating on")." CTRL-C");
						exit(0) if !$ignore;
					}
					elsif ($key == 4)	# ctrl-D
					{
						 print "\033[2J\n";
					}
					elsif ($key_cb)
					{
						&$key_cb($key);
					}

				}
			}

			# without console

			else
			{
				sleep($LOOP_SLEEP);
			}

		}	# try
		catch Error with
		{
			my $ex = shift;   # the exception object
			display($dbg_main,0,"exception: $ex");
			error($ex);
			my $msg = "!!! main_loop() caught an exception !!!\n\n";
			error($msg);
		};
	}	# while(1)
}	# main_loop()


1;
