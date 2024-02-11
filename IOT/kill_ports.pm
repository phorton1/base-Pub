#!/usr/bin/perl
#
# This script lives in /home/myiot_user which must have a shell login.
# I had to modify /etc/sudoers (using "visudo" instead of vi) to add the
# following line at the end to allow myiot_user to call netstat and get pids from it
#
#      myiot_user ALL=(root) NOPASSWD: /usr/bin/netstat

use strict;
use warnings;

my $port = $ARGV[0];
die ("NO PORT SPECIFIED") if !$port;
print "kill_ports.pm($port) started\n";

my $text = `sudo /usr/bin/netstat -tulpn`;
# print "COMMAND:/usr/bin/netstat\n$text\n";

my @lines = split("\n",$text);
shift @lines;
for my $line (@lines)
{
	if ($line =~ /:$port.*LISTEN\s+(\d+)\/sshd:/)
	{
		my $pid = $1;
		print "killing process($pid) for port($port)\n";
		kill 9,$pid;
		my $gone_pid = waitpid $pid, 0;  # then check that it's gone
		if (!$gone_pid)		# 0 means it's still running
		{
			print "Could not kill  process($pid) for port($port)\n";
			exit(1);
		}
		print "process($pid) for port($port) killed\n";
		exit 0;
	}
}

print "Could not find process for port($port) to kill\n";


# OLD

if (0)
{
	my $text2 = '';
	my $text1 = `ps -l -u myiot_user`;
	print "PS LIST\n$text1\n";

	my @lines = split("\n",$text1);
	shift @lines;
	for my $line (@lines)
	{
		if ($line =~ /^\d+\s+S\s+\d+\s+(\d+)\s.*\ssshd$/)
		{
			my $pid = $1;
			print "command=kill $pid\n";
			kill 9,$pid;
			my $gone_pid = waitpid $pid, 0;  # then check that it's gone
			print "    gone_pid=$gone_pid\n";
		}
	}
}


print "kill_ports.pm finished\n";


1;
