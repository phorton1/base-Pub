#!/usr/bin/perl
#---------------------------------------
# ServiceMain.pm
#---------------------------------------
# A standardized "Main" loop for Services


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
use Time::HiRes qw(sleep time);

# I'm gonna start with an unparameterized signal handler
# and later figure out a way to parameterize it, as needed

use sigtrap 'handler', \&onMainSignal, 'normal-signals';

# special handling for specific cases *may* be included in apps

$SIG{CHLD} = 'DEFAULT' if !is_win();
	# Needed to run git from linux service


my $dbg_main = 0;


my $sig_terminate_cb;




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
			$linux_keyboard = IO::Select->new();
			$linux_keyboard->add(\*STDIN);
		}
	}

	my $last_loop_cb = 0;
	while (1)
	{
		display($dbg_main+1,0,"main loop");

		try
		{
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

						if ($key == 3)        # char = 0x03
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
				if ($linux_keyboard->can_read($LOOP_SLEEP||0.0001))		# minimum in case of zero so no block
				{
					my $key;
					$key = sysread(STDIN,$key,1);
					if ($key eq 'd')
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
