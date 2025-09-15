#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Getopt::Long;
use IO::Select;
use Time::HiRes ();
use Fcntl qw(O_NONBLOCK F_GETFL F_SETFL);

binmode STDOUT, ':encoding(UTF-8)';

# ---------------- CLI ----------------
my %opt = (
    header    => 2,          # fixed header lines; 0 to disable
    footer    => 2,          # fixed footer lines; 0 to disable
    window    => 60,         # autorange window (rows) across all samples
    delay_ms  => 0,          # inter-iteration delay (0 = tight loop)
    series    => 4,          # used only when generating fake data (no --serial)
    serial    => '',         # e.g. /dev/ttyUSB0 ; if empty, generate synthetic data
    baud      => 115200,     # serial baud rate
    no_color  => 0,          # disable color
);
GetOptions(
    'header=i'     => \$opt{header},
    'footer=i'     => \$opt{footer},
    'window=i'     => \$opt{window},
    'delay_ms|d=i' => \$opt{delay_ms},
    'series=i'     => \$opt{series},
    'serial=s'     => \$opt{serial},
    'baud=i'       => \$opt{baud},
    'no-color!'    => \$opt{no_color},
) or die "Bad options\n";

# ---------------- Term & ANSI helpers ----------------
sub esc              { "\e[" . shift }
sub gotorc           { my ($r,$c)=@_; sprintf "\e[%d;%dH",$r,$c }
sub clr_eol          { esc("K") }
sub hide_cursor      { print esc("?25l") }
sub show_cursor      { print esc("?25h") }
sub set_scroll_region{ my ($t,$b)=@_; print esc("${t};${b}r") }
sub reset_scroll_region { print esc("r") }
sub reset_attrs_str  { esc("0m") }   # return string (do NOT print)
sub fg256            { my ($n)=@_; $opt{no_color} ? "" : esc("38;5;${n}m") }
sub bg256            { my ($n)=@_; $opt{no_color} ? "" : esc("48;5;${n}m") }
sub bold             { $opt{no_color} ? "" : esc("1m") }

sub term_size {
    my ($rows,$cols) = (undef, undef);
    eval {
        require "sys/ioctl.ph";            ## no critic
        my $winsize = pack('S4', 0,0,0,0);
        ioctl(STDOUT, &TIOCGWINSZ, $winsize) or die;
        ($rows,$cols) = unpack('S4', $winsize);
        1;
    } or do {
        my $sz = `stty size 2>/dev/null`;
        ($rows,$cols) = ($1,$2) if $sz =~ /(\d+)\s+(\d+)/;
    };
    $rows ||= 24; $cols ||= 80;
    return ($rows,$cols);
}

# ---------------- Layout state ----------------
my ($ROWS, $COLS) = term_size();
my $need_redraw = 1;               # trigger full redraw on start/resize/field change
my $inline_nums_on = 0;            # toggle with 'N' to show/hide per-glyph field numbers

my $min_plot_height = 6;
my $pad_left  = 1;                 # left padding inside scroll region
my $pad_right = 1;                 # right padding
my $plot_left; my $plot_right;     # columns for plotting
my $plot_top;  my $plot_bottom;    # scroll region bounds
my $plot_width; my $plot_height;

# glyphs/colors
my @glyphs = ('●','◆','■','▲','○','◇','□','△','▣','▵','✶','✦','▸','◼','▴','▮');
my @colors = (196,208,220,40,45,51,201,190,33,129,99,178,75,141,214,160);

# ---------------- Data ----------------
my $S = $opt{series};
my @values;          # current values (length S)
my @hist;            # history ring buffers per series (array of arrayrefs)
my $hsize = $opt{window};

# Synthetic generator state (used if no --serial)
my @syn_vol; my @syn_seed;

# ---------------- Serial I/O ----------------
my $ser_fh;
my $sel;                           # IO::Select for non-blocking reads
my @field_names;

sub setup_serial {
    return 0 unless $opt{serial};
    my $dev = $opt{serial};
    my $baud = $opt{baud} || 115200;

    # Configure line settings via stty (portable enough on Linux)
    system("stty -F $dev $baud cs8 -cstopb -parenb -ixon -ixoff -crtscts -echo -icanon min 1 time 0 2>/dev/null");
    open($ser_fh, "+<", $dev) or die "Cannot open $dev: $!";
    binmode($ser_fh, ":raw");
    # make non-blocking
    my $flags = fcntl($ser_fh, F_GETFL, 0);
    fcntl($ser_fh, F_SETFL, $flags | O_NONBLOCK);
    $sel = IO::Select->new($ser_fh);
    return 1;
}

sub read_serial_line_nonblock {
    return undef unless $ser_fh;
    my @ready = $sel->can_read(0);
    return undef unless @ready;
    my $buf = '';
    my $tmp;
    while (sysread($ser_fh, $tmp, 1024)) { $buf .= $tmp; last if $tmp =~ /\n/ }
    return undef unless length $buf;
    # keep only the last complete line if multiple
    my @lines = split(/\r?\n/, $buf);
    return $lines[-1] if defined $lines[-1] && $lines[-1] ne '';
    return undef;
}

