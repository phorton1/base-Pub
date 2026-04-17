#!/usr/bin/perl
#-----------------------------------------------------
# Pub::WX::StyledTextPanel
#-----------------------------------------------------
# Owner-drawn scrolled text panel with per-run color,
# bold, and background highlight.  Zoomable via
# Ctrl+mousewheel.  Supports drag selection and
# Ctrl+C copy to clipboard.
#
# CONTENT API
#   clearContent()                    -- reset to empty
#   $line = addLine()                 -- append blank line; returns line ref
#   addPart($line, $text, %opts)      -- append styled run to line
#   addSingleLine($text, %opts)       -- addLine + addPart in one call
#   setText($string)                  -- clearContent + plain lines from \n-split
#
# STYLE OPTIONS (for addPart / addSingleLine)
#   bold => 0|1
#   fg   => Wx::Colour     (foreground; default black)
#   bg   => Wx::Colour     (background highlight; default none)
#
# ZOOM
#   setZoomLevel($n)                  -- 0..33 index (3pt..36pt); default 6 = 9pt
#   Ctrl+mousewheel                   -- zoom in / out

package Pub::WX::StyledTextPanel;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_PAINT
	EVT_IDLE
	EVT_MOUSE_EVENTS
	EVT_MOUSEWHEEL
	EVT_CHAR
	EVT_MENU );
use Win32::Clipboard;
use Pub::Utils qw(display warning error);
use base qw(Wx::ScrolledWindow);

my $dbg = 1;

my $LEFT_MARGIN  = 5;
my $DEFAULT_ZOOM = 6;    # index into @fonts; 6 = 9pt
my $ID_COPY      = 1;    # internal menu ID — never exposed to app layer

my @fonts      = map { Wx::Font->new($_, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL) } (3..36);
my @fonts_bold = map { Wx::Font->new($_, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_BOLD)   } (3..36);


#-----------------------------------------------------
# Construction
#-----------------------------------------------------

sub new
{
	my ($class, $parent, $id) = @_;
	$id //= -1;

	my $this = $class->SUPER::new($parent, $id);
	bless $this, $class;

	$this->{content}     = [];
	$this->{width}       = 0;
	$this->{height}      = 0;
	$this->{zoom_level}  = $DEFAULT_ZOOM;
	$this->{LINE_HEIGHT} = 16;
	$this->{CHAR_WIDTH}  = 7;

	$this->{drag_start}  = '';
	$this->{drag_alt}    = 0;
	$this->{in_drag}     = 0;
	$this->{drag_end}    = '';
	$this->{scroll_inc}  = 0;

	$this->SetBackgroundColour(wxWHITE);
	$this->SetBackgroundStyle(wxBG_STYLE_CUSTOM);
	$this->setZoomLevel($DEFAULT_ZOOM);

	EVT_PAINT($this,        \&onPaint);
	EVT_IDLE($this,         \&onIdle);
	EVT_MOUSE_EVENTS($this, \&onMouse);
	EVT_MOUSEWHEEL($this,   \&onMouseWheel);
	EVT_CHAR($this,         \&onChar);
	EVT_MENU($this, $ID_COPY, sub { $_[0]->_doCopy() });

	return $this;
}


#-----------------------------------------------------
# Content API
#-----------------------------------------------------

sub clearContent
{
	my ($this) = @_;
	$this->{content} = [];
	$this->{width}   = 0;
	$this->{height}  = 0;
	$this->{drag_start} = '';
	$this->{drag_end}   = '';
	$this->{in_drag}    = 0;
	$this->Scroll(0, 0);
	$this->SetVirtualSize($LEFT_MARGIN, 0);
}


sub addLine
{
	my ($this) = @_;
	my $line = { width => 0, parts => [] };
	push @{$this->{content}}, $line;
	my $lh = $this->{LINE_HEIGHT};
	my $n  = scalar @{$this->{content}};
	$this->{height} = $n * $lh;
	$this->SetVirtualSize($this->{width} + $LEFT_MARGIN, $this->{height} + $lh);
	return $line;
}


