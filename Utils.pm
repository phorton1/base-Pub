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
sub is_win { return $^O eq "MSWin32" ? 1 : 0 }
use Cwd;
use JSON;
use Date::Calc;
use MIME::Base64;
use Time::Local;
use Time::HiRes qw(sleep time);
use Scalar::Util qw(blessed);
use if is_win, 'Cava::Packager';
use if is_win, 'Win32::Console';
use if is_win, 'Win32::DriveInfo';
use if is_win, 'Win32::Mutex';
use if is_win, 'Win32::Process';


our $debug_level = 0;
my $dbg_json = 1;

# storage only global variables set elsewhere

our $login_name = '';

# common constants

our $SSDP_PORT  = 1900;
our $SSDP_GROUP = '239.255.255.250';

BEGIN
{
 	use Exporter qw( import );

	# print "OS=$^O\n";

	# definition of xplat
	#
	# is a method that can be called, or variable accessed
	# that works and has a meaningful semantic cross platform,
	# and that I think should be callable from xplat code.
	#
	# i.e. getAppFrame() is 'cross platform' in that it can be called
	# and will only return a value on a wxWidgets Windows App,
	# and can be called on other platforms to check for that fact.
	#
	# some methods *could* be conidered xplat if they do nothing
	# and 'work' on platforms besides windows: i.e. STDOUT semaphores,
	# but, at this time, I would prefer they are not called, so
	# they are win only.

	my @XPLAT = qw(
		is_win
		$AS_SERVICE

		$debug_level

		$temp_dir
        $data_dir
        $logfile
		$login_name

		setAppFrame
		getAppFrame

		LOG
		error
		warning
		display
    	display_hash
		display_bytes
		display_rect
		setOutputListener

		_def
		_lim
		_plim
		pad
		pad2
		round
		roundTwo
		CapFirst
		prettyBytes

		@monthName
		now
		today
		gmtToLocalTime
		timeToStr
		datePlusDays

        makePath
		pathOf
		filenameFromWin
		getTimestamp
		setTimestamp
        getTextFile
		getTextLines
		printVarToFile
		my_mkdir

		encode64
        decode64
        mergeHash
		hash_to_line
		hash_from_line
		filterPrintable
		parseParamStr

		diskFree
		getMachineId
		getTopWindowId

		url_decode
		my_encode_json
		my_decode_json
		myMimeType

		$SSDP_PORT
        $SSDP_GROUP

		$DISPLAY_COLOR_NONE
        $DISPLAY_COLOR_LOG
        $DISPLAY_COLOR_WARNING
        $DISPLAY_COLOR_ERROR

		$UTILS_COLOR_BLACK
		$UTILS_COLOR_BLUE
		$UTILS_COLOR_GREEN
		$UTILS_COLOR_CYAN
		$UTILS_COLOR_RED
		$UTILS_COLOR_MAGENTA
		$UTILS_COLOR_BROWN
		$UTILS_COLOR_LIGHT_GRAY
		$UTILS_COLOR_GRAY
		$UTILS_COLOR_LIGHT_BLUE
		$UTILS_COLOR_LIGHT_GREEN
		$UTILS_COLOR_LIGHT_CYAN
		$UTILS_COLOR_LIGHT_RED
		$UTILS_COLOR_LIGHT_MAGENTA
		$UTILS_COLOR_YELLOW
		$UTILS_COLOR_WHITE

		$utils_color_to_rgb
	);


	# Windows only methods and symbols will not work, and/or
	# make no sense in a cross platform environment, or that
	# I just don't want to propogate to cross platform code.
	# This includes methods that know about Cava::Packager,
	# which, in my usage, is Win only.
	#
	# Currently artisanUtils.pm uses Pub::Utils qw(!:win_only)

	my @WIN_ONLY = qw(

		$CONSOLE

		$USE_SHARED_LOCK_SEM
		createSTDOUTSemaphore
		openSTDOUTSemaphore
		waitSTDOUTSemaphore
		releaseSTDOUTSemaphore

		$resource_dir
		setStandardTempDir
		setStandardDataDir
		setStandardCavaResourceDir

		execNoShell
		execExplorer
	);

	our @EXPORT = (
		@XPLAT,
		@WIN_ONLY );

	our %EXPORT_TAGS = (win_only  => [@WIN_ONLY]);
}


our $AS_SERVICE:shared=0;
my $app_frame;
	# in multi-threaded WX apps, this is a weird scalar and
	# cannot be used directly from threads

our $temp_dir        = '';
our $data_dir        = '';
our $logfile         = '';
our $resource_dir    = '';

my $CHARS_PER_INDENT = 2;
my $WITH_TIMESTAMPS = 0;
my $WITH_PROCESS_INFO = 1;
my $PAD_FILENAMES = 30;
my $USE_ANSI_COLORS = is_win() ? 0 : 1;
	# by default, we use ANSI colors on linux

