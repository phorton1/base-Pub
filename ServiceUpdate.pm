#!/usr/bin/perl
#---------------------------------------
# Update.pm
#---------------------------------------
# Check for local and remote GIT changes, allowing
# for UI to choose to "stash" local changes if neeeded.
#
# One or both of these are required on linux to run git from backticks:
#
# 		$SIG{CHLD} = 'DEFAULT' if !is_win();
# 		$SIG{PIPE} = 'IGNORE' if !is_win();
#
# An update is only allowed if the remote machine
# is behind, not ahead, of the github repository.
# Ahead means there is a commit that has not been
# pushed from the remote.
#
# Otherwise there may be staged/or unstaged changes,
# and a stash can be used to get rid of them, or
# no stash is needed and the pull can just proceed.


package Pub::ServiceUpdate;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;

my $DETAILED_RESPONSES = 1;



my $dbg_git = -1;
my $dbg_update = -1;

BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
		$GIT_UP_TO_DATE
		$GIT_NEEDS_STASH
		$GIT_UPDATE_DONE
		$GIT_CANT_UPDATE
		$GIT_ERROR

		git_result_to_text
	);
}

our $GIT_NONE = 0;
	# init value
our $GIT_UP_TO_DATE = 1;
	# No changes needed.
our $GIT_NEEDS_STASH = 2;
	# A stash was required and $do_stash was not specified
our $GIT_UPDATE_DONE = 3;
	# The update was done
our $GIT_CANT_UPDATE = 4;
	# The update cannot complete due to remote commits
our $GIT_ERROR = 5;
	# There was an error calling a git routine

sub git_result_to_text
{
	my ($code) = @_;
	return
		$code == $GIT_UP_TO_DATE 	? 'GIT_UP_TO_DATE' :
		$code == $GIT_NEEDS_STASH 	? 'GIT_NEEDS_STASH' :
		$code == $GIT_UPDATE_DONE 	? 'GIT_UPDATE_DONE' :
		$code == $GIT_CANT_UPDATE 	? 'GIT_CANT_UPDATE' :
		$code == $GIT_ERROR 		? 'GIT_ERROR' :
		'GIT_NONE';
}





sub gitCommand
	# returns 0 on error, 1 on success
	# always sets the $$retval text
	# it is an error if:
	#
	#	the command returns undef
	#	the backtick command exited with a non-zero exit code
	#	$no_blank && the command returns ''
{
	my ($no_blank,$ptext,$repo,$command) = @_;
	display($dbg_git,0,"gitCommand($no_blank,$repo) $command");
	$$ptext = `git -C $repo $command 2>&1`;
	my $exit_code = $?;

	if (!defined($$ptext))
	{
		$$ptext = "ERROR repo($repo) command($command) returned undef\n";
		return 0;
	}
	if ($exit_code)
	{
		$$ptext .= "\n" if $ptext;
		$$ptext = "ERROR repo($repo) command($command) returned exit_code($exit_code)\n$$ptext";
		return 0;
	}
	if ($no_blank && !$$ptext)
	{
		$$ptext = "ERROR repo($repo) command($command) returned blank\n";
		return 0;
	}

	display($dbg_git+1,0,"text=$$ptext");
	return 1;
}




sub updateOne