sub addPart
{
	my ($this, $line, $text, %opts) = @_;
	$text =~ s/\t/    /g;
	my $part = {
		text => $text,
		bold => $opts{bold} || 0,
		fg   => $opts{fg}   || undef,
		bg   => $opts{bg}   || undef,
	};
	push @{$line->{parts}}, $part;
	my $cw = length($text) * $this->{CHAR_WIDTH};
	$line->{width} += $cw;
	$this->{width} = $line->{width} if $line->{width} > $this->{width};
}


sub addSingleLine
{
	my ($this, $text, %opts) = @_;
	my $line = $this->addLine();
	$this->addPart($line, $text, %opts);
}


sub setText
{
	my ($this, $string) = @_;
	$this->clearContent();
	for my $text (split /\n/, $string, -1)
	{
		$this->addSingleLine($text);
	}
	$this->Refresh();
}


#-----------------------------------------------------
# Zoom
#-----------------------------------------------------

sub setZoomLevel
{
	my ($this, $level) = @_;
	$level = 0            if $level < 0;
	$level = @fonts - 1   if $level > @fonts - 1;
	$this->{zoom_level} = $level;

	my $dc = Wx::ClientDC->new($this);
	$dc->SetFont($fonts[$level]);
	$this->{CHAR_WIDTH}  = $dc->GetCharWidth();
	$this->{LINE_HEIGHT} = int($dc->GetCharHeight() * 1.1);

	$this->SetScrollRate($this->{CHAR_WIDTH}, $this->{LINE_HEIGHT});
	$this->Refresh();
}


sub onMouseWheel
{
	my ($this, $event) = @_;
	if ($event->ControlDown())
	{
		my $delta = $event->GetWheelRotation();
		$this->setZoomLevel($this->{zoom_level} + ($delta > 0 ? 1 : -1));
	}
	else
	{
		$event->Skip();
	}
}


#-----------------------------------------------------
# Paint
#-----------------------------------------------------