# THESE COLOR CONSTANTS JUST HAPPEN TO MATCH WINDOWS
# low order nibble of $attr = foreground color
# high order nibble of $attr = background color
# THEY ARE NOT IN THE SAME ORDER AS THE ANSI COLORS
# and hence $ansi_colors is a lookup array

our $UTILS_COLOR_BLACK            = 0x00;
our $UTILS_COLOR_BLUE             = 0x01;
our $UTILS_COLOR_GREEN            = 0x02;
our $UTILS_COLOR_CYAN             = 0x03;
our $UTILS_COLOR_RED              = 0x04;
our $UTILS_COLOR_MAGENTA          = 0x05;
our $UTILS_COLOR_BROWN            = 0x06;
our $UTILS_COLOR_LIGHT_GRAY       = 0x07;
our $UTILS_COLOR_GRAY             = 0x08;
our $UTILS_COLOR_LIGHT_BLUE       = 0x09;
our $UTILS_COLOR_LIGHT_GREEN      = 0x0A;
our $UTILS_COLOR_LIGHT_CYAN       = 0x0B;
our $UTILS_COLOR_LIGHT_RED        = 0x0C;
our $UTILS_COLOR_LIGHT_MAGENTA    = 0x0D;
our $UTILS_COLOR_YELLOW           = 0x0E;
our $UTILS_COLOR_WHITE            = 0x0F;


# mapping from $UTILS_COLORS to ansi_color constants
# and backwards for clients (i.e. console/buddy) who want
# to display ansi colors in windows apps

our $ansi_color_black 	     	= 30;
our $ansi_color_red 	     	= 31;
our $ansi_color_green 	     	= 32;
our $ansi_color_brown 	 		= 33;
our $ansi_color_blue 	     	= 34;
our $ansi_color_magenta 	 	= 35;
our $ansi_color_cyan 	     	= 36;
our $ansi_color_light_gray 		= 37;
our $ansi_color_gray  	        = 90;
our $ansi_color_light_red 	 	= 91;
our $ansi_color_light_green 	= 92;
our $ansi_color_yellow 			= 93;
our $ansi_color_light_blue  	= 94;
our $ansi_color_light_magenta 	= 95;
our $ansi_color_light_cyan 		= 96;
our $ansi_color_white  			= 97;


our $utils_color_to_ansi = {
	$UTILS_COLOR_BLACK         => $ansi_color_black,
	$UTILS_COLOR_BLUE          => $ansi_color_blue,
	$UTILS_COLOR_GREEN         => $ansi_color_green,
	$UTILS_COLOR_CYAN          => $ansi_color_cyan,
	$UTILS_COLOR_RED           => $ansi_color_red,
	$UTILS_COLOR_MAGENTA       => $ansi_color_magenta,
	$UTILS_COLOR_BROWN         => $ansi_color_brown,
	$UTILS_COLOR_LIGHT_GRAY    => $ansi_color_light_gray,
	$UTILS_COLOR_GRAY          => $ansi_color_gray,
	$UTILS_COLOR_LIGHT_BLUE    => $ansi_color_light_blue,
	$UTILS_COLOR_LIGHT_GREEN   => $ansi_color_light_green,
	$UTILS_COLOR_LIGHT_CYAN    => $ansi_color_light_cyan,
	$UTILS_COLOR_LIGHT_RED     => $ansi_color_light_red,
	$UTILS_COLOR_LIGHT_MAGENTA => $ansi_color_light_magenta,
	$UTILS_COLOR_YELLOW        => $ansi_color_yellow,
	$UTILS_COLOR_WHITE         => $ansi_color_white,
};

our $utils_color_to_rgb = {
	$UTILS_COLOR_BLACK         => 0x000000,
	$UTILS_COLOR_BLUE          => 0x000080,
	$UTILS_COLOR_GREEN         => 0x008000,
	$UTILS_COLOR_CYAN          => 0x008080,
	$UTILS_COLOR_RED           => 0x800000,
	$UTILS_COLOR_MAGENTA       => 0x800080,
	$UTILS_COLOR_BROWN         => 0x000000,
	$UTILS_COLOR_LIGHT_GRAY    => 0xCCCCCC,
	$UTILS_COLOR_GRAY          => 0x444444,
	$UTILS_COLOR_LIGHT_BLUE    => 0x8888FF,
	$UTILS_COLOR_LIGHT_GREEN   => 0x88FF88,
	$UTILS_COLOR_LIGHT_CYAN    => 0x88FFFF,
	$UTILS_COLOR_LIGHT_RED     => 0xFF8888,
	$UTILS_COLOR_LIGHT_MAGENTA => 0xFF88FF,
	$UTILS_COLOR_YELLOW        => 0xFFFF88,
	$UTILS_COLOR_WHITE         => 0xFFFFFF,
};


