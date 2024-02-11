#!/usr/bin/perl
#-----------------------------------------------------
# Pub::DebugMem.pm
#-----------------------------------------------------
# Routines for debugging memory usage


package Pub::DebugMem;
use strict;
use warnings;
use threads;
use threads::shared;
require Win32::API if $ENV{windir};

use Sys::MemInfo;
use Pub::Utils;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
		debug_memory
	);
}

my $high:shared = 0;


if (0)
{
	require Win32::Process::Info;
	display(0,0,"my pid=$$");
	my $pi = Win32::Process::Info->new();
	for my $info ($pi->GetProcInfo())
	{
		display_hash(0,0,"$info",$info)
			if ($info->{ProcessId} eq $$);
	}
}






sub debug_memory
{
	my ($msg) = @_;
	get_debug_memory($msg);
}


sub get_debug_memory
{
	my ($msg) = @_;

	$msg |= '';

	my $total = Sys::MemInfo::totalmem();
	my $free = Sys::MemInfo::freemem();
	my $used = $total - $free;
	$high = $used if $used > $high;
	my $use_high = $high;

	$used = prettyBytes($used,3);
	$total = prettyBytes($total,3);
	$use_high = prettyBytes($high,3);
	my $text = "MEM($msg)";
	# while (length($text) < 35)
	# {
	# 	$text .= ' ';
	# }
	$text .= " $used/$total HIGH=$use_high";

	my $details = '';
	if ($ENV{windir})
	{
		my $hp = getCurrentProcess();
		$text .= " process=".getProcessMemoryInfo($hp);
	}
	else
	{
		$details = getLinuxProcessMemory();
	}

	LOG(-1,"    $text $details",2);
}




sub getCurrentProcess
{
    my $GetCurrentProcess = new Win32::API("Kernel32", "GetCurrentProcess", [], 'N') || return $^E;
    my $hProcess=$GetCurrentProcess->Call();
    return $hProcess;
}

sub getProcessMemoryInfo
	#usage: $memusage=getProcessMemoryInfo($hprocess); or ($memusage,$peakmemusage,$vmsize)=getProcessMemoryInfo($hprocess);
{
    my $hProcess=shift || return;
	my $name=shift;
	my $pid=shift;

	# memory usage is bundled up in ProcessMemoryCounters structure
    # populated by GetProcessMemoryInfo() win32 call

	my $DWORD = 'B32';  # 32 bits
    my $SIZE_T = 'I';   # unsigned integer

    # build a buffer structure to populate

	my $pmem_struct = "$DWORD" x 2 . "$SIZE_T" x 8;
    my $pProcessMemoryCounters = pack($pmem_struct, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

    # GetProcessMemoryInfo is in "psapi.dll"

	my $GetProcessMemoryInfo = new Win32::API('psapi','GetProcessMemoryInfo', ['I', 'P', 'I'], 'I') || return $^E;
    my $DWORD_SIZE = 4;
    my $BufSize = 10 * $DWORD_SIZE;
    my $MemStruct = pack( "L10", ( $BufSize, split( "", 0 x 9 ) ) );
    if ($GetProcessMemoryInfo->Call( $hProcess, $MemStruct, $BufSize ))
	{
		my( @MemStats ) = unpack( "L10", $MemStruct );
		my $memusage=int($MemStats[3]/1024);
		my $peak_memusage=int($MemStats[2]/1024);
		my $vmsize=int($MemStats[8]/1024);
		if (wantarray)
		{
			return ($memusage,$peak_memusage,$vmsize);
		}
		return $memusage;
	}
	return;
}



sub getLinuxProcessMemory
{
	my $page_size_in_kb = 4;
	sysopen(my $fh, "/proc/$$/statm", 0) or die $!;
	sysread($fh, my $line, 255) or die $!;
	close($fh);
	my ($vsz, $rss, $share, $code, $crap, $data, $crap2) = split(/\s+/, $line,  7);

	my $text = '';

	$text .= makeval('virt',$vsz);
	$text .= makeval('rss',$rss);
	$text .= makeval('code',$code);
	$text .= makeval('shared',$share);
	$text .= makeval('data',$data);

	return $text;
}

sub makeval
{
	my ($label,$num) = @_;
	return "$label(".prettyBytes($num * 4096,3).") ";
}

1;
