#!/usr/bin/perl
#---------------------------------------------------------------------
# AppConfig.pm - global configuration file
# Cannot be called Config.pm if I want to run,
# or Komodo error check in same directory, as
# Config is an outer level Perl namespace


package Pub::WX::AppConfig;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils;
use Pub::WX::Resources;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
        $ini_file
		clearConfigFile

		readConfig
		writeConfig
		readConfigRect
		writeConfigRect );
}

our $ini_file = '';

my $config:shared;



sub initialize
	# not exported
{
	return if !$ini_file;
	display(9,0,"AppConfig::initialize($ini_file)");
	my $text = getTextFile($ini_file);
	$config = shared_clone([ split(/\n/,$text) ]);
}


sub clearConfigFile
{
	return if !$ini_file;
	$config = shared_clone([]);
	unlink $ini_file;
}


sub save
	# not exported
{
	return if !$ini_file;
	my $text = join("\n",@$config);
	printVarToFile(1,$ini_file,$text);
}


sub readConfig
	# id's cannot contain re-breaking symbols
{
	my ($id) = @_;
	return if !$ini_file;
	for my $line (@$config)
	{
		return $line if $line =~ s/^$id=//;
	}
	return '';
}


sub writeConfig
{
	my ($id,$val) = @_;
	return if !$ini_file;
	for (my $i=0; $i<@$config; $i++)
	{
		if ($config->[$i] =~ /^$id=/)
		{
			$config->[$i] = "$id=$val";
			return;
		}
	}
	push @$config,"$id=$val";
}


sub writeConfigRect
{
	my ($id,$rect) = @_;
	return if !$ini_file;
	writeConfig($id,sprintf("%d,%d,%d,%d",$rect->x,$rect->y,$rect->width,$rect->height));
}


sub readConfigRect
{
	my ($id) = @_;
	return if !$ini_file;
	my $str = readConfig($id);
	if ($str)
	{
		my $rect = Wx::Rect->new(split(/,/,$str));
		return $rect;
	}
	return undef;
}


1;