our $ansi_color_to_utils = {
	$ansi_color_black 			=> $UTILS_COLOR_BLACK,
	$ansi_color_blue	 		=> $UTILS_COLOR_BLUE,
	$ansi_color_green	 		=> $UTILS_COLOR_GREEN,
	$ansi_color_cyan 			=> $UTILS_COLOR_CYAN,
	$ansi_color_red 			=> $UTILS_COLOR_RED,
	$ansi_color_magenta 		=> $UTILS_COLOR_MAGENTA,
	$ansi_color_brown 			=> $UTILS_COLOR_BROWN,
	$ansi_color_light_gray 		=> $UTILS_COLOR_LIGHT_GRAY,
	$ansi_color_gray			=> $UTILS_COLOR_GRAY,
	$ansi_color_light_blue 		=> $UTILS_COLOR_LIGHT_BLUE,
	$ansi_color_light_green	 	=> $UTILS_COLOR_LIGHT_GREEN,
	$ansi_color_light_cyan		=> $UTILS_COLOR_LIGHT_CYAN,
	$ansi_color_light_red		=> $UTILS_COLOR_LIGHT_RED,
	$ansi_color_light_magenta	=> $UTILS_COLOR_LIGHT_MAGENTA,
	$ansi_color_yellow			=> $UTILS_COLOR_YELLOW,
	$ansi_color_white			=> $UTILS_COLOR_WHITE,
};

our $DISPLAY_COLOR_NONE 	= $UTILS_COLOR_LIGHT_GRAY;
our $DISPLAY_COLOR_LOG  	= $UTILS_COLOR_WHITE;
our $DISPLAY_COLOR_WARNING 	= $UTILS_COLOR_YELLOW;
our $DISPLAY_COLOR_ERROR 	= $UTILS_COLOR_LIGHT_RED;


my $STD_OUTPUT_HANDLE = -11;
# my $STD_ERROR_HANDLE = -12;
our $CONSOLE;	# = is_win() ? Win32::Console->new(STD_OUTPUT_HANDLE) : '';
# my $USE_HANDLE = *STDOUT;


my $utils_initialized:shared = 0;


sub initUtils
{
	my ($as_service,$quiet) = @_;
	$as_service ||= 0;
	$quiet ||= 0;
	# print "initUtils($as_service,$quiet) initialized=$utils_initialized AS_SERVICE=$AS_SERVICE\n";
	return if $utils_initialized;

	$AS_SERVICE = $as_service || 0;
	for my $arg (@ARGV)
	{
		$AS_SERVICE = 0 if $arg =~ /NO_SERVICE/i;
	}

	$CONSOLE = is_win() && !$AS_SERVICE ?
		Win32::Console->new($STD_OUTPUT_HANDLE) : '';
	$CONSOLE->OutputCP(1252) if $CONSOLE;
		# use 1252 Code Page to show Latin1 high chars
}


#---------------
# appFrame
#---------------

sub setAppFrame
{
	$app_frame = shift;
}

sub getAppFrame
{
    return $app_frame;
}


#------------------------------
# Standard directories
#------------------------------

sub setStandardTempDir
	# The $temp_dir is not automatically cleaned up.
	#    if you wanna clean it, do it yourself
	# The $temp_dir is not process specific, so programs that need
	#	 process specific files should include the pid $$
	#    of the main process in filenames, for example if you wanted
	#    logfiles per instance, or PID files about children to kill/delete.
{
	my ($app_name) = @_;
	$temp_dir = is_win() && $Cava::Packager::PACKAGED ?
		filenameFromWin($ENV{USERPROFILE})."/AppData/Local/Temp" :
		"/base_data/temp";
	$temp_dir .= "/$app_name" if $app_name;
	my_mkdir($temp_dir) if !-d $temp_dir;
}


sub setStandardDataDir
{
	my ($app_name) = @_;
	$data_dir = is_win() && $Cava::Packager::PACKAGED ?
		filenameFromWin($ENV{USERPROFILE})."/Documents" :
		"/base_data/data";
	$data_dir .= "/$app_name" if $app_name;
	my_mkdir($data_dir) if !-d $data_dir;
}


sub setStandardCavaResourceDir
	# you pass in the development/local path
	# and it is totally replaced if PACKAGED
{
	my ($res_dir) = @_;
	Cava::Packager::SetResourcePath($res_dir);
	$resource_dir = filenameFromWin(Cava::Packager::GetResourcePath());
}


#----------------------------------------------
# STD_OUT Semaphore
#----------------------------------------------
# theorertically xplat, but not published as such

our $USE_SHARED_LOCK_SEM:shared = 0;
my $local_sem:shared = 0;

# win32 only