sub parse_arduino_line {
    my ($line) = @_;
    # format: lbl1:#.#\tlbl2:#.#  OR  #.#\t#.#   (tab-separated)
    my @parts = split(/\t/, $line);
    my @labels = ();
    my @vals   = ();
    for my $i (0..$#parts) {
        my $tok = $parts[$i];
        if ($tok =~ /^\s*([^:]+)\s*:\s*([-+]?(?:\d+(?:\.\d+)?|\.\d+))\s*$/) {
            push @labels, $1;
            push @vals, $2 + 0.0;
        } elsif ($tok =~ /^\s*([-+]?(?:\d+(?:\.\d+)?|\.\d+))\s*$/) {
            push @labels, "";     # unlabeled, will assign index later
            push @vals, $1 + 0.0;
        }
        # ignore malformed tokens silently
    }
    return (\@labels, \@vals);
}

sub ensure_fields {
    my ($labels_ref, $vals_ref) = @_;
    my @labels = @$labels_ref;
    my $n = scalar(@$vals_ref);

    # Fill missing labels with 1-based indices
    for my $i (0..$n-1) {
        $labels[$i] = ($i+1) if !defined($labels[$i]) || $labels[$i] eq '';
    }

    # First time: initialize structures
    if (!@field_names) {
        @field_names = @labels;
        @values      = map { 0 } (1..$n);
        @hist        = map { [] } (1..$n);
        return 1;  # treat as change (requires redraw)
    }

    # Detect changes (count or any label mismatch)
    my $changed = 0;
    if (@field_names != $n) {
        $changed = 1;
    } else {
        for my $i (0..$n-1) {
            if ($field_names[$i] ne $labels[$i]) { $changed = 1; last }
        }
    }

    if ($changed) {
        @field_names = @labels;
        my $oldn = scalar(@values);
        my $newn = $n;
        if ($newn > $oldn) {
            push @values, (0) x ($newn - $oldn);
            push @hist,   ([]) x ($newn - $oldn);
        } elsif ($newn < $oldn) {
            @values = @values[0..$newn-1];
            @hist   = @hist[0..$newn-1];
        }
    }

    return $changed;
}

# ---------------- Layout helpers ----------------
sub recompute_layout {
    my ($r,$c) = term_size();
    $ROWS = $r; $COLS = $c;

    my $avail = $ROWS - $opt{header} - $opt{footer};
    if ($avail < $min_plot_height) {
        $opt{header} = 0 if $ROWS < ($min_plot_height + $opt{footer});
        $avail = $ROWS - $opt{header} - $opt{footer};
        die "Not enough vertical space (rows=$ROWS)\n" if $avail < $min_plot_height;
    }

    $plot_top    = $opt{header} + 1;
    $plot_bottom = $ROWS - $opt{footer};
    $plot_height = $plot_bottom - $plot_top + 1;

    $plot_left   = 1 + $pad_left;
    $plot_right  = $COLS - $pad_right;
    $plot_right  = $plot_left if $plot_right < $plot_left;
    $plot_width  = $plot_right - $plot_left + 1;
}

# Map value -> column within [plot_left, plot_right]
sub val_to_col {
    my ($v, $vmin, $vmax) = @_;
    return $plot_left if $plot_width <= 1;
    my $t = ($v - $vmin) / (($vmax-$vmin) || 1e-9);
    $t = 0 if $t < 0; $t = 1 if $t > 1;
    my $x = int($t * ($plot_width-1));
    return $plot_left + $x;
}

# ---------------- Fixed bars ----------------
sub draw_header {
    return if $opt{header} <= 0;
    my $barbg = 238;
    for my $r (1..$opt{header}) {
        my $label = $r==1 ? " Fixed Header — Vertical Scroll Region Test (tmux-256color) " : "";
        my $line  = sprintf(" %s%s", $label, "-" x ($COLS-1-length($label)));
        $line = substr($line, 0, $COLS-1);
        print gotorc($r,1), bg256($barbg), fg256(231), bold(), $line, reset_attrs_str(), clr_eol(), "\n";
    }
}

sub draw_footer {
    return if $opt{footer} <= 0;
    my $barbg = 238;
    for my $i (0..$opt{footer}-1) {
        my $r = $ROWS - $opt{footer} + 1 + $i;
        my $label = $i==0
          ? " Footer — q=quit  N=toggle per-glyph numbers   (resize to test SIGWINCH) "
          : "";
        my $line  = sprintf(" %s%s", $label, "-" x ($COLS-1-length($label)));
        $line = substr($line, 0, $COLS-1);
        print gotorc($r,1), bg256($barbg), fg256(231), bold(), $line, reset_attrs_str(), clr_eol(), "\n";
    }
}

sub clear_screen { print esc("2J") }

sub full_redraw {
    reset_scroll_region();
    clear_screen();
    draw_header();
    draw_footer();
    set_scroll_region($plot_top, $plot_bottom);
    print gotorc($plot_bottom, 1);
}

