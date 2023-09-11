#!/usr/bin/perl
#-----------------------------------------------------
# File Server Info class
#-----------------------------------------------------
# the file time is in GMT
# call toLocalTime to get the local time stamp

package Pub::FS::FileInfo;
use strict;
use warnings;
use Pub::Utils;

our $dbg_info = 0;
	# 0 = show new fromText events
	# -1 = show fromText hashes


BEGIN {
    use Exporter qw( import );
	our @EXPORT = qw (
        makepath
	);
}


# the dir field is serialized specially

my @fields = qw( size ts entry );


sub new
{
    my ($class,
        $session,
		$is_dir,
		$dir,		# parent directory
        $entry,		# directory or filename
        $no_checks ) = @_;

	if ($dir && !$entry)
	{
		$entry = $dir;
		$dir = '';
	}

	display($dbg_info,0,"FileInfo->new($is_dir,$is_dir,$dir,$entry)");

    my $this = {
        session   => $session,
        is_dir    => $is_dir,
        entry     => $entry };
    $this->{entries} = {} if ($is_dir);

    bless $this,$class;
    return $this if ($no_checks);

    my $filename = $dir ? makepath($dir,$entry) : $entry;

    if ($is_dir && !(-d $filename))
    {
        error("directory $filename not found");
        return;
    }
    if (!$is_dir && !(-e $filename))
    {
        $session->session_error("file $filename not found");
        return;
    }

	my ($dev,$ino,$in_mode,$nlink,$uid,$gid,$rdev,$size,
	  	$atime,$mtime,$ctime,$blksize,$blocks) = stat($filename);

    # on windows it appears as if $mtime is in
    # the local timezone. So, by all rights,
    # I have to convert it to GMT sheesh.

	if (!$mtime)
    {
        error("Could not stat ".($is_dir?'directory':'file')." $filename");
        return;
    }

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
    my $this = {};
    bless $this,$class;
    $this->{session} = $session;
    display($dbg_info,0,"from_text($string)");
    for my $field (@fields)
    {
		my $value = $string =~ s/^(.*?)(\t|$)// ? $1 : '';
		if ($value =~ s/\/$//)
		{
			$this->{is_dir} = 1;
			$value = "/" if !$value;
		}
		$this->{$field} =  $value;
    }
	$this->{dir} = $use_dir if $use_dir;
	$this->{entries} = {} if $this->{is_dir};
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