{
	my ($do_stash,$repo,$report_text) = @_;
	display($dbg_update+1,0,"updateOne($do_stash,$repo)");

	my $text;
	if (!gitCommand(0,\$text,$repo,'remote update'))
	{
		$$report_text .= $text;
		return $GIT_ERROR;
	}

	# git status
	# -b == include branch info
	# --porcelain s== stable simple paraseable result

	if (!gitCommand(1,\$text,$repo,'status -b --porcelain'))
	{
		$$report_text .= $text;
		return $GIT_ERROR;
	}

	# master...origin/master [ahead 1, behind 1]
	# ?? untracked_file
	# _M modified file

	my @lines = split(/\n/,$text);
	my $status_text = shift @lines;

	my $commits = $status_text =~ /\[(.*)\]/ ? $1 : '';
	my $ahead = $commits =~ /ahead (\d+)/ ? $1 : 0;
	my $behind = $commits =~ /behind (\d+)/ ? $1 : 0;
	my $has_changes = @lines;
	my $changes = join("\n",@lines);

	my $msg = "repo($repo) ahead($ahead) behind($behind) has_changes($has_changes) changes=$changes";
	display($dbg_update,0,$msg);

	if ($ahead)
	{
		$$report_text .= "ERROR Can't update repo($repo): it is AHEAD by $ahead commits\n";
		$$report_text .= "$msg\n" if $DETAILED_RESPONSES;
		return $GIT_CANT_UPDATE;
	}

	# We will ignore local changes if no update is needed.
	# but tell them about it

	if (!$behind)
	{
		$$report_text .= "repo($repo) is up to date";
		$$report_text .= ", but note that it has $has_changes local changes"
			if $has_changes;
		$$report_text .= "\n";
		$$report_text .= "$changes\n"
			if $has_changes && $DETAILED_RESPONSES;
		return $GIT_UP_TO_DATE;
	}

	# We now know the repository is behind and can be updated

	if ($changes)
	{
		if (!$do_stash)
		{
			$$report_text .= "repo($repo) has $has_changes local changes that need to be stashed\n";
			$$report_text .= "$changes\n" if  $DETAILED_RESPONSES;
			return $GIT_NEEDS_STASH;
		}
		else
		{
			$$report_text .= "repo($repo) stashing $has_changes local_changes\n";
			$$report_text .= "$changes\n" if  $DETAILED_RESPONSES;
			if (!gitCommand(1,\$text,$repo,'stash'))
			{
				$$report_text .= $text;
				return $GIT_ERROR;
			}
		}
	}

	# DO THE PULL

	if (!gitCommand(1,\$text,$repo,'pull'))
	{
		$$report_text .= $text;
		return $GIT_ERROR;
	}

	$$report_text .= $text; # if $DETAILED_RESPONSES;
	$$report_text .= "UPDATE($repo) DONE\n";
	return $GIT_UPDATE_DONE;
}






sub doSystemUpdate
	# returns text for one of the $GIT_CONSTANTS and a possibly long messzge in $$ptext.
	# if !$do_stash two loops may be done, one to see if a stash is needed,
	# and the second to do the stash.
	#
	# By convention, with all responses 200, caller should return something
	# on the first line that indicates whether there was an ERROR, NOTHING_TO_DO,
	# or RESTARTING.
{
	my ($ptext,$do_stash,$repos) = @_;
	LOG(-1,"UPDATING SYSTEM($do_stash,".join(' ',@$repos).")");

	$$ptext = '';

	# first loop checks for stash needed

	my $highest = $GIT_NONE;
	if (!$do_stash)
	{
		for my $repo (@$repos)
		{
			my $rslt = updateOne(0,$repo,$ptext);
			if ($rslt > $highest)
			{
				$highest = $rslt;
				if ($highest >= $GIT_CANT_UPDATE)
				{
					display($dbg_update+1,0,"stash_loop returning($highest)=".git_result_to_text($highest));
					return $highest;
				}
			}
		}
		if ($highest >= $GIT_NEEDS_STASH)
		{
			display($dbg_update+1,0,"!do_stash returning NEEDS_STASH($highest)");
			return $highest;
		}
		if ($highest == $GIT_UP_TO_DATE)
		{
			display($dbg_update+1,0,"!do_stash returning UP_TO_DATE");
			return $highest;
		}
	}

	# second loop does the updates

	for my $repo (@$repos)
	{
		my $rslt = updateOne(1,$repo,$ptext);
		if ($rslt > $highest)
		{
			$highest = $rslt;
			if ($highest >= $GIT_CANT_UPDATE)
			{
				display($dbg_update+1,0,"update_loop returning($highest)=".git_result_to_text($highest));
				return $highest;
			}
		}
	}

	display($dbg_update,0,"doSystemUpdate() returning(highest)=".git_result_to_text($highest));
	return $highest;
}


1;
