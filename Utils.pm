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
use Scalar::Util qw(blessed);
use Cava::Packager;
use MIME::Base64;
use Time::Local;
use Time::HiRes qw(sleep time);
use Win32::Console;
use Win32::DriveInfo;
use Win32::Mutex;


our $debug_level = 0;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

		$USE_CONSOLE
		$debug_level

		$temp_dir
        $data_dir
        $logfile
		$resource_dir

		setAppFrame
		getAppFrame

		setStandardTempDir
		setStandardDataDir
		setStandardCavaResourceDir

		$WITH_SEMAPHORES
		$USE_SHARED_LOCK_SEM
		createSTDOUTSemaphore
		$HOW_SEMAPHORE_WIN32
		$HOW_SEMAPHORE_LOCAL
		openSTDOUTSemaphore
		waitSTDOUTSemaphore
		releaseSTDOUTSemaphore

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
		gmtToLocalTime

        makePath
		pathOf
		filenameFromWin
		setTimestamp
        getTextFile
		printVarToFile
		my_mkdir
		diskFree
		getMachineId

		encode64
        decode64
        mergeHash

		$display_color_black
		$display_color_blue
		$display_color_green
		$display_color_cyan
		$display_color_red
		$display_color_magenta
		$display_color_brown
		$display_color_light_gray
		$display_color_gray
		$display_color_light_blue
		$display_color_light_green
		$display_color_light_cyan
		$display_color_light_red
		$display_color_light_magenta
		$display_color_yellow
		$display_color_white

		$DISPLAY_COLOR_NONE
        $DISPLAY_COLOR_LOG
        $DISPLAY_COLOR_WARNING
        $DISPLAY_COLOR_ERROR
    );
}

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

my $fg_lightgray = 7;
my $fg_lightred = 12;
my $fg_yellow = 14;
my $fg_white = 15;


our $display_color_black            = 0x00;
our $display_color_blue             = 0x01;
our $display_color_green            = 0x02;
our $display_color_cyan             = 0x03;
our $display_color_red              = 0x04;
our $display_color_magenta          = 0x05;
our $display_color_brown            = 0x06;
our $display_color_light_gray       = 0x07;
our $display_color_gray             = 0x08;
our $display_color_light_blue       = 0x09;
our $display_color_light_green      = 0x0A;
our $display_color_light_cyan       = 0x0B;
our $display_color_light_red        = 0x0C;
our $display_color_light_magenta    = 0x0D;
our $display_color_yellow           = 0x0E;
our $display_color_white            = 0x0F;

our $DISPLAY_COLOR_NONE 	= $display_color_light_gray;
our $DISPLAY_COLOR_LOG  	= $display_color_white;
our $DISPLAY_COLOR_WARNING 	= $display_color_yellow;
our $DISPLAY_COLOR_ERROR 	= $display_color_light_red;


my $STD_OUTPUT_HANDLE = -11;
my $STD_ERROR_HANDLE = -12;
our $USE_CONSOLE = Win32::Console->new($STD_OUTPUT_HANDLE);
# my $USE_HANDLE = *STDOUT;



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
	$temp_dir = $Cava::Packager::PACKAGED ?
		filenameFromWin($ENV{USERPROFILE})."/AppData/Local/Temp" :
		"/base/temp";
	$temp_dir .= "/$app_name" if $app_name;
	mkdir $temp_dir if !-d $temp_dir;
}


