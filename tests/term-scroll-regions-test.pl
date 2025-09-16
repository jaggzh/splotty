#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Getopt::Long;
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

binmode STDOUT, ':encoding(UTF-8)';

# ---------------- CLI ----------------
my %opt = (
    header   => 2,     # fixed header lines; 0 to disable
    footer   => 2,     # fixed footer lines; 0 to disable
    series   => 4,     # how many fields (series) - will be dynamic with serial
    window   => 30,    # autorange window (rows) across all series
    delay_ms => 0,     # inter-row delay in ms; default off (0)
    no_color => 0,     # disable color
    serial_port => '/dev/ttyACM1',  # default serial port
    baud_rate => 115200,            # default baud rate
    demo_mode => 0,                 # use fake data instead of serial
);
GetOptions(
    'header=i'      => \$opt{header},
    'footer=i'      => \$opt{footer},
    'series=i'      => \$opt{series},
    'window=i'      => \$opt{window},
    'delay_ms|d=i'  => \$opt{delay_ms},
    'no-color!'     => \$opt{no_color},
    'serial-port=s' => \$opt{serial_port},
    'baud-rate=i'   => \$opt{baud_rate},
    'demo!'         => \$opt{demo_mode},
) or die "Bad options\n";

# ---------------- Term & ANSI helpers ----------------
sub esc  { "\e[" . shift }
sub gotorc { my ($r,$c)=@_; sprintf "\e[%d;%dH",$r,$c }
sub clr_eol { esc("K") }
sub hide_cursor { print esc("?25l") }
sub show_cursor { print esc("?25h") }
sub set_scroll_region { my ($top,$bot)=@_; print esc("${top};${bot}r") }
sub reset_scroll_region { print esc("r") }
sub reset_attrs_str { esc("0m") }
sub fg256 { my ($n)=@_; $opt{no_color} ? "" : esc("38;5;${n}m") }
sub bg256 { my ($n)=@_; $opt{no_color} ? "" : esc("48;5;${n}m") }
sub bold { $opt{no_color} ? "" : esc("1m") }

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

my $need_redraw = 1;     # trigger full redraw
my $inline_nums_on = 1;  # toggle with 'N' to show/hide per-glyph sensor numbers
my $min_plot_height = 6;

# gutters
my $yaxis_w   = 0;       # pure char plotting; no X/Y axes in the scroller row lines
my $pad_left  = 1;       # small left pad
my $pad_right = 1;       # small right pad

# glyphs/colors
my @glyphs = ('●','◆','■','▲','○','◇','□','△','▣','▵','✶','✦','▸','◆','◼','▴');
my @colors = (196,208,220,40,45,51,201,190,33,129,99,178,75,141,214,160);

# ---------------- Serial Data ----------------
my $serial_fh;
my $serial_buffer = '';

sub open_serial_port {
    my $port = $opt{serial_port};
    my $baud = $opt{baud_rate};
    
    # Configure the serial port using stty
    system("stty -F $port $baud cs8 -cstopb -parity raw -echo") == 0
        or die "Failed to configure serial port $port: $!\n";
    
    # Open the serial port
    open($serial_fh, '<', $port) or die "Cannot open serial port $port: $!\n";
    
    # Make it non-blocking
    my $flags = fcntl($serial_fh, F_GETFL, 0) or die "fcntl F_GETFL: $!\n";
    fcntl($serial_fh, F_SETFL, $flags | O_NONBLOCK) or die "fcntl F_SETFL: $!\n";
    
    print STDERR "Opened serial port $port at $baud baud\n";
}

sub read_serial_data {
    return unless $serial_fh;
    
    my $data;
    my $bytes_read = sysread($serial_fh, $data, 1024);
    return unless defined $bytes_read && $bytes_read > 0;
    
    $serial_buffer .= $data;
    
    my @lines;
    while ($serial_buffer =~ s/^([^\n]*)\n//) {
        push @lines, $1;
    }
    
    return @lines;
}

