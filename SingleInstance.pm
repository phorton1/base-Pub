#!/usr/bin/perl
#---------------------------------------------
# Pub::SingleInstance.pm
#---------------------------------------------
# ONE COPY OF THIS APPLICATION ON THIS MACHINE.
#
# Not the same question as "is the http port free", and deliberately not
# part of Pub::HTTP::ServerBase.  A port is one resource an application
# might contend for; the others - an ini, a database, a log, a cache being
# written by two writers - have nothing to do with http, and an application
# with no server at all may still want to be the only one running.  The
# check also has to happen BEFORE a server is started or a worker pool is
# spawned, which is the wrong side of ServerBase to live on.
#
# flock, NOT A PID FILE, and not Win32::Mutex.
#
# The property that matters is that the lock is released BY THE OPERATING
# SYSTEM when the process ends, however it ends.  A pid file cannot promise
# that: a crash leaves it behind, and the next start has to decide whether
# a recorded pid is a live instance or a corpse - which is unanswerable
# once pids are reused.  flock has no such hole, and unlike Win32::Mutex it
# is the same call everywhere, which matters because some of these
# applications run on linux as well as windows.
#
# THE HANDLE IS HELD FOR THE LIFE OF THE PROCESS.  It is a file scoped
# global here on purpose: if it went out of scope the lock would drop and
# a second instance could start while the first was still running.
#
# KEYED BY $temp_dir, WHICH SEPARATES DEVELOPMENT FROM INSTALLED FOR FREE.
# The two already resolve to different roots, so a development copy and an
# installed copy are different instances and may run together, which is
# what an author wants and a user never notices.  No second naming scheme
# to keep in step.
#
# WHAT IT DOES NOT DO IS DECIDE WHAT FAILURE MEANS.  It reports through
# error(), which puts the message in the log and, if the application has
# registered a frame with Pub::Utils, in front of the user - and does
# neither harmfully when the application is headless.  Whether a refusal
# ends the program is the caller's business.
#
#	use Pub::SingleInstance;
#
#	if (!takeSingleInstance($appName))
#	{
#		# already reported; decide what it means
#	}

package Pub::SingleInstance;
use strict;
use warnings;
use Fcntl qw( :flock O_RDWR O_CREAT );
use Pub::Utils;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		takeSingleInstance
		releaseSingleInstance
		singleInstancePath
	);
}


our $dbg_single = 1;
	# 1 = quiet
	# 0 = the path and the outcome


my $lock_fh;		# held open for the life of the process, on purpose
my $lock_path;


sub singleInstancePath
{
	my ($name) = @_;
	$name ||= 'app';
	$name =~ s/[^A-Za-z0-9_.-]/_/g;
	return "$temp_dir/$name.instance";
}


sub takeSingleInstance
	# Returns 1 if this process may run, 0 if another instance holds it.
	#
	# opts: allow_second   take it if you can, but do not refuse if you
	#                      cannot - for the case an author deliberately
	#                      wants two copies up at once
	#       quiet          do not call error() on refusal; the caller
	#                      will report it in its own words
{
	my ($name,$opts) = @_;
	$opts ||= {};

	return 1 if $lock_fh;		# already held by this process

	$lock_path = singleInstancePath($name);

	if (!sysopen($lock_fh,$lock_path,O_RDWR|O_CREAT))
	{
		# COULD NOT EVEN OPEN THE FILE, which says nothing about whether
		# another instance is running.  Refusing to start over a lock file
		# that cannot be created would turn a permissions problem into a
		# dead application, so this is a warning and the answer is yes.

		$lock_fh = undef;
		warning(0,0,"SingleInstance: could not open $lock_path - $! ".
			"(continuing without the guard)");
		return 1;
	}

	if (!flock($lock_fh,LOCK_EX|LOCK_NB))
	{
		close $lock_fh;
		$lock_fh = undef;

		return 1 if $opts->{allow_second};

		error("Only one instance of $name may run at a time.")
			if !$opts->{quiet};

		display($dbg_single,0,"SingleInstance: REFUSED, $lock_path is held");
		return 0;
	}

	# The pid is written for a human reading the directory, and is never
	# read back by this module - the LOCK is the fact, the pid is a note.

	truncate($lock_fh,0);
	seek($lock_fh,0,0);
	print $lock_fh "$$\n";
	$lock_fh->flush() if $lock_fh->can('flush');

	display($dbg_single,0,"SingleInstance: took $lock_path as pid $$");
	return 1;
}


sub releaseSingleInstance
	# Optional.  The operating system does this when the process ends,
	# which is the whole point of using a lock rather than a pid file, so
	# this exists only for an application that wants to hand off cleanly
	# before it exits.
{
	return if !$lock_fh;
	flock($lock_fh,LOCK_UN);
	close $lock_fh;
	$lock_fh = undef;
	display($dbg_single,0,"SingleInstance: released $lock_path");
}


1;