sub setStandardDataDir
{
	my ($app_name) = @_;
	$data_dir = $Cava::Packager::PACKAGED ?
		filenameFromWin($ENV{USERPROFILE})."/Documents" :
		"/base/data";
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


#----------------------------------------------
# STD_OUT Semaphore
#----------------------------------------------
# get really wonky in buddy ...

our $HOW_SEMAPHORE_LOCAL = 1;
our $HOW_SEMAPHORE_WIN32 = 2;

our $WITH_SEMAPHORES:shared = 0; # $HOW_SEMAPHORE_LOCAL;  #$HOW_SEMAPHORE_WIN32; 	# $HOW_SEMAPHORE_LOCAL;

my $SEMAPHORE_TIMEOUT = 1000;	# ms
my $STD_OUT_SEM;
my $local_sem:shared = 0;

our $USE_SHARED_LOCK_SEM:shared = 0;


sub createSTDOUTSemaphore
	# $process_group_name is for a group of processes that
	# share STDOUT.  The inntial process calls this method.
{
	my ($how) = @_;
	$WITH_SEMAPHORES = $how if defined($how);
	return if $WITH_SEMAPHORES < $HOW_SEMAPHORE_WIN32;
	my ($process_group_name) = @_;
	$STD_OUT_SEM = Win32::Mutex->new(0,$process_group_name);
	# print "$process_group_name SEMAPHORE CREATED\n" if $STD_OUT_SEM:
	error("Could not CREATE $process_group_name SEMAPHORE") if !$STD_OUT_SEM;

}


sub openSTDOUTSemaphore
	# $process_group_name is for a group of processes that
	# share STDOUT.  The inntial process calls this method.
{
	return if $WITH_SEMAPHORES < $HOW_SEMAPHORE_WIN32;
	my ($process_group_name) = @_;
	$STD_OUT_SEM = Win32::Mutex->open($process_group_name);
	# print "$process_group_name SEMAPHORE OPENED\n" if $STD_OUT_SEM:
	error("Could not OPEN $process_group_name SEMAPHORE") if !$STD_OUT_SEM;
}


sub waitSTDOUTSemaphore
	# returns 1 if they got it, 0 if timeout
{
	return if !$WITH_SEMAPHORES;
	if ($WITH_SEMAPHORES == $HOW_SEMAPHORE_WIN32)
	{
		return $STD_OUT_SEM->wait($SEMAPHORE_TIMEOUT) if $STD_OUT_SEM;
	}
	else
	{
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
}


sub releaseSTDOUTSemaphore
{
	return if !$WITH_SEMAPHORES;
	if ($WITH_SEMAPHORES == $HOW_SEMAPHORE_WIN32)
	{
		$STD_OUT_SEM->release() if $STD_OUT_SEM;
	}
	else
	{
		$local_sem--;
	}
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



#----------------------
# _output
#----------------------

sub _output
{
    my ($indent_level,$msg,$color,$call_level) = @_;
    $call_level ||= 0;

    my ($indent,$file,$line,$tree) = get_indent($call_level+1);

	my $tid = threads->tid();
	my $proc_info = $WITH_PROCESS_INFO ? pad("($$,$tid)",10) : '';
	my $dt = $WITH_TIMESTAMPS ? pad(now(1)." ",20) : '';
	my $file_part = pad("$file\[$line\]",$PAD_FILENAMES);

    $indent = 1-$indent_level if $indent_level < 0;
	$indent_level = 0 if $indent_level < 0;

	my $fill = pad("",($indent+$indent_level) * $CHARS_PER_INDENT);
	my $full_message = $dt.$proc_info.$file_part;
	my $header_len = length($full_message);
	$full_message .= $fill.$msg;

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

	my $text = '';
	my $started = 0;
	my @lines = split(/\r/,$full_message);
	for my $line (@lines)
	{
		next if !defined($line);
		$line =~ s/\n|\s$//g;
		$text .= pad("",$header_len).$fill."    " if $started;
		$text .= $line."\r\n";
		$started = 1;
	}

	lock($local_sem) if $USE_SHARED_LOCK_SEM;
	my $got_sem = waitSTDOUTSemaphore();

	$USE_CONSOLE->Attr($color) if $USE_CONSOLE;

	print $text;

	# print($full_message."\n");
	# print($USE_HANDLE $full_message."\n") :
	# $USE_CONSOLE->Write($full_message."\n") :
	$USE_CONSOLE->Attr($DISPLAY_COLOR_NONE) if $USE_CONSOLE;

	$USE_CONSOLE->Flush() if $USE_CONSOLE;
	# sleep(0.1) if $WITH_SEMAPHORES;

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
	# win32 only
	# returns free space for the drive in the given $path.
	# if no DRIVER_LETTER COLON is specified, defaults to C:
{
	my ($path) = @_;
	my $drive = 'C:';
	$drive = $1 if $path && $path =~ /^([A-Z]:)/i;
	my ($SectorsPerCluster,
		$BytesPerSector,
		$NumberOfFreeClusters,
		$TotalNumberOfClusters,
		$FreeBytesAvailableToCaller,
		$TotalNumberOfBytes,
		$TotalNumberOfFreeBytes) = Win32::DriveInfo::DriveSpace($drive);
	# display(0,0,"diskFree=$TotalNumberOfFreeBytes");
	return $TotalNumberOfFreeBytes;

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
{
	# display_hash(0,0,"ENV",\%ENV);
	my $id = $ENV{COMPUTERNAME};
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



1;