# ---------------- Data ----------------
my $S = $opt{series};
my @values;          # current values (length S)
my @field_names;     # field names for each series
my @hist;            # history ring buffers per series (array of arrayrefs)
my $hsize = $opt{window};

# For demo mode - keep the original random data
my @start = map { 50 + rand()*50 } (1..$S);
my @vol   = map { 6 + rand()*6 }   (1..$S);

sub init_data {
    if ($opt{demo_mode}) {
        # Initialize demo data
        @field_names = map { "field$_" } (1..$S);
        for my $i (0..$S-1) {
            $values[$i] = $start[$i];
            $hist[$i]   = [];
        }
    } else {
        # Initialize empty for serial data
        @values = ();
        @field_names = ();
        @hist = ();
        $S = 0;
    }
}

sub parse_arduino_line {
    my ($line) = @_;
    chomp $line;
    $line =~ s/\r//g;  # remove carriage returns
    
    my @fields = split /\t/, $line;
    my (@names, @vals);
    
    for my $i (0..$#fields) {
        my $field = $fields[$i];
        if ($field =~ /^([^:]+):([+-]?(?:\d+\.?\d*|\.\d+))$/) {
            # Has label: "label:value"
            push @names, $1;
            push @vals, $2 + 0;  # convert to number
        } elsif ($field =~ /^([+-]?(?:\d+\.?\d*|\.\d+))$/) {
            # No label, just value: "value"
            push @names, ($i + 1);  # 1-indexed field number
            push @vals, $1 + 0;
        } else {
            # Skip malformed fields
            next;
        }
    }
    
    return (\@names, \@vals);
}

sub update_fields {
    my ($new_names, $new_values) = @_;
    
    # Check if field structure has changed
    my $structure_changed = 0;
    if (@$new_names != @field_names) {
        $structure_changed = 1;
    } else {
        for my $i (0..$#field_names) {
            if ($field_names[$i] ne $new_names->[$i]) {
                $structure_changed = 1;
                last;
            }
        }
    }
    
    if ($structure_changed) {
        # Rebuild data structures
        @field_names = @$new_names;
        $S = @field_names;
        @values = @$new_values;
        @hist = map { [] } (0..$S-1);
        $need_redraw = 1;
        print STDERR "Field structure changed: " . join(", ", @field_names) . "\n";
    } else {
        # Update values
        @values = @$new_values;
    }
    
    # Update history
    for my $i (0..$S-1) {
        push @{$hist[$i]}, $values[$i];
        shift @{$hist[$i]} while @{$hist[$i]} > $hsize;
    }
}

# ---------------- Mapping helpers ----------------
my ($plot_top, $plot_bottom, $plot_height, $plot_left, $plot_right, $plot_width);
my ($legend_col_start);