my $SEMAPHORE_TIMEOUT = 1000;	# ms
my $STD_OUT_SEM;

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
	# returns 1 if they got it, 0 if timeout
{

	return $STD_OUT_SEM->wait($SEMAPHORE_TIMEOUT) if $STD_OUT_SEM;
	return 1;

	if (!$local_sem)
	{
		$local_sem++;
		return 1;
	}
	my $start = time();
	while ($local_sem && time() < $start + $SEMAPHORE_TIMEOUT)
	{
		sleep(0.01);
	}
	if ($local_sem)
	{
		print "\n\nSTDOUT SEMAPHORE TIMEOUT !!!\n\n";
		return 0;
	}
	$local_sem++;
	return 1;
}


sub releaseSTDOUTSemaphore
{
	$STD_OUT_SEM->release() if $STD_OUT_SEM;
	# $local_sem--;
}



#--------------------------------------------
# _output
#--------------------------------------------

my $output_listener;


sub setOutputListener
{
	$output_listener = shift;
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
	my ($utils_color) = @_;
	if (is_win())
	{
		$CONSOLE->Attr($utils_color) if $CONSOLE;
	}
	elsif ($USE_ANSI_COLORS)
	{
		printf "\033[%dm",$utils_color_to_ansi->{$utils_color};
	}
}





sub _output
{
    my ($indent_level,$msg,$color,$call_level) = @_;
    $call_level ||= 0;
    my ($indent,$file,$line,$tree) = get_indent($call_level+1);

	my $dt = $WITH_TIMESTAMPS ? now(1) : '';
	my $dt_padded = $WITH_TIMESTAMPS  ? pad($dt." ",20) : '';

	my $tid = threads->tid();
	my $proc_info = $WITH_PROCESS_INFO ? "($$,$tid)" : '';
	my $proc_info_padded = $WITH_PROCESS_INFO ? pad($proc_info,10) : '';

	my $file_part = "$file\[$line\]";

    $indent = 1-$indent_level if $indent_level < 0;
	$indent_level = 0 if $indent_level < 0;

	my $fill = pad("",($indent+$indent_level) * $CHARS_PER_INDENT);
	my $full_message = $dt_padded.$proc_info_padded.pad($file_part,$PAD_FILENAMES);
	my $header_len = length($full_message);
	$full_message .= $fill.$msg;

	lock($local_sem) if $USE_SHARED_LOCK_SEM;
	my $got_sem = waitSTDOUTSemaphore();

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

	if (!$AS_SERVICE)
	{
		initUtils();

		my $text = '';
		if (1)	# split into indented lines on \rs
		{
			my $started = 0;
			my @lines = split(/\r/,$full_message);
			for my $line (@lines)
			{
				next if !defined($line);
				$line =~ s/^\n|\n$//g;
				$text .= pad("",$header_len).$fill."    " if $started;
				$text .= $line."\r\n";
				$started = 1;
			}
		}
		else
		{
			$text = $full_message."\r\n";
		}

		_setColor($color);

		print $text;
		# print($full_message."\n");
		# print($USE_HANDLE $full_message."\n") :
		# $CONSOLE->Write($full_message."\n") :

		_setColor($DISPLAY_COLOR_NONE);

		$CONSOLE->Flush() if $CONSOLE;
		# sleep(0.1) if $WITH_SEMAPHORES;
	}

	# calling the output listener we detect for failures
	# and return up thru the call chain ....

	if ($output_listener)
	{
		return if !$output_listener->onUtilsOutput($full_message,$color);
	}

	releaseSTDOUTSemaphore() if $got_sem;

	return 1;
}



#---------------------------------------------------------------
# High Level Display Routines
#---------------------------------------------------------------

sub display
	# high level display() routine called by clients.
{
    my ($level,$indent_level,$msg,$call_level,$alt_color) = @_;
	$call_level ||= 0;
	_output($indent_level,$msg,$alt_color?$alt_color:$DISPLAY_COLOR_NONE,$call_level+1)
		if $level <= $debug_level;
	return $msg;
}


sub LOG
{
    my ($indent_level,$msg,$call_level) = @_;
	$call_level ||= 0;
	_output($indent_level,$msg,$DISPLAY_COLOR_LOG,$call_level+1);
	return $msg;
}


sub error
{
    my ($msg,$call_level,$suppress_show) = @_;
	$call_level ||= 0;
	_output(-1,"ERROR - $msg",$DISPLAY_COLOR_ERROR,$call_level+1);

    my $app_frame = getAppFrame();
	$app_frame->showError("Error: ".$msg) if
		!$suppress_show &&
		$app_frame &&
		!threads->tid() &&
		blessed($app_frame) &&
		$app_frame->can('showError');

	return $msg;
}


