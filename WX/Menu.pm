#!/usr/bin/perl


package Pub::WX::Menu;
use strict;
use warnings;
use Wx qw(
    wxITEM_RADIO
    wxITEM_CHECK
    wxITEM_NORMAL
    wxTB_FLAT
    wxTB_VERTICAL
    wxTB_HORIZONTAL );
use Pub::Utils;
use Pub::WX::Resources;


our $dbg_resources = 4;

#---------------------------------------------------
# Routines
#---------------------------------------------------


sub myColor
{
	my $color = shift;
	$color = '#009900' if ($color eq "green");
	return Wx::Colour->new($color);
}


sub createMenu
{
	my ($menu_name,$level,$menu) = @_;
		# can append to an already existing menu

	$level ||= 0;
	display($dbg_resources,2,"createMenu($level,$menu_name)");

	# the menu can be gotten by name or passed in by ref

	my $menu_ids = ref($menu_name) =~ /ARRAY/ ?
		$menu_name : $resources->{$menu_name};

	my $started = 0;
	my $sep_needed = 0;
		# don't put out separator at top, bottom, or two in a row

    $menu ||= Wx::Menu->new();
	foreach my $id (@$menu_ids)
	{
		if ($id == $ID_SEPARATOR)
		{
			$sep_needed = 1;
			next;
		}

		my $data = $$resources{command_data}->{$id};
		if ($data eq '')
		{
			error("createMenu() - command id($id) has no data in $menu_name");
			next;
		}
		my ($text,$hint,$style,$required_level,$pref_id) = @$data;
		$required_level||= 0;
		$pref_id ||= '';


		if ($level < $required_level)
		{
			display($dbg_resources,0,"Skipping menu item($text) STYLE=$style  level=$level required=$required_level");
			next;
		}

		if ($pref_id && !get_pref($pref_id))
		{
			display($dbg_resources,0,"Skipping menu item($text) STYLE=$style pref_id=$pref_id");
			next;

		}

		if ($sep_needed && $started)
		{
			$menu->AppendSeparator();
			$sep_needed = 0;
		}
		$started = 1;

		$style ||= 0;
		display($dbg_resources,0,"Adding menu item($text) style=$style required=$required_level");

		my $kind = wxITEM_NORMAL;
		if ($style eq '1')
		{
			$kind = wxITEM_CHECK;
		}
		elsif ($style eq '2')
		{
			$kind = wxITEM_RADIO;
		}

		my $item = $menu->Append($id,$text,$hint,$kind);
	}
	return $menu;
}


1;