sub recompute_layout {
    ($ROWS,$COLS) = term_size();

    my $avail = $ROWS - $opt{header} - $opt{footer};
    if ($avail < $min_plot_height) {
        # keep minimal usable region
        $opt{header} = 0 if $ROWS < ($min_plot_height + $opt{footer});
        $avail = $ROWS - $opt{header} - $opt{footer};
        die "Not enough vertical space (rows=$ROWS)\n" if $avail < $min_plot_height;
    }

    $plot_top    = $opt{header} + 1;
    $plot_bottom = $ROWS - $opt{footer};
    $plot_height = $plot_bottom - $plot_top + 1;

    $plot_left   = $yaxis_w + $pad_left + 1;      # 1-based columns
    my $legend_w = 20;                             # increased width for vertical legend
    $plot_right  = $COLS - $pad_right - $legend_w;
    $plot_right  = $plot_left if $plot_right < $plot_left;
    $plot_width  = $plot_right - $plot_left + 1;

    $legend_col_start = $plot_right + 2;          # legend gutter start column
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

# ---------------- Draw fixed bars ----------------
sub draw_header {
    return if $opt{header} <= 0;
    my $barbg = 238;
    for my $r (1..$opt{header}) {
        print gotorc($r,1), bg256($barbg), fg256(231), bold();
        my $mode = $opt{demo_mode} ? "DEMO" : "SERIAL";
        my $port_info = $opt{demo_mode} ? "" : " ($opt{serial_port}\@$opt{baud_rate})";
        my $label = $r==1 ? " Serial Data Plotter [$mode]$port_info " : "";
        my $line  = sprintf(" %s%s", $label, "-" x ($COLS-1-length($label)));
        $line = substr($line, 0, $COLS-1);
        print $line, reset_attrs_str(), clr_eol();
    }
}

sub draw_footer {
    return if $opt{footer} <= 0;
    my $barbg = 238;
    for my $i (0..$opt{footer}-1) {
        my $r = $ROWS - $opt{footer} + 1 + $i;
        print gotorc($r,1), bg256($barbg), fg256(231), bold();
        my $label = $i==0
          ? " Footer — q=quit  N=toggle field numbers  (Fields: $S) "
          : "";
        my $line  = sprintf(" %s%s", $label, "-" x ($COLS-1-length($label)));
        $line = substr($line, 0, $COLS-1);
        print $line, reset_attrs_str(), clr_eol();
    }
}

# Vertical legend gutter (right side)
sub draw_legend_gutter {
    my $start_row = $plot_top;
    my $c = $legend_col_start;
    
    # Clear the legend area first
    for my $r ($start_row..$plot_bottom) {
        print gotorc($r, $c), clr_eol();
    }
    
    # Draw fields vertically
    for my $i (0..$S-1) {
        my $r = $start_row + $i;
        last if $r > $plot_bottom;  # Don't overflow the plot area
        
        my $g = $glyphs[$i % @glyphs];
        my $color = $colors[$i % @colors];
        my $name = $field_names[$i] // ($i + 1);
        my $value = defined $values[$i] ? sprintf("%.1f", $values[$i]) : "-.--";
        
        my $line = sprintf("%s%s%s %s: %s", 
            fg256($color), $g, reset_attrs_str(), 
            $name, $value);
        
        print gotorc($r, $c), $line;
    }
}

# ---------------- Render scaffolding ----------------
sub clear_screen { print esc("2J") }

sub full_redraw {
    reset_scroll_region();
    clear_screen();
    draw_header();
    draw_footer();
    set_scroll_region($plot_top, $plot_bottom);
    # place cursor at bottom of region so printing a line will scroll up
    print gotorc($plot_bottom, 1);
    draw_legend_gutter();
}

# ---------------- Input handling ----------------
sub set_raw_tty {
    system("stty -echo -icanon time 0 min 0 2>/dev/null"); # nonblocking read
}
sub restore_tty {
    system("stty sane 2>/dev/null");
}

# ---------------- Data update ----------------
sub step_series_demo {
    for my $i (0..$S-1) {
        my $step = (rand() - 0.5) * $vol[$i];
        $values[$i] += $step;
        push @{$hist[$i]}, $values[$i];
        shift @{$hist[$i]} while @{$hist[$i]} > $hsize;
    }
}

sub window_minmax {
    my ($lo,$hi) = (1e9, -1e9);
    for my $i (0..$S-1) {
        for my $v (@{$hist[$i]}) {
            $lo = $v if $v < $lo;
            $hi = $v if $v > $hi;
        }
    }
    # Ensure non-degenerate range
    if ($hi - $lo < 1e-6) { $hi += 1; $lo -= 1 }
    return ($lo,$hi);
}

# Build one row string containing all series glyphs at mapped columns
sub build_plot_row {
    my ($vmin, $vmax) = @_;
    return "" if $S == 0;  # No data yet
    
    my $width = $plot_width;
    my @buf = (' ') x $COLS;

    # draw series points
    for my $i (0..$S-1) {
        my $col = val_to_col($values[$i], $vmin, $vmax);
        my $glyph = $glyphs[$i % @glyphs];
        my $color = $colors[$i % @colors];
        if ($col >= 1 && $col <= $COLS) {
            my $cell = ($opt{no_color} ? "" : fg256($color)) . $glyph . reset_attrs_str();
            # place only inside plot area; other cols remain spaces
            if ($col >= $plot_left && $col <= $plot_right) {
                $buf[$col-1] = ($opt{no_color} ? "" : fg256($color)) . $glyph . reset_attrs_str();
                if ($inline_nums_on) {
                    my $num = ($i+1);
                    my $num_s = "$num";
                    for (my $k=0; $k<length($num_s); $k++) {
                        my $cc = $col + $k;
                        last if $cc > $plot_right;
                        $buf[$cc-1] = ($opt{no_color} ? "" : fg256($color)) . substr($num_s,$k,1) . reset_attrs_str();
                    }
                }
            }
        }
    }

    # optional subtle left/right borders for the plot area
    my $border_col = 244;
    if ($plot_left-1 >= 1) {
        $buf[$plot_left-2] = fg256($border_col) . '│' . reset_attrs_str();
    }
    if ($plot_right+1 <= $COLS) {
        $buf[$plot_right] = fg256($border_col) . '│' . reset_attrs_str();
    }

    # Return the visible line covering the whole width
    return join('', @buf[0..$COLS-1]);
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
    close($serial_fh) if $serial_fh;
    $cleaned = 1;
}

# WINCH handler: recompute layout and redraw
$SIG{WINCH} = sub {
    recompute_layout();
    $need_redraw = 1;
};

# Die/quit handlers
$SIG{INT}  = sub { cleanup(); restore_tty(); exit 130 };
$SIG{TERM} = sub { cleanup(); restore_tty(); exit 143 };
$SIG{__DIE__} = sub { cleanup(); restore_tty(); die @_ };

# Initialize data and serial
init_data();
unless ($opt{demo_mode}) {
    eval { open_serial_port(); };
    if ($@) {
        print STDERR "Warning: Could not open serial port: $@";
        print STDERR "Falling back to demo mode\n";
        $opt{demo_mode} = 1;
        init_data();
    }
}

# Initial layout & draw
recompute_layout();
full_redraw();
set_raw_tty();

# Nonblocking input + main loop
require Time::HiRes;
my $sleep_s = ($opt{delay_ms} // 0) / 1000.0;
$sleep_s = 0.1 if $sleep_s == 0;  # Default to 100ms for serial reading

while (1) {
    my $ch = '';
    my $n = sysread(STDIN, $ch, 1);
    if (defined $n && $n > 0) {
        if ($ch eq 'q') { last; }
        if ($ch eq 'N') {
        	$inline_nums_on = !$inline_nums_on;
        }
    }

    if ($need_redraw) {
        full_redraw();
        $need_redraw = 0;
    }

    # Read and process data
    my $data_updated = 0;
    if ($opt{demo_mode}) {
        step_series_demo();
        $data_updated = 1;
    } else {
        my @lines = read_serial_data();
        for my $line (@lines) {
            next if $line =~ /^\s*$/;  # Skip empty lines
            my ($names, $values) = parse_arduino_line($line);
            if (@$names > 0) {
                update_fields($names, $values);
                $data_updated = 1;
                last;  # Use the last valid line in this batch
            }
        }
    }

    # Only plot if we have data and it was updated
    if ($data_updated && $S > 0) {
        my ($vmin,$vmax) = window_minmax();

        # Build one row and print it at bottom of scroll region
        my $row = build_plot_row($vmin,$vmax);
        print gotorc($plot_bottom, 1), $row, clr_eol(), "\n";

        # Keep cursor at bottom inside region so LF scrolls only within region
        print gotorc($plot_bottom, 1);
        
        # Update legend with current values
        draw_legend_gutter();
    }

    Time::HiRes::sleep($sleep_s) if $sleep_s > 0;
}

restore_tty();
cleanup();
exit 0;
