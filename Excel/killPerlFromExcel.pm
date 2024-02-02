#!/usr/bin/perl
#
# program to kill Perl tasks
# kills all tasks perl tasks, except itself,
# unless a pid is specified, in which case
# it only kills that process whatever it is ...

use strict;
use warnings;
use Pub::Utils;


sub kill_pid
{
    my ($pid) = @_;
    LOG(0,"killing task $pid");
    my $result = `taskkill /F /T /PID $pid`;   # options /F=force /T=children
    $result =~ s/\s*$//g;
    LOG(0,"kill result=$result");
}



#-----------------------------------------
# main
#-----------------------------------------

my $my_pid = $$;

my ($KILL_PID,$LOG_FILE) = (@ARGV);
$LOG_FILE ||= '';

for my $arg (@ARGV)
{
	$KILL_PID = $arg if $arg =~ /^\d+$/;
}

LOG(0,"killPerlFromExcel($KILL_PID,$LOG_FILE)");

kill_pid($KILL_PID) if $KILL_PID;

# my $found = 0;
# my $tasks = `tasklist`;
# for my $line (sort(split(/\n/,$tasks)))
# {
#      if ($line =~ /prh_perl_IE11\.exe\s+(\d+)\s+Console/ &&
#         $my_pid ne $1)
# 	 {
# 		$found = 1;
# 		kill_pid($1);
# 	 }
# }
# LOG(1,"!! Could not find any prh_perl_IE11.exe's to kill");

LOG(0,"killPerlFromExcel.pm finished");

1;