sub warning
{
    my ($level,$indent_level,$msg,$call_level) = @_;
	$call_level ||= 0;
	_output($indent_level,"WARNING: $msg",$DISPLAY_COLOR_WARNING,$call_level+1)
		if $level <= $debug_level;
	return $msg;
}


sub display_hash
{
	my ($level,$indent,$title,$hash) = @_;
	return if !display($level,$indent,$title,1);
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



sub display_rect
{
	my ($dbg,$level,$msg,$rect) = @_;
	display($dbg,$level,$msg."(".
		$rect->x.",".
        $rect->y.",".
		$rect->width.",".
        $rect->height.")",1);
}


#--------------------------------------
# string and rounding utilities
#--------------------------------------

sub _def
    # oft used debugging utility
{
    my ($var) = @_;
    return defined($var) ? $var : 'undef';
}

sub _lim
{
	my ($s,$len) = @_;
	$s = substr($s,0,$len) if length($s) > $len;
	return $s;
}

sub _plim
{
	my ($s,$len) = @_;
	return pad(_lim($s,$len),$len);
	return $s;
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


sub round
{
	my ($num,$digits) = @_;
	$num = "0.00" if (!defined($num) || ($num eq ""));
	return sprintf("%0.$digits"."f",$num);
}


sub roundTwo
{
	my ($num,$no_zero) = @_;
	if ($no_zero && !$num)
	{
		$num = '';
	}
	else
	{
		$num ||= '0.00';
		$num = sprintf("%0.2f",$num);
		$num = '0.00' if $num eq '-0.00';
	}
	return $num;
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
        $new_name .= " " if $new_name;
        $new_name .= uc(substr($part,0,1)).lc(substr($part,1));
    }
    return $new_name;
}


sub prettyBytes
{
	my ($bytes,$digits) = @_;
	$digits ||= 1;
    $bytes ||= 0;

	my @size = ('', 'K', 'M', 'G', 'T');
	my $ctr = 0;
	for ($ctr = 0; $bytes > 1000; $ctr++)
	{
		$bytes /= 1000; # 1024;
	}
	my $rslt = sprintf("%.$digits"."f", $bytes).$size[$ctr];
    $rslt =~ s/\..*$// if !$size[$ctr];
    return $rslt;
}



#----------------------------------------
# Dates and Times
#----------------------------------------

our @monthName = (
    "January",
    "Februrary",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December" );


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
	my ($gm_time, $with_date) = @_;
	$with_date ||= 0;
    my @time_parts = $gm_time ? gmtime() : localtime();
	my $time =
		pad2($time_parts[2]).':'.
		pad2($time_parts[1]).':'.
		pad2($time_parts[0]);
	$time = today().' '.$time if $with_date;
    return $time;
}


sub gmtToLocalTime
    # takes a GMT time in the format 2013-07-05 12:31:22
    # and returns a local date time in the same format.
{
    my ($ts) = @_;

	# catch bad epoch from unix like system

	$ts = '2000-01-01 01:00:00'
		if $ts lt '2000-01-01 01:00:00';

	if ($ts !~ /(\d\d\d\d).(\d\d).(\d\d).(\d\d):(\d\d):(\d\d)/)
	{
		error("bad timeStamp($ts)");
		return 0;
	}
	my ($year,$mo,$day,$hour,$min,$sec) =
	   ($1,$2-1,$3,$4,$5,$6);
	$mo = 1 if $mo < 0;
	$day = 1 if !int($day);
	my $gm_time = timegm($sec,$min,$hour,$day,$mo,$year);
	my @time_parts = localtime($gm_time);
	return
		($time_parts[5]+1900) .'-'.
		pad2($time_parts[4]+1).'-'.
		pad2($time_parts[3])  .' '.
		pad2($time_parts[2])  .':'.
		pad2($time_parts[1])  .':'.
		pad2($time_parts[0]);
}


sub timeToStr
{
	my ($tm) = @_;
	my @time_parts = localtime($tm);
	my $ts =
		($time_parts[5]+1900).'-'.
		pad2($time_parts[4]+1).'-'.
		pad2($time_parts[3]).' '.
		pad2($time_parts[2]).':'.
		pad2($time_parts[1]).':'.
		pad2($time_parts[0]);
	return $ts;
}


sub datePlusDays
{
    my ($dte,$days) = @_;
    return $dte if ($dte !~ /(\d\d\d\d)-(\d\d)-(\d\d)/);
    my ($year,$month,$day) = Date::Calc::Add_Delta_Days($1,$2,$3,$days);
	$day = "0".$day if (length($day) < 2);
	$month = "0".$month if (length($month) < 2);
    return "$year-$month-$day";
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


sub makePath
    # static, handles '/'
{
    my ($dir,$entry) = @_;
    $dir .= '/' if ($dir !~ /\/$/);
    return $dir.$entry;
}


sub pathOf
{
	my ($full) = @_;
	my $path = '/';
	$path = $1 if $full =~ /^(.*)\//;
	# print "pathOf($full)=$path\n";
	return $path;
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


sub getTextLines
{
    my ($filename) = @_;
	my $text = getTextFile($filename);
	return split(/\n/,$text);
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


sub getTimestamp
	# param = unix format full path to file
	# returns colon delmited GMT timestamp.
	# returns dash/space/colon delimited if pretty
    # returns blank if the file could not be stat'd
    # takes an optional parameter local to return
    # local timestamp
{
	my ($filename,$local) = @_;
	my $ts = '';

	my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
	  	$atime,$mtime,$ctime,$blksize,$blocks) = stat($filename);
    $mtime = '' if (!$mtime);
	if ($mtime ne '')
	{
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
             $local ? localtime($mtime) : gmtime($mtime);
		$year += 1900;
		$mon += 1;
		$ts = sprintf("%04d-%02d-%02d %02d:%02d:%02d",
			$year,$mon,$mday,$hour,$min,$sec);
	}
	return $ts;
}




sub setTimestamp
    # takes a delimited GMT timestamp
    # and sets the given file's modification time.
    # takes an optional parameter to accept a local
    # file modification timestamp
{
	my ($filename,$ts,$local) = @_;
    $filename =~ s/\/$//;
        # for dirs with dangling slashes
	if ($ts !~ /(\d\d\d\d).(\d\d).(\d\d).(\d\d):(\d\d):(\d\d)/)
	{
		error("bad timeStamp($ts)");
		return 0;
	}
	display(9,0,"setTimestamp($filename) = ($6,$5,$4,$3,$2,$1)");
	my $to_time = $local ?
        timelocal($6,$5,$4,$3,($2-1),$1) :
        timegm($6,$5,$4,$3,($2-1),$1);
	return utime $to_time,$to_time,$filename;
}


sub diskFree
	# returns free space for the drive in the given $path.
	# win32: if no DRIVER_LETTER COLON is specified, defaults to C:
{
	my ($path) = @_;
	my $rslt = 0;
	if (is_win())
	{
		my $drive = 'C:';
		$drive = $1 if $path && $path =~ /^([A-Z]:)/i;
		my ($SectorsPerCluster,
			$BytesPerSector,
			$NumberOfFreeClusters,
			$TotalNumberOfClusters,
			$FreeBytesAvailableToCaller,
			$TotalNumberOfBytes,
			$TotalNumberOfFreeBytes) = Win32::DriveInfo::DriveSpace($drive);
		$rslt = $TotalNumberOfFreeBytes;
	}

	# linux, call 'df', parse the lines looking for "Mounted On" eq "/"
	# and return the 3rd integer (4th space delimited part) blocks  * 1024

	else
	{
		my $text = `df`;
		my @lines = split(/\n/,$text);
		for my $line (@lines)
		{
			my @parts = split(/\s+/,$line);
			if ($parts[5] eq '/')
			{
				$rslt = $parts[3] * 1024;
				last;
			}
		}
	}

	display(0,0,"diskFree=$rslt");
	return $rslt;
}


sub my_mkdir
	# recursively make directories for a fully qualified path
{
	my ($path,$is_filename,$dbg_level) = @_;
	$dbg_level ||= 0;

	if ($path !~ /^(\/|[A-Z]:)/i)
	{
		error("unqualified path($path) in my_makedir");
		return 0;
	}

	my @parts = split(/\//,$path);
	pop @parts if $is_filename;
	return 1 if !@parts;
	shift @parts if !$parts[0];
	return 1 if !@parts;

	my $dir = $parts[0] =~ /^[A-Z]:$/i ? shift @parts : '';
	return 1 if !@parts;

	while (@parts)
	{
		$dir .= "/".shift @parts;
		if (!-d $dir)
		{
			display($dbg_level,0,"making directory $dir");
			mkdir $dir;
			if (!-d $dir)
			{
				error("Could not create sub_dir($dir)  for path($path)");
				return 0;
			}
		}
	}

	return 1;
}


sub getMachineId
	# uses $ENV{COMPUTERNAME) on Windows
	# uses hostname command otherwise
{
	# display_hash(0,0,"ENV",\%ENV);
	my $id = is_win() ?
		$ENV{COMPUTERNAME} :
		`hostname`;
	$id =~ s/\s+$//;
    # display(0,0,"getMachineId=$id");
	return $id;
}


#--------------------------------------
# miscellaneous
#--------------------------------------

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



sub hash_to_line
	# RETURN $line INCLUDES \n
{
    my ($hash,$fields) = @_;
    my $line = "";
	my $started = 0;
    for my $field (@$fields)
    {
        $line .= "\t" if $started;
		$started = 1;
        my $val = $hash->{$field};
        $val = "" if (!defined($val));
        $line .= $val;
    }
    return $line."\n";
}


sub hash_from_line
    # inflate a record from a tab delimited record
    # using the passed in field array.
	# removes trailing whitespace
{
    my ($line,$fields) = @_;
	$line =~ s/\s*$//;
	# display(0,0,"hash from line($line)");
	# display(0,1,"fields(".join(',',@$fields).")");

    my $hash = {};
    my @vals = split(/\t/,$line);
    for (my $i=0; $i<@$fields; $i++)
    {
        my $field = $fields->[$i];
		error("undefined field [$i]") if !defined($field);
        my $val = $vals[$i];
        $val = "" if !defined($val);
        $hash->{$field} = $val;
    }
    return $hash;
}


sub parseParamStr
{
	my ($buffer,$debug_level,$who,$delim) = @_;

	$buffer = '' if !defined($buffer);
	$delim ||= '&';
	$who ||= '';
	$debug_level = 5 if !defined($debug_level);

	my $retval = {};
	my @pairs = split(/$delim/,$buffer);
	foreach my $pair (@pairs)
	{
		next if !defined($pair);
		my ($p1,$p2) = split(/=/,$pair);
		next if !defined($p1) || !defined($p2);
		$p2 =~ s/\s*$//;	# remove trailing spaces
		$p1 =~ tr/+/ /;
		$p1 =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C",hex($1))/eg;
		$p2 =~ tr/+/ /;
		$p2 =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C",hex($1))/eg;
		$retval->{$p1} = $p2;
        display($debug_level,1,$who."params($p1)=$p2")
	}
	return $retval;
}


sub encode64
    # returns encode_base64
    # WITHOUT ANY NEWLINES (esp TERMINATING EOL)
{
    my ($s) = @_;
   	my $retval = encode_base64($s);
    $retval =~ s/\n//g;
    return $retval;
}


sub decode64
{
    my ($s) = @_;
    return "" if (!defined($s));
   	return decode_base64($s."\n");
}


sub filterPrintable
    # reduce the string to containing only ascii characters from
    # space to 7f, particularly mapping accented spanish characters
	# to their ascii equivilants. Used to clean strings before putting
	# them in vfoledb, which does not like international characters.
{
    my ($value) = @_;
	# display_bytes(0,0,"value",$value);
	# print "before($value)";

	# certain unicode sequences first

	$value =~ s/\xc3\xba/u/;
	$value =~ s/\xc3\x91/N/;

	# single character replacements
	# from http://ascii-table.com/ascii-extended-pc-list.php

	$value =~ s/\x80/C/g;
	$value =~ s/\x81|\x96|\x97/u/g;
	$value =~ s/\x82|\x88|\x89|\x8A/e/g;
	$value =~ s/\x83|\x84|\x85|\x86|xA0/a/g;
	$value =~ s/\x87/c/g;
	$value =~ s/\x8B|\x8C|\x8D|\xA1/i/g;
	$value =~ s/\x8E|\x8F/A/g;
	$value =~ s/\x90/E/g;
	$value =~ s/\x91/ae/g;
	$value =~ s/\x92/AE/g;
	$value =~ s/\x93|\x94|\x95|\xA2/o/g;
	$value =~ s/\x98/y/g;
	$value =~ s/\x99/O/g;
	$value =~ s/\x9A/U/g;
	$value =~ s/\x9F/f/g;

	# remove any others

    $value =~ s/[^\x20-\x7f]//g;
	# print " after value($value)\n";

    return $value;
}


sub execNoShell
	# This, not system(), is how I figured out how to
	# run an external program without opening a DOS box.
{
	my ($cmd,$path) = @_;
	$path ||= getcwd();
	# chdir($path) ;
	display(1,0,"execNoShell(>$cmd<) path($path)");

	# in the case of quoted commands and parameters,
	# we need to surround the whole command with quotes

	my $p;
	Win32::Process::Create(
		$p,
		"C:\\Windows\\System32\\cmd.exe",
		"/C \"$cmd\"",
		0,
		Win32::Process::CREATE_NO_WINDOW() |
		Win32::Process::NORMAL_PRIORITY_CLASS(),
		$path );
}


sub execExplorer
{
	my ($path) = @_;
	my $win_path = $path;
	$win_path =~ s/\//\\/g;
	display(0,0,"execExplorer($path)");
	`explorer /select,\"$win_path\"`;

	# my $p;
	# Win32::Process::Create(
	# 	$p,
	# 	"C:\\Windows\\explorer.exe",
	# 	"/select \"$win_path\"",
	# 	0,
	# 	# CREATE_NO_WINDOW |
	# 	NORMAL_PRIORITY_CLASS,
	# 	$path );
}


sub getTopWindowId
{
	my ($parent) = @_;
	my $window_id = 0;
	while ($parent)
	{
		my $id = $parent->GetId();
		$window_id = $id if $id > 0;
		$parent = $parent->GetParent();
	}
	return $window_id;
}





sub my_decode_json
{
	my ($json) = @_;
	my $data = '';
	try
	{
		$data = decode_json($json);
	}
	catch Error with
	{
		my $ex = shift;   # the exception object
		error("Could not decode json: $ex");
	};
	return $data;
}


# sub my_encode_json
# {
# 	my ($data) = @_;
# 	my $json = '';
# 	try
# 	{
# 		$json = encode_json($data);
# 	}
# 	catch Error with
# 	{
# 		my $ex = shift;   # the exception object
# 		error("Could not encode json: $ex");
# 	};
# 	return $json;
# }



sub my_encode_json
	# return my json representation of an object
{
	my ($obj) = @_;
	my $response = '';

	display($dbg_json,0,"json obj=$obj ref=".ref($obj),1);

	if ($obj =~ /ARRAY/)
	{
		for my $ele (@$obj)
		{
			$response .= "," if (length($response));
			$response .= my_encode_json($ele)."\n";
		}
		return "[". $response . "]";
	}

	if ($obj =~ /HASH/)
	{
		for my $k (keys(%$obj))
		{
			my $val = $$obj{$k};
			$val = '' if (!defined($val));

			display($dbg_json,1,"json hash($k) = $val = ".ref($val),1);

			if (ref($val))
			{
				display($dbg_json,0,"json recursing");
				$val = my_encode_json($val);
			}
			else
			{
				# convert high ascii characters (é = 0xe9 = 233 decimal)
				# to &#decimal; html encoding.  jquery clients must use
				# obj.html(s) and NOT obj.text(s) to get it to work
				#
				# this is pretty close to what Utils::escape_tag() does,
				# except that it escapes \ to \x5c and does not escape
				# double quotes.

			    $val =~ s/([^\x20-\x7f])/"&#".ord($1).";"/eg;

				# escape quotes and backalashes

				$val =~ s/\\/\\\\/g;
				$val =~ s/"/\\"/g;
				$val = '"'.$val.'"'
					if $val ne '0' &&
					   $val !~ /^(true|false)$/ &&
					   $val !~ /^[1-9]\d*$/;

					# don't quote boolean or 'real' integer values
					#	that are either 0 or dont start with 0
					# true/false are provided in perl by specifically
					# using the strings 'true' and 'false'
			}

			$response .= ',' if (length($response));
			$response .= '"'.$k.'":'.$val."\n";
		}

		return '{' . $response . '}';
	}

	display($dbg_json+1,0,"returning quoted string constant '$obj'",1);

	# don't forget to escape it here as well.

    $obj =~ s/([^\x20-\x7f])/"&#".ord($1).";"/eg;
	return "\"$obj\"";
}


sub url_decode
{
	my ($p) = @_;
	display(9,0,"decode[$p]",1);
	$p =~ s/\+/ /g;
	$p =~ s/%(..)/pack("c",hex($1))/ge;
	display(9,1,"=decoded[$p]",1);
	return $p;
}


sub myMimeType
{
	my ($filename) = @_;
	$filename = lc($filename);
	my @parts = split(/\./,$filename);
	my $ext = pop(@parts);
	return
		$ext eq 'js'  				? 'text/javascript' :
		$ext eq 'css' 				? 'text/css' :
		$ext =~ /^(jpeg|jpg|jpe)$/ 	? 'image/jpeg' :
		$ext eq 'ico' 				? 'image/x-icon' :
		$ext eq 'gif' 				? 'image/gif' :
		$ext eq 'png' 				? 'image/png' :
		$ext =~ /^(html|htm)$/ 		? 'text/html' :
		$ext eq 'json' 				? 'application/json' :

		$ext =~ /^(txt|asc|log)$/ 	? 'text/plain' :

		$ext eq 'doc'				? 'application/msword' :
		$ext eq 'pdf'               ? 'application/pdf' :
		$ext eq 'xls'               ? 'application/vnd.ms-excel' :
		$ext eq 'xlsx'              ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' :
		$ext eq 'tar'               ? 'application/x-tar' :
		$ext eq 'zip'               ? 'application/zip' :


		$ext eq 'mp3'				? 'audio/mpeg' :
		$ext eq 'ico'				? 'image/x-icon' :
		$ext eq 'bmp'				? 'image/bmp' :
		$ext =~ /^(tif|tiff)$/		? 'image/tiff' :
		$ext eq 'rtf'				? 'text/rtf' :
		$ext =~ /^(mpg|mpeg|mpe)$/	? 'video/mpeg' :
		$ext eq 'avi'				? 'video/x-msvideo' :
		'text/plain';
	return 'text/plain';
}


1;