# ---------------- Data update & scaling ----------------
sub window_minmax {
    my ($lo,$hi) = (1e9, -1e9);
    for my $i (0..$#hist) {
        for my $v (@{$hist[$i]}) { $lo = $v if $v < $lo; $hi = $v if $v > $hi; }
    }
    if (!@hist || $hi - $lo < 1e-6) { $hi += 1; $lo -= 1 }
    return ($lo,$hi);
}

# Build one line for a given field index (vertical printing: one line per field)
sub build_field_line {
    my ($i, $vmin, $vmax) = @_;
    my $col  = val_to_col($values[$i], $vmin, $vmax);
    my $g    = $glyphs[$i % @glyphs];
    my $colr = $colors[$i % @colors];

    # Compose a buffer filled with spaces
    my @buf = (' ') x $COLS;

    # Place glyph within plot bounds
    if ($col >= $plot_left && $col <= $plot_right) {
        my $cell = fg256($colr) . $g . reset_attrs_str();
        $buf[$col-1] = $cell;
        if ($inline_nums_on) {
            my $num_s = "" . ($i+1);
            for (my $k=0; $k<length($num_s); $k++) {
                my $cc = $col + 1 + $k;
                last if $cc > $plot_right;
                $buf[$cc-1] = fg256($colr) . substr($num_s,$k,1) . reset_attrs_str();
            }
        }
    }

    # Optional faint borders
    my $border_col = 244;
    if ($plot_left-1 >= 1)  { $buf[$plot_left-2] = fg256($border_col) . '│' . reset_attrs_str(); }
    if ($plot_right+1 <= $COLS){ $buf[$plot_right] = fg256($border_col) . '│' . reset_attrs_str(); }

    return join('', @buf);
}

# ---------------- Synthetic generator (fallback when no --serial) ----------------
sub synth_setup {
    my $n = $opt{series};
    @field_names = map { $_ } (1..$n);
    @values      = map { 50 + rand()*50 } (1..$n);
    @hist        = map { [] } (1..$n);
    @syn_seed    = @values;
    @syn_vol     = map { 3 + rand()*5 } (1..$n);
}

sub synth_step {
    for my $i (0..$#values) {
        my $step = (rand() - 0.5) * $syn_vol[$i];
        $values[$i] += $step;
        push @{$hist[$i]}, $values[$i];
        shift @{$hist[$i]} while @{$hist[$i]} > $hsize;
    }
}

# ---------------- Main ----------------
$| = 1;
hide_cursor();

my $cleaned = 0;
sub cleanup {
    return if $cleaned;
    print reset_attrs_str();
    reset_scroll_region();
    show_cursor();
    print gotorc($ROWS,1), "\n";
    $cleaned = 1;
}

# Signals
$SIG{WINCH} = sub { recompute_layout(); $need_redraw = 1; };
$SIG{INT}   = sub { cleanup(); system("stty sane 2>/dev/null"); exit 130 };
$SIG{TERM}  = sub { cleanup(); system("stty sane 2>/dev/null"); exit 143 };
$SIG{__DIE__} = sub { cleanup(); system("stty sane 2>/dev/null"); die @_ };

# Terminal input raw (nonblocking)
system("stty -echo -icanon time 0 min 0 2>/dev/null");

# Serial or synth
my $serial_on = setup_serial();
synth_setup() unless $serial_on;

# Initial layout & draw
recompute_layout();
full_redraw();

my $sleep_s = ($opt{delay_ms} // 0) / 1000.0;

while (1) {
    # --- Handle keyboard ---
    my $ch = '';
    my $n = sysread(STDIN, $ch, 1);
    if (defined $n && $n > 0) {
        if ($ch eq 'q') { last; }
        if ($ch eq 'N') { $inline_nums_on = !$inline_nums_on; }
    }

    # --- Ingest data ---
    if ($serial_on) {
        if (my $line = read_serial_line_nonblock()) {
            my ($lbls,$vals) = parse_arduino_line($line);
            if (@$vals) {
                my $fields_changed = ensure_fields($lbls,$vals);
                @values = @$vals;
                for my $i (0..$#values) {
                    push @{$hist[$i]}, $values[$i];
                    shift @{$hist[$i]} while @{$hist[$i]} > $hsize;
                }
                $need_redraw = 1 if $fields_changed;  # redraw header/footer/regions once on schema change
            }
        } else {
            # no new serial data this tick; fall through to render with last values
        }
    } else {
        synth_step();
    }

    # --- Redraw if needed (header/footer shown only at start/redraw) ---
    if ($need_redraw) {
        full_redraw();
        $need_redraw = 0;
    }

    # --- Scaling over window ---
    my ($vmin,$vmax) = window_minmax();

    # --- Vertical print: one line per field (causes fast vertical scroll) ---
    for my $i (0..$#values) {
        my $line = build_field_line($i, $vmin, $vmax);
        print gotorc($plot_bottom, 1), $line, clr_eol(), "\n";
    }

    Time::HiRes::sleep($sleep_s) if $sleep_s > 0;
}

system("stty sane 2>/dev/null");
cleanup();
exit 0;
