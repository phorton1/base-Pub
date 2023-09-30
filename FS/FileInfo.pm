#!/usr/bin/perl
#-----------------------------------------------------
# FS::Pub::FileInfo
#-----------------------------------------------------
# FileInfo methods return FileInfo objects or text containing
# an error messaaage.
#
# You can check ref(), or better yet, call isValidInfo() which
# specifically checks FS::Pub::FileInfo objects, to tell the
# difference.

package Pub::FS::FileInfo;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;

our $dbg_info = 0;
	# 0 = show new() events
	# -1 = show fromText hashes
our $dbg_text:shared = 1;
	# 0 = show lists encountered
	# -1 = show list items
	# -3 = show hash returned by textToDirInfo()

BEGIN {
    use Exporter qw( import );
	our @EXPORT = qw (
		isValidInfo
		dirInfoToText
		textToDirInfo
	);
}


sub isValidInfo
{
	my ($thing) = @_;
	return 1 if $thing && ref($thing) =~ /Pub::FS::FileInfo/;
	return 0;
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

	display($dbg_info,0,"FileInfo->new($is_dir,$dir,$entry)",1);

    my $this = shared_clone({
        is_dir    => $is_dir,
        entry     => $entry });
    $this->{entries} = shared_clone({}) if ($is_dir);
    bless $this,$class;
    return $this if ($no_checks);

    my $filename = $dir ? makePath($dir,$entry) : $entry;

	# errors at $call_level=1 with $suppress_show
	return error("directory $filename not found",1,1)
		if $is_dir && !(-d $filename);
	return error("file $filename not found",1,1)
		if !$is_dir && !(-e $filename);

	my ($dev,$ino,$in_mode,$nlink,$uid,$gid,$rdev,$size,
	  	$atime,$mtime,$ctime,$blksize,$blocks) = stat($filename);

	return error("Could not stat ".($is_dir?'directory':'file')." $filename",1,1)
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



#-----------------------------------
# routines
#-----------------------------------


sub fromText
{
    my ($class,$text,$call_level) = @_;
	$call_level ||= 0;
	$call_level++;

    display($dbg_info,0,"fromText($text)");
	my @parts = split(/\t/,$text);
    my $this = shared_clone({
		size   => defined($parts[0]) ? $parts[0] : '',
		ts     => $parts[1] || '',
		entry  => $parts[2] || '',
		is_dir => 0,
	});

	$this->{is_dir} = 1 if $this->{entry} =~ s/\/$//;
	$this->{entry} = '/' if $this->{is_dir} && !$this->{entry};

	# errors at $call_level=1 with $suppress_show
	return error("bad FS::FileInfo size($this->{size}) for directory: $text",$call_level)
		if $this->{is_dir} && $this->{size};
	return error("bad FS::FileInfo size($this->{size}) for file: $text",$call_level)
		if !$this->{is_dir} && $this->{size} !~ /^\d+$/;
	return error("bad FS::FileInfo timestamp($this->{ts}): $text",$call_level)
		if $this->{ts} !~ /^[\s\d\-\:]+$/;


	$this->{entries} = shared_clone({}) if $this->{is_dir};
	display($dbg_info+1,0,"fromText",toText($this,1));
	bless $this,$class;
	return $this;
}


sub toText
{
    my ($this,$quiet_dbg) = @_;
    my $entry = $this->{entry};
	$entry .= "/" if $this->{is_dir} && $entry ne '/';
	my $text = "$this->{size}\t$this->{ts}\t$entry";
    display($dbg_text+1,0,"toText()=$text")
		if !$quiet_dbg;
    return $text;
}


#--------------------------------------------------
# dirInfoToText and textToDirInfo
#--------------------------------------------------
# Convert a populatated FileInfo(is_dir=1) to a
# cannonical text form, or vice versa.

sub dirInfoToText
	# takes a populated FileInfo directory object
	# never fails
	# first line is the parent directory
	# subsequent lines are it's entries
{
    my ($dir_info) = @_;

    display($dbg_text,0,"dirInfoToText($dir_info->{entry}) ".
		($dir_info->{is_dir} ? scalar(keys %{$dir_info->{entries}})." entries" : ""));

	my $text = $dir_info->toText()."\r";
	if ($dir_info->{is_dir})
    {
		for my $entry (sort keys %{$dir_info->{entries}})
		{
			my $info = $dir_info->{entries}->{$entry};
			$text .= $info->toText()."\r" if $info;
		}
	}
    return $text;
}



sub textToDirInfo
	# first line is the parent directory
	# subsequent lines are it's entries
	# creates a populated FileInfo directory object
	# or returns a text error message
	# errors at $call_level=1 with $suppress_show
{
    my ($text) = @_;
	# Somebody else must check for PROTOCOL_ERROR before calling this
		# my $err = $session->textError($text);
		# return $err if $err;

	# the first directory listed is the base directory
	# all sub-entries go into it's {entries} member

    my $result;
    my @lines = split("\r",$text);
    display($dbg_text,0,"textToDirInfo() lines=".scalar(@lines));

    for my $line (@lines)
    {
        my $info = Pub::FS::FileInfo->fromText($line,1);
		if (!isValidInfo($info))
		{
			$result = $info;
			last;
		}
		if (!$result)
		{
			if (!$info->{is_dir})
			{
				$result = error("textToDirInfo must start with a DIR_ENTRY not the file: $info->{entry}",1,1);
				last;
			}
			$result = $info;
		}
		else
		{
			$result->{entries}->{$info->{entry}} = $info;
		}
    }

	if (isValidInfo($result))
	{
		display_hash($dbg_text+2,2,"textToDirInfo($result->{entry})",$result->{entries});
	}
	else
	{
		display_hash($dbg_text+2,2,"textToDirInfo() returning $result");
	}
    return $result;
}




1;
