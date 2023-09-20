#!/usr/bin/perl
#--------------------------------------------------------
# Pub::Utils.pm
#--------------------------------------------------------
# These output routines are definitely not multi-process
# safe, and they do not currently support STD_ERR for services

package Pub::Utils;
use strict;
use warnings;
use threads;
use threads::shared;
use Cava::Packager;
use Win32::Console;
use Win32::Mutex;

our $debug_level = -3;

BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

		$debug_level

		$temp_dir
        $data_dir
        $logfile
		$resource_dir

		createSTDOUTSemaphore
		openSTDOUTSemaphore
		waitSTDOUTSemaphore
		releaseSTDOUTSemaphore

		setAppFrame
		getAppFrame

		setStandardTempDir
		setStandardDataDir
		setStandardCavaResourceDir

		pad
		pad2
		_def
		LOG
		error
		warning
		display
    	display_hash
		display_bytes
		CapFirst

		now
		today

        mergeHash

		filenameFromWin
        getTextFile
		printVarToFile
    );
}

my $app_frame;

our $temp_dir        = '';
our $data_dir        = '';
our $logfile         = '';
our $resource_dir    = '';


my $CHARS_PER_INDENT = 2;
my $WITH_TIMESTAMPS = 0;
my $WITH_PROCESS_INFO = 1;
my $PAD_FILENAMES = 30;

my $fg_lightgray = 7;
my $fg_lightred = 12;
my $fg_yellow = 14;
my $fg_white = 15;

our $DISPLAY_COLOR_NONE 	= 0;
our $DISPLAY_COLOR_LOG  	= 1;
our $DISPLAY_COLOR_WARNING 	= 2;
our $DISPLAY_COLOR_ERROR 	= 3;

my $STD_OUTPUT_HANDLE = -11;
my $CONSOLE_STDOUT = Win32::Console->new($STD_OUTPUT_HANDLE);
# my $STD_ERROR_HANDLE = -12;
# my $CONSOLE_STDERR = Win32::Console->new($STD_OUTPUT_HANDLE);


my $WITH_SEMAPHORES = 0;
my $STD_OUT_SEM;
my $MUTEX_TIMEOUT = 1000;


sub createSTDOUTSemaphore
	# $process_group_name is for a group of processes that
	# share STDOUT.  The inntial process calls this method.
{
	my ($process_group_name) = @_;
	$STD_OUT_SEM = Win32::Mutex->new(0,$process_group_name);
	# print "$process_group_name SEMAPHORE CREATED\n" if $STD_OUT_SEM:
	error("Could not CREATE $process_group_name SEMAPHORE") if !$STD_OUT_SEM;

}

sub openSTDOUTSemaphore
	# $process_group_name is for a group of processes that
	# share STDOUT.  The inntial process calls this method.
{
	my ($process_group_name) = @_;
	$STD_OUT_SEM = Win32::Mutex->open($process_group_name);
	# print "$process_group_name SEMAPHORE OPENED\n" if $STD_OUT_SEM:
	error("Could not OPEN $process_group_name SEMAPHORE") if !$STD_OUT_SEM;
}

sub waitSTDOUTSemaphore
{
	return $STD_OUT_SEM->wait($MUTEX_TIMEOUT) if $STD_OUT_SEM;
}

sub releaseSTDOUTSemaphore
{
	$STD_OUT_SEM->release() if $STD_OUT_SEM;
}






sub setAppFrame
{
	$app_frame = shift;
}


sub getAppFrame
{
    return $app_frame;
}


sub setStandardTempDir
	# The $temp_dir is not automatically cleaned up.
	#    if you wanna clean it, do it yourself
	# The $temp_dir is not process specific, so programs that need
	#	 process specific files should include the pid $$
	#    of the main process in filenames, for example if you wanted
	#    logfiles per instance, or PID files about children to kill/delete.
{
	my ($app_name) = @_;
	$temp_dir = $Cava::Packager::PACKAGED ?
		filenameFromWin($ENV{USERPROFILE})."/AppData/Local/Temp" :
		"/base/temp";
	$temp_dir .= "/$app_name" if $app_name;
	mkdir $temp_dir if !-d $temp_dir;
}


sub setStandardDataDir
{
	my ($app_name) = @_;
	$data_dir = filenameFromWin($ENV{USERPROFILE});
	$data_dir .= "/Documents";
	$data_dir .= "/$app_name" if $app_name;
	mkdir $data_dir if !-d $data_dir;
}


