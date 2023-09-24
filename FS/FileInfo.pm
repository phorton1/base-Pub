#!/usr/bin/perl
#-----------------------------------------------------
# File Server Info class
#-----------------------------------------------------
# Henceforth, if you wanna know if its a FileInfo as opposed
# to, say, an error, you must call isValidInfo() on the objects
# returned from this file.

package Pub::FS::FileInfo;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;

our $dbg_info = 1;
	# 0 = show new fromText events
	# -1 = show fromText hashes


BEGIN {
    use Exporter qw( import );
	our @EXPORT = qw (
		reportError
        makepath
		isValidInfo
	);
}


sub isValidInfo
{
	my ($thing) = @_;
	return 1 if $thing && ref($thing) =~ /Pub::FS::FileInfo/;
	return 0;
}

sub reportError
	# subverts showError() to show me errors as they are generated
	# rather than later
{
	my ($msg) = @_;
	my $save_app = getAppFrame();
	setAppFrame(undef);
	error($msg,1);
	setAppFrame($save_app);
	return "ERROR - $msg";
}



my @fields = qw( size ts entry );


sub new
	# there is a dangerous ambiguity as to semantic for dirs
	# 	  the entry may or may not be fully qualified!
	# if called with both dir and entry it is NOT fully qualified
	#     and assumes the caller knows that the entry is a
	#     subdirectory of the given dir.
	# if called with only one of dir or entry, it is assumed to
	#     be fully qualified.
	# these assumptions will be checked except if $no_checks,
	#     but it still is a dangerous way to do things.
{
    my ($class,
        $session,
		$is_dir,
		$dir,		# parent directory
        $entry,		# directory or filename
        $no_checks ) = @_;

	$dir ||= '';
	$entry ||= '';

	if ($dir && !$entry)
	{
		$entry = $dir;
		$dir = '';
	}

	display($dbg_info,0,"FileInfo->new($is_dir,$is_dir,$dir,$entry)");

    my $this = shared_clone({
        is_dir    => $is_dir,
        entry     => $entry });
    $this->{entries} = shared_clone({}) if ($is_dir);
    bless $this,$class;
    return $this if ($no_checks);

    my $filename = $dir ? makepath($dir,$entry) : $entry;

	return reportError("directory $filename not found")
		if $is_dir && !(-d $filename);
	return reportError("file $filename not found")
		if !$is_dir && !(-e $filename);

	my ($dev,$ino,$in_mode,$nlink,$uid,$gid,$rdev,$size,
	  	$atime,$mtime,$ctime,$blksize,$blocks) = stat($filename);

	return reportError("Could not stat ".($is_dir?'directory':'file')." $filename")
		if !$mtime;

	my @time_parts = gmtime($mtime);
	my $ts =
		($time_parts[5]+1900).'-'.
		pad2($time_parts[4]+1).'-'.
		pad2($time_parts[3]).' '.
		pad2($time_parts[2]).':'.
		pad2($time_parts[1]).':'.
		pad2($time_parts[0]);

	display($dbg_info+1,1,"stats=$ts,$size");
    $this->{size}   = $size;
    $this->{ts} 	= $ts;
    return $this;
}


sub makepath
    # static, handles '/'
{
    my ($dir,$entry) = @_;
    $dir .= '/' if ($dir !~ /\/$/);
    return $dir.$entry;
}




#-----------------------------------
# routines
#-----------------------------------


sub from_text
{
    my ($class,$session,$string,$use_dir) = @_;
    my $this = shared_clone({});
    bless $this,$class;
    display($dbg_info,0,"from_text($string)");
    for my $field (@fields)
    {
		my $value = $string =~ s/^(.*?)(\t|$)// ? $1 : '';
		if ($field eq 'entry' && $value =~ s/\/$//)
		{
			$this->{is_dir} = 1;
			$value = "/" if !$value;
		}
		$this->{$field} =  $value;
    }

	return reportError("bad FS::FileInfo size($this->{size}) for directory")
		if $this->{is_dir} && $this->{size};
	return reportError("bad FS::FileInfo size($this->{size}) for file")
		if !$this->{is_dir} && $this->{size} !~ /^\d+$/;
	return reportError("bad FS::FileInfo timestamp($this->{ts})")
		if $this->{ts} !~ /^[\s\d\-\:]+$/;

	$this->{dir} = $use_dir if $use_dir;
	$this->{entries} = shared_clone({}) if $this->{is_dir};
	display_hash($dbg_info+1,1,"from_text",$this);
	bless $this,$class;
	return $this;
}


sub to_text
{
    my ($this) = @_;
    my $string = '';
    for my $field (@fields)
    {
        my $val = $this->{$field};
        $val = '' if (!defined($val));
		$val .= "/" if $field eq 'entry' && $this->{is_dir};
        $string .= $val."\t";
    }
    return $string;
}


1;