sub onPaint
{
	my ($this, $event) = @_;

	my $dc = Wx::PaintDC->new($this);
	$this->DoPrepareDC($dc);

	# Update region in client coords; convert to virtual (unscrolled) coords for drawing.
	# After DoPrepareDC the DC origin is shifted, so all DrawXxx calls use virtual coords.
	my $box = $this->GetUpdateRegion()->GetBox();
	my ($ux, $uy) = $this->CalcUnscrolledPosition($box->x, $box->y);
	my ($uw, $uh) = ($box->width, $box->height);
	my $ye = $uy + $uh - 1;

	# Erase background using virtual coords
	$dc->SetPen(wxTRANSPARENT_PEN);
	$dc->SetBrush(Wx::Brush->new(wxWHITE, wxSOLID));
	$dc->DrawRectangle($ux, $uy, $uw, $uh);

	$dc->SetBackgroundMode(wxTRANSPARENT);

	# Draw drag selection highlight
	$this->_drawDrag($dc, Wx::Rect->new($ux, $uy, $uw, $uh)) if $this->{drag_end};

	my $lh      = $this->{LINE_HEIGHT};
	my $zoom    = $this->{zoom_level};
	my $content = $this->{content};

	my $first = int($uy / $lh);
	my $last  = int($ye / $lh);
	$last = $#$content if $last > $#$content;

	for my $i ($first .. $last)
	{
		my $ys    = $i * $lh;
		my $parts = $content->[$i]{parts};
		my $xs    = $LEFT_MARGIN;

		for my $part (@$parts)
		{
			my $tw = length($part->{text}) * $this->{CHAR_WIDTH};

			if (defined $part->{bg})
			{
				$dc->SetPen(Wx::Pen->new($part->{bg}, 1, wxSOLID));
				$dc->SetBrush(Wx::Brush->new($part->{bg}, wxSOLID));
				$dc->DrawRectangle($xs, $ys, $tw, $lh);
			}

			$dc->SetFont($part->{bold} ? $fonts_bold[$zoom] : $fonts[$zoom]);
			$dc->SetTextForeground($part->{fg} // wxBLACK);
			$dc->DrawText($part->{text}, $xs, $ys);

			$xs += $tw;
		}
	}
}


#-----------------------------------------------------
# Drag selection helpers (geometry)
#-----------------------------------------------------

sub _floor  { int($_[0] / $_[1]) * $_[1] }
sub _ceil   { int($_[0] / $_[1]) * $_[1] + $_[1] - 1 }
sub _floorX { my ($v,$cw) = @_; _floor($v - $LEFT_MARGIN, $cw) + $LEFT_MARGIN }
sub _ceilX  { my ($v,$cw) = @_; _ceil ($v - $LEFT_MARGIN, $cw) + $LEFT_MARGIN }
sub _floorY { _floor($_[0], $_[1]) }
sub _ceilY  { _ceil ($_[0], $_[1]) }
sub _swap   { my ($a,$b) = @_; ($$b, $$a) = ($$a, $$b) }


sub _getAltRectangle
{
	my ($this) = @_;
	my $cw = $this->{CHAR_WIDTH};
	my $lh = $this->{LINE_HEIGHT};
	my ($sx, $sy) = @{$this->{drag_start}};
	my ($ex, $ey) = @{$this->{drag_end}};
	_swap(\$sx, \$ex) if $sx > $ex;
	_swap(\$sy, \$ey) if $sy > $ey;
	($sx, $sy, $ex, $ey) = (
		_floorX($sx,$cw), _floorY($sy,$lh),
		_ceilX ($ex,$cw), _ceilY ($ey,$lh) );
	return Wx::Rect->new($sx, $sy, $ex - $sx + 1, $ey - $sy + 1);
}


sub _getRectangles
{
	my ($this) = @_;
	return ($this->_getAltRectangle()) if $this->{drag_alt};

	my $cw    = $this->{CHAR_WIDTH};
	my $lh    = $this->{LINE_HEIGHT};
	my $width = $this->GetSize()->GetWidth();
	my ($sx, $sy) = @{$this->{drag_start}};
	my ($ex, $ey) = @{$this->{drag_end}};
	my ($sl, $el) = (int($sy/$lh), int($ey/$lh));
	my $num   = abs($el - $sl) + 1;
	my $yplus = 1;

	$sy = _floorY($sy,$lh);
	$ey = _floorY($ey,$lh);

	my ($fr, $mr, $lr);
	if ($sy < $ey || ($sy == $ey && $sx <= $ex))
	{
		$sx  = _floorX($sx,$cw);
		$ex  = _ceilX ($ex,$cw);
		my $ex1 = $num > 1 ? $width : $ex;
		$fr = Wx::Rect->new($sx, $sy,            $ex1-$sx+1, $lh);
		$mr = Wx::Rect->new(0,  $sy+$lh,         $width, ($num-2)*$lh) if $num > 2;
		$lr = Wx::Rect->new(0,  $ey,             $ex+1,  $lh)          if $num > 1;
	}
	else
	{
		$yplus = 0;
		$sx  = _ceilX ($sx,$cw);
		$ex  = _floorX($ex,$cw);
		my $sx1 = $num > 1 ? 0 : $ex;
		$fr = Wx::Rect->new($sx1,$sy,            $sx-$sx1+1, $lh);
		$mr = Wx::Rect->new(0,  $ey+$lh,         $width, ($num-2)*$lh) if $num > 2;
		$lr = Wx::Rect->new($ex, $ey,            $width-$ex+1,$lh)     if $num > 1;
	}
	return ($fr, $mr, $lr);
}


sub _drawIntersectRect
{
	my ($dc, $urect, $rect) = @_;
	my $is = Wx::Rect->new($rect->x, $rect->y, $rect->width, $rect->height);
	$is->Intersect($urect);
	$dc->DrawRectangle($is->x, $is->y, $is->width, $is->height)
		if $is->width && $is->height;
}


sub _drawDrag
{
	my ($this, $dc, $urect) = @_;
	$dc->SetPen(wxLIGHT_GREY_PEN);
	$dc->SetBrush(wxLIGHT_GREY_BRUSH);
	my ($r1, $r2, $r3) = $this->_getRectangles();
	_drawIntersectRect($dc, $urect, $r1) if $r1;
	_drawIntersectRect($dc, $urect, $r2) if $r2;
	_drawIntersectRect($dc, $urect, $r3) if $r3;
}


sub _refreshScrolled
{
	my ($this, $rect) = @_;
	my ($sx, $sy) = $this->CalcScrolledPosition($rect->x, $rect->y);
	$this->RefreshRect(Wx::Rect->new($sx, $sy, $rect->width, $rect->height));
}


sub _refreshCur
{
	my ($this) = @_;
	my ($r1, $r2, $r3) = $this->_getRectangles();
	$this->_refreshScrolled($r1) if $r1;
	$this->_refreshScrolled($r2) if $r2;
	$this->_refreshScrolled($r3) if $r3;
}


sub _samePt
{
	my ($p1, $p2) = @_;
	return $p1 && $p2 && $p1->[0] == $p2->[0] && $p1->[1] == $p2->[1];
}


sub _refreshDrag
{
	my ($this, $new) = @_;
	my $old = $this->{drag_end} || '';
	$this->{in_drag} = 1 if $new;

	if ($old && !$new)
	{
		$this->_refreshCur();
		$this->{drag_end} = $new;
	}
	elsif ($new && !$old)
	{
		$this->{drag_end} = $new;
		$this->_refreshCur();
	}
	else
	{
		# Refresh the union of old and new selection
		$this->_refreshCur();
		$this->{drag_end} = $new;
		$this->_refreshCur();
	}
}


sub _initDrag
{
	my ($this) = @_;
	$this->_refreshDrag(undef) if $this->{drag_end};
	$this->{drag_alt}   = 0;
	$this->{drag_start} = '';
	$this->{drag_end}   = '';
	$this->{in_drag}    = 0;
	$this->{scroll_inc} = 0;
}


#-----------------------------------------------------
# Mouse
#-----------------------------------------------------

sub onMouse
{
	my ($this, $event) = @_;
	my $cp = $event->GetPosition();
	my ($sx, $sy) = ($cp->x, $cp->y);
	my ($ux, $uy) = $this->CalcUnscrolledPosition($sx, $sy);

	my $dclick   = $event->LeftDClick();
	my $lclick   = $dclick || $event->LeftDown();
	my $rclick   = $event->RightDown();
	my $dragging = $event->Dragging();
	my $lup      = $event->LeftUp();
	my $shift    = $event->ShiftDown();
	my $alt      = $event->AltDown();

	$this->SetFocus() if $lclick || $rclick;
	$this->{scroll_inc} = 0;

	if ($rclick && $this->_canCopy())
	{
		my $menu = Wx::Menu->new();
		$menu->Append($ID_COPY, "Copy\tCtrl+C");
		$this->PopupMenu($menu, $cp);
		$menu->Destroy();
		return;
	}

	if ($this->{in_drag} && $lup)
	{
		$this->{in_drag} = 0;
	}
	elsif ($dclick)
	{
		$this->_initDrag();
		$this->_selectWordAt($ux, $uy);
	}
	elsif ($lclick)
	{
		if ($shift)
		{
			$this->{in_drag} = 1;
			$this->_refreshDrag([$ux, $uy]);
		}
		else
		{
			$this->_initDrag();
			$this->{drag_alt}   = $alt;
			$this->{drag_start} = [$ux, $uy];
		}
	}
	elsif ($this->{drag_start} && $dragging)
	{
		$this->_refreshDrag([$ux, $uy]);
		$this->_handleScroll($sx, $sy);
	}

	$event->Skip();
}


sub _selectWordAt
{
	my ($this, $ux, $uy) = @_;
	my $lh = $this->{LINE_HEIGHT};
	my $cw = $this->{CHAR_WIDTH};
	my $l  = int($uy / $lh);
	my $c  = int(($ux - $LEFT_MARGIN) / $cw);
	$c = 0 if $c < 0;

	my $line = $this->{content}[$l];
	return if !$line;

	my $text = join('', map { $_->{text} } @{$line->{parts}});
	return if $c >= length($text);

	my $char = substr($text, $c, 1);
	return if $char eq ' ';

	my ($start, $end) = ($c, $c);
	$start-- while $start > 0 && substr($text, $start-1, 1) !~ / |,/;
	$end++   while $end < length($text)-1 && substr($text, $end+1, 1) !~ / |,/;

	my $cw2 = $end - $start + 1;
	my $sy  = $l     * $lh;
	my $sx  = $start * $cw + $LEFT_MARGIN;
	my $ex  = $sx + $cw2 * $cw - 1;
	my $ey  = $sy + $lh - 1;

	$this->{drag_start} = [$sx, $sy];
	$this->{drag_end}   = [$ex, $ey];
	$this->_refreshScrolled(Wx::Rect->new($sx, $sy, $ex-$sx+1, $lh));
}


sub _handleScroll
{
	my ($this, $sx, $sy) = @_;
	my $lh     = $this->{LINE_HEIGHT};
	my $height = $this->GetSize()->height;
	my $inc = $sy > $height - $lh*2 ? 1 : $sy < $lh*2 ? -1 : 0;
	return if !$inc;

	$this->{scroll_inc} = $inc;
	my ($cur_x, $cur_y) = $this->GetViewStart();
	my $new_y = $cur_y + $inc;
	$new_y = 0 if $new_y < 0;
	if ($new_y != $cur_y)
	{
		$this->Scroll($cur_x, $new_y);
		$this->Update();
	}
}


sub onIdle
{
	my ($this, $event) = @_;
	my $inc = $this->{scroll_inc};
	if ($inc && $this->{in_drag})
	{
		my ($ex, $ey) = @{$this->{drag_end}};
		$ey += $inc * $this->{LINE_HEIGHT};
		return if $ey < 0 || $ey > $this->{height};
		my ($cur_x, $cur_y) = $this->GetViewStart();
		my $new_y = $cur_y + $inc;
		$new_y = 0 if $new_y < 0;
		if ($new_y != $cur_y)
		{
			$this->Scroll($cur_x, $new_y);
			$this->_refreshDrag([$ex, $ey]);
			$this->Update();
		}
		$event->RequestMore();
	}
}


#-----------------------------------------------------
# Clipboard
#-----------------------------------------------------

sub onChar
{
	my ($this, $event) = @_;
	my $key = $event->GetKeyCode();
	$this->_initDrag() if $key == 27;       # Escape
	$this->_doCopy()   if $key == 3 && $this->_canCopy();  # Ctrl+C
	$event->Skip();
}


sub _canCopy { return $_[0]->{drag_end} ? 1 : 0 }


sub _doCopy
{
	my ($this) = @_;
	my $clip = Win32::Clipboard();
	$clip->Set($this->_getSelectedText());
}


sub _getSelectedText
{
	my ($this) = @_;
	my $lh  = $this->{LINE_HEIGHT};
	my $cw  = $this->{CHAR_WIDTH};
	my $alt = $this->{drag_alt};
	my ($sx, $sy) = @{$this->{drag_start}};
	my ($ex, $ey) = @{$this->{drag_end}};

	my ($sl, $sc, $el, $ec) = (
		int($sy / $lh), int(($sx - $LEFT_MARGIN) / $cw),
		int($ey / $lh), int(($ex - $LEFT_MARGIN) / $cw) );
	$sc = 0 if $sc < 0;
	$ec = 0 if $ec < 0;

	if ($alt)
	{
		_swap(\$sl, \$el) if $el < $sl;
		_swap(\$sc, \$ec) if $ec < $sc;
	}
	elsif ($el < $sl || ($el == $sl && $ec < $sc))
	{
		_swap(\$sl, \$el);
		_swap(\$sc, \$ec);
	}

	my $content = $this->{content};
	my $retval  = '';

	for my $ln ($sl .. $el)
	{
		$retval .= "\n" if $ln != $sl;
		my $line = $content->[$ln];
		my $text = $line ? join('', map { $_->{text} } @{$line->{parts}}) : '';
		my $len  = length($text);

		if ($alt)
		{
			my ($a, $b) = ($sc < $len ? $sc : $len, $ec < $len ? $ec : $len - 1);
			$retval .= $a <= $b ? substr($text, $a, $b - $a + 1) : '';
		}
		elsif ($ln == $sl && $ln == $el)
		{
			my ($a, $b) = ($sc < $len ? $sc : $len, $ec < $len ? $ec : $len - 1);
			$retval .= $a <= $b ? substr($text, $a, $b - $a + 1) : '';
		}
		elsif ($ln == $sl)
		{
			$retval .= $sc < $len ? substr($text, $sc) : '';
		}
		elsif ($ln == $el)
		{
			$retval .= $ec >= 0 ? substr($text, 0, ($ec < $len ? $ec : $len - 1) + 1) : '';
		}
		else
		{
			$retval .= $text;
		}
	}

	return $retval;
}


1;