sub setStandardCavaResourceDir
	# you pass in the development/local path
	# and it is totally replaced if PACKAGED
{
	my ($res_dir) = @_;
	Cava::Packager::SetResourcePath($res_dir);
	$resource_dir = filenameFromWin(Cava::Packager::GetResourcePath());
}



#----------------------------------
# Display Utilities
#----------------------------------

sub _def
    # oft used debugging utility
{
    my ($var) = @_;
    return defined($var) ? $var : 'undef';
}


sub pad
{
	my ($s,$len) = @_;
	$len -= length($s);
	while ($len-- > 0)
	{
		$s .= " ";
	}
	return $s;
}


sub pad2
{
	my ($d) = @_;
	$d = '0'.$d if (length($d)<2);
	return $d;
}


sub get_indent
{
    my ($call_level) = @_;

    my $first = 1;
    my $indent = 0;
	my $file = '';
	my $line = 0;

    while (1)
    {
        my ($p,$f,$l,$m) = caller($call_level);
        return ($indent-1,$file,$line) if !$p;

		$f ||= '';
		my @parts = split(/\/|\\/,$f);
		my $fl = pop @parts;

		if ($first)
		{
			$file = $fl;
			$line = $l;
		}

        $first = 0;
        $indent++;
        $call_level++;
    }
}



sub _setColor
{
	my ($color_const) = @_;
	my $attr =
		$color_const == $DISPLAY_COLOR_ERROR ? $fg_lightred :
		$color_const == $DISPLAY_COLOR_WARNING ? $fg_yellow :
		$color_const == $DISPLAY_COLOR_LOG ? $fg_white :
		$fg_lightgray;
	$CONSOLE_STDOUT->Attr($attr);
}



sub _output
{
    my ($indent_level,$msg,$color_const,$call_level) = @_;
    $call_level ||= 0;

    my ($indent,$file,$line,$tree) = get_indent($call_level+1);

	my $tid = threads->tid();
	my $proc_info = $WITH_PROCESS_INFO ? pad("($$,$tid)",10) : '';
	my $dt = $WITH_TIMESTAMPS ? pad(now(1)." ",20) : '';
	my $file_part = pad("$file\[$line\]",$PAD_FILENAMES);

    $indent = 1-$indent_level if $indent_level < 0;
	$indent_level = 0 if $indent_level < 0;

	my $full_message = $dt.$proc_info.$file_part;
	$full_message .= pad("",($indent+$indent_level) * $CHARS_PER_INDENT).$msg;

	if ($logfile)
	{
		if (open(LOGFILE,">>$logfile"))
		{
			print LOGFILE $full_message."\n";
			close LOGFILE;
		}
		else
		{
			print STDERR "!!! Could not open logfile $logfile for writing !!!\n";
			$logfile = '';
		}
	}

	my $got_sem = waitSTDOUTSemaphore();
	_setColor($color_const);
	print STDOUT $full_message."\n";
	_setColor($DISPLAY_COLOR_NONE);
	releaseSTDOUTSemaphore() if $got_sem;

	return 1;
}



#---------------------------------------------------------------
# High Level Display Routines
#---------------------------------------------------------------

sub display
	# high level display() routine called by clients.
{
    my ($level,$indent_level,$msg,$call_level) = @_;
	$call_level ||= 0;
	my $rslt = 1;
	if ($level <= $debug_level)
	{
		$rslt = _output($indent_level,$msg,$DISPLAY_COLOR_NONE,$call_level+1);
	}
	return $rslt;
}


sub LOG
{
    my ($indent_level,$msg,$call_level) = @_;
	$call_level ||= 0;
	my $rslt = _output($indent_level,$msg,$DISPLAY_COLOR_LOG,$call_level+1);
	return $rslt;
}



sub error
{
    my ($msg,$call_level) = @_;
	$call_level ||= 0;
	_output(-1,"ERROR: $msg",$DISPLAY_COLOR_ERROR,$call_level+1);

    my $app_frame = getAppFrame();
	$app_frame->showError("Error: ".$msg) if
		$app_frame && ref($app_frame)=~/HASH/ && $app_frame->can('showError');

	return undef;
}


sub warning
{
    my ($level,$indent_level,$msg,$call_level) = @_;
	$call_level ||= 0;
	my $rslt = 1;
	if ($level <= $debug_level)
	{
		$rslt = _output($indent_level,"WARNING: $msg",$DISPLAY_COLOR_WARNING,$call_level+1)
	}
	return $rslt;
}



