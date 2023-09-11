#!/usr/bin/perl
#---------------------------------------------------------------------
# AppConfig.pm - global configuration file
# Cannot be called Config.pm if I want to run,
# or Komodo error check in same directory, as
# Config is an outer level Perl namespace


package Pub::WX::AppConfig;
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils;
use Pub::WX::Resources;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
        $ini_file

		deleteConfig
		readConfig
		writeConfig
		readConfigMenu
		writeConfigMenu
		readConfigRect
		writeConfigRect
		configHasGroup
		configDeleteGroup );
}

our $ini_file = "$data_dir/app.ini";

my $global_config_file;



sub initialize
	# not exported
{
	display(9,0,"AppConfig::initialize($ini_file)");
	$global_config_file = Wx::FileConfig->new(
        $resources->{app_title},
        "Pat Horton",
        $ini_file,
        '',
        wxCONFIG_USE_LOCAL_FILE);
}

sub save
	# not exported
{
	$global_config_file->Flush() if ($global_config_file);
}


sub configHasGroup
{
	my ($title) = @_;
	$title = "/ $$resources{app_title}/$title" if ($title !~ /^\//);
	return $global_config_file->HasGroup($title);
}


sub configDeleteGroup
{
	my ($title) = @_;
	$title = "/ $$resources{app_title}/$title" if ($title !~ /^\//);
	return $global_config_file->DeleteGroup($title);
}


sub deleteConfig
{
	my ($title) = @_;
	$title = "/ $$resources{app_title}/$title" if ($title !~ /^\//);
	return $global_config_file->DeleteEntry($title)
}


sub readConfig
{
	my ($title) = @_;
	$title = "/ $$resources{app_title}/$title" if ($title !~ /^\//);
	return $global_config_file->Read($title);
}


sub writeConfig
{
	my ($title,$val) = @_;
	$title = "/ $$resources{app_title}/$title" if ($title !~ /^\//);
	$global_config_file->Write($title,$val);
}


sub writeConfigMenu
	# writes full set of pull down menus passed in as an array of (refs to) arrays.
	# each subarray consists of two elements, the submenu title (i.e. &File),
	# and a (reference to an) array of command_ids for the pull down items.
{
	my $num = 1;
	my ($title,@menus) = @_;
	foreach my $r_menu (@menus)
	{
		my ($menu_title, $r_ids) = @$r_menu;
		my $menu_str = $menu_title.",".join(",",@$r_ids);
		writeConfig($title.($num++), $menu_str);
	}
}


sub readConfigMenu
	# reads a full menu bar (set of pull down menu items) from config file.
	# see coments on writeConfigMenu for details on data structure.
	# reads $config_title1 thru $config_titleN until N is not found.
{
	my $num = 1;
	my @retval = ();
	my ($title,@menus) = @_;
	while ((my $menu_str=readConfig($title.($num++))) ne "")
	{
		my @data = split(/,/,$menu_str);
		my $title = shift @data;
		push @retval, [$title, [@data]];
	}
	return @retval;
}


sub writeConfigRect
{
	my ($title,$rect) = @_;
	writeConfig($title,sprintf("%d,%d,%d,%d",$rect->x,$rect->y,$rect->width,$rect->height));
}


sub readConfigRect
{
	my ($title) = @_;
	my $str = readConfig($title);
	if ($str ne "")
	{
		my $rect = Wx::Rect->new(split(/,/,$str));
		return $rect;
	}
}

1;