sub display_hash
{
	my ($level,$indent,$title,$hash) = @_;
	return if !display($level,$indent,"display_hash($title)",1);
	if (!$hash)
	{
		display($level,$indent+1,"NO HASH",1);
	}
	for my $k (sort(keys(%$hash)))
	{
		my $val = _def($hash->{$k});
		return if !display($level,$indent+1,"$k = '$val'",1);
	}
	return 1;
}


sub display_bytes
	# does not currently work through whole display system
{
	my $max_bytes = 100000;
	my ($dbg,$level,$title,$packet) = @_;
	return if ($dbg > $debug_level);
	my $indent = "";
	while ($level-- > 0) { $indent .= "    "; }
	print "$indent$title";
	$indent .= "   ";
	my $i=0;
    my $chars = '';
	my $start_line = 0;

	for ($i=0; $i<$max_bytes && $i<length($packet); $i++)
	{
        if (($i % 16) == 0)
        {
			my $pos_str = sprintf("%06x (%d)",$start_line,$start_line);
            print "   $chars\n";
            print "$indent";
            $chars = '';
        }

		my $c = substr($packet,$i,1);
		# my $d = (ord($c) != 9) && (ord($c) != 10) && (ord($c) != 13) ? $c : ".";
		my $d = ord($c) >= 32 && ord($c)<=127 ? $c : '.';
        $chars .= $d;

		if (($i % 16) == 0)
		{
			my $pos_str = sprintf("%06x (%d)",$start_line,$start_line);
			$start_line += 16;
            print pad($pos_str,20);
		}

		printf "%02x ",ord($c);
	}

	print "   $chars\n" if ($chars ne "");
	print "..." if ($i < length($packet));
	print "\n" ;
}



sub CapFirst
	# changed implementation on 2014/07/19
{
    my ($name) = @_;
	return '' if !$name;
	$name =~ s/^\s+|\s+$/g/;

    my $new_name = '';
	my @parts = split(/\s+/,$name);
    for my $part (@parts)
    {
        $new_name .= " " if ($name ne "");
        $new_name .= uc(substr($part,0,1)).lc(substr($part,1));
    }
    return $name;
}



#----------------------------------------
# Dates and Times
#----------------------------------------

sub today
    # returns the current local time in the
    # format hh::mm:ss
{
	my @time_parts = localtime();
	my $time =
		($time_parts[5]+1900).'-'.
		pad2($time_parts[4]+1).'-'.
		pad2($time_parts[3]);
    return $time;
}


sub now
    # returns the current local time in the
    # format hh::mm:ss
{
	my ($with_date) = @_;
	$with_date ||= 0;
    my @time_parts = localtime();
	my $time =
		pad2($time_parts[2]).':'.
		pad2($time_parts[1]).':'.
		pad2($time_parts[0]);
	$time = today().' '.$time if $with_date;
    return $time;
}


#----------------------------------------
# Hash Utilities
#----------------------------------------

sub mergeHash
{
	my ($h1,$h2) = @_;
	return if (!defined($h2));
	foreach my $k (keys(%$h2))
	{
        next if (!defined($$h2{$k}));
		display(9,2,"mergeHash $k=$$h2{$k}");
		$$h1{$k} = $$h2{$k};
	}
	return $h1;
}



#----------------------------------------------------------
# File Routines
#----------------------------------------------------------


sub filenameFromWin
{
	my ($filename) = @_;
	$filename =~ s/^.*://;
	$filename =~ s/\\/\//g;
	return $filename;
}


sub getTextFile
{
    my ($ifile,$bin_mode) = @_;
    my $text = "";
    if (open INPUT_TEXT_FILE,"<$ifile")
    {
		#binmode(INPUT_TEXT_FILE, ":utf8");
		binmode INPUT_TEXT_FILE if ($bin_mode);
        $text = join("",<INPUT_TEXT_FILE>);
        close INPUT_TEXT_FILE;
    }
    return $text;
}



sub printVarToFile
{
	my ($isOutput,$filename,$var,$bin_mode) = @_;
	if ($isOutput)
	{
		open OFILE,">$filename" || mydie("Could not open $filename for printing");
		binmode OFILE if ($bin_mode);
		print OFILE $var;
		close OFILE;
	}
}


1;
