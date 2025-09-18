#!/usr/bin/perl
use v5.36;
use Term::ReadKey;
use Term::Terminfo;
use Time::HiRes "gettimeofday";

# Timeout for multi-byte sequences (in milliseconds)
my $kb_input_timeout_ms = 200;  # 50ms

sub millis() {
    my ($s, $usec) = gettimeofday();
    my $ms = $s*1000 + int($usec/1000);
    return $ms;
}

# Global state for key processing
my $key_buffer = '';
my $keyseq_activity_ms;

# Load terminal capabilities
my $term = Term::Terminfo->new();
my $seq_up = $term->getstr('kcuu1');        
my $seq_down = $term->getstr('kcud1');      
my $seq_left = $term->getstr('kcub1');      
my $seq_right = $term->getstr('kcuf1');     

my $seq_ctrlup = "\e[1;5A";     
my $seq_ctrldown = "\e[1;5B";   
my $seq_ctrlleft = "\e[1;5D";   
my $seq_ctrlright = "\e[1;5C";  

my @target_sequences = grep { defined } (
    $seq_up, $seq_down, $seq_left, $seq_right,
    $seq_ctrlup, $seq_ctrldown, $seq_ctrlleft, $seq_ctrlright
);

sub printable_str($s) {
    return $s =~ /^[\x20-\x7E]+$/ ? $s
         : join('', map { sprintf("\\x%02X", ord($_)) } split //, $s);
}

# Informational: show what those sequences are
say "Detected mappings:";
say "  Up         = ", defined $seq_up ? printable_str($seq_up) : "(undef)";
say "  Down       = ", defined $seq_down ? printable_str($seq_down) : "(undef)";
say "  Left       = ", defined $seq_left ? printable_str($seq_left) : "(undef)";
say "  Right      = ", defined $seq_right ? printable_str($seq_right) : "(undef)";
say "  Ctrl+Up    = ", printable_str($seq_ctrlup);
say "  Ctrl+Down  = ", printable_str($seq_ctrldown);
say "  Ctrl+Left  = ", printable_str($seq_ctrlleft);
say "  Ctrl+Right = ", printable_str($seq_ctrlright);

# Non-blocking key processor
# Returns: undef (no complete key), or hashref with key info
sub process_keys() {
    # Try to read a character (non-blocking)
    my $c = ReadKey(-1);
    
    # If no character available, check for timeout on existing buffer
    if (!defined $c) {
        if (length($key_buffer) > 0 && defined $keyseq_activity_ms) {
            my $current_ms = millis();
            my $elapsed_ms = $current_ms - $keyseq_activity_ms;
            if ($elapsed_ms > $kb_input_timeout_ms) {
                # Timeout - process first character in buffer
                my $key = substr($key_buffer, 0, 1, '');
                if (length($key_buffer) == 0) {
                    undef $keyseq_activity_ms;
                }
                
                return {
                    type => ($key eq "\e") ? 'escape' : 'char',
                    key => $key,
                    printable => printable_str($key),
                    elapsed_ms => $elapsed_ms
                };
            }
        }
        return undef;  # No input, no timeout
    }
    
    # Check for exact sequence matches
    if (defined $seq_ctrlup && $key_buffer eq $seq_ctrlup) {
        my $elapsed_ms = millis() - $keyseq_activity_ms;
        $key_buffer = '';
        undef $keyseq_activity_ms;
        return { type => 'ctrl_up', key => $seq_ctrlup, printable => printable_str($seq_ctrlup), elapsed_ms => $elapsed_ms };
    }
    if (defined $seq_ctrldown && $key_buffer eq $seq_ctrldown) {
        my $elapsed_ms = millis() - $keyseq_activity_ms;
        $key_buffer = '';
        undef $keyseq_activity_ms;
        return { type => 'ctrl_down', key => $seq_ctrldown, printable => printable_str($seq_ctrldown), elapsed_ms => $elapsed_ms };
    }
    if (defined $seq_ctrlleft && $key_buffer eq $seq_ctrlleft) {
        my $elapsed_ms = millis() - $keyseq_activity_ms;
        $key_buffer = '';
        undef $keyseq_activity_ms;
        return { type => 'ctrl_left', key => $seq_ctrlleft, printable => printable_str($seq_ctrlleft), elapsed_ms => $elapsed_ms };
    }
    if (defined $seq_ctrlright && $key_buffer eq $seq_ctrlright) {
        my $elapsed_ms = millis() - $keyseq_activity_ms;
        $key_buffer = '';
        undef $keyseq_activity_ms;
        return { type => 'ctrl_right', key => $seq_ctrlright, printable => printable_str($seq_ctrlright), elapsed_ms => $elapsed_ms };
    }
    if (defined $seq_up && $key_buffer eq $seq_up) {
        my $elapsed_ms = millis() - $keyseq_activity_ms;
        $key_buffer = '';
        undef $keyseq_activity_ms;
        return { type => 'up', key => $seq_up, printable => printable_str($seq_up), elapsed_ms => $elapsed_ms };
    }
    if (defined $seq_down && $key_buffer eq $seq_down) {
        my $elapsed_ms = millis() - $keyseq_activity_ms;
        $key_buffer = '';
        undef $keyseq_activity_ms;
        return { type => 'down', key => $seq_down, printable => printable_str($seq_down), elapsed_ms => $elapsed_ms };
    }
    if (defined $seq_left && $key_buffer eq $seq_left) {
        my $elapsed_ms = millis() - $keyseq_activity_ms;
        $key_buffer = '';
        undef $keyseq_activity_ms;
        return { type => 'left', key => $seq_left, printable => printable_str($seq_left), elapsed_ms => $elapsed_ms };
    }
    if (defined $seq_right && $key_buffer eq $seq_right) {
        my $elapsed_ms = millis() - $keyseq_activity_ms;
        $key_buffer = '';
        undef $keyseq_activity_ms;
        return { type => 'right', key => $seq_right, printable => printable_str($seq_right), elapsed_ms => $elapsed_ms };
    }
    
    # Check if buffer could be start of a target sequence
    my $is_prefix = 0;
    for my $seq (@target_sequences) {
        if (index($seq, $key_buffer) == 0) {
            $is_prefix = 1;
			# We got a character - add to buffer and reset the inter-sequence timing
            last;
        }
    }
    
    if ($is_prefix) {
        # Could be start of sequence - keep accumulating
		$keyseq_activity_ms = millis();
		$key_buffer .= $c;
        return undef;
    } else {
        # Not a prefix - emit first character
        my $elapsed_ms = millis() - $keyseq_activity_ms;
        my $key = substr($key_buffer, 0, 1, '');
        if (length($key_buffer) == 0) {
            undef $keyseq_activity_ms;
        }
        
        return {
            type => ($key eq "\e") ? 'escape' : 'char',
            key => $key,
            printable => printable_str($key),
            elapsed_ms => $elapsed_ms
        };
    }
}

# Demo usage with timing information
$SIG{INT} = sub { ReadMode('restore'); exit 1 };
END { ReadMode('restore') }
ReadMode('raw');
$| = 1;

say "Non-blocking key demo with millisecond timing. Press keys (q to quit)...";
say "Detected sequences:";
say "  Up: ", printable_str($seq_up // "(undef)");
say "  Ctrl+Up: ", printable_str($seq_ctrlup);

my $counter = 0;
my $last_time_ms = millis();

while (1) {
    my $current_ms = millis();
    
    # Process any available keys
    if (my $key_info = process_keys()) {
        my $type = $key_info->{type};
        my $printable = $key_info->{printable};
        my $elapsed = $key_info->{elapsed_ms} // 0;
        
        if ($type eq 'char' && $key_info->{key} eq 'q') {
            say "Quitting...";
            last;
        }
        
        my ($s, $usec) = gettimeofday();
        printf "[%02d:%02d:%02d.%03d] Key: %-10s [%s] (sequence took: %dms)\n",
            (localtime($s))[2,1,0], int($usec/1000),
            $type, $printable, $elapsed;
    }
    
    # Do your other processing here
    $counter++;
    if ($counter % 100000 == 0) {
        print ".";  # Show we're still doing work
    }
    
    # Show timing every second
    if ($current_ms - $last_time_ms > 10000) {
        my ($s, $usec) = gettimeofday();
        printf "[%02d:%02d:%02d.%03d] Still working... (counter: %d)\n",
            (localtime($s))[2,1,0], int($usec/1000), $counter;
        $last_time_ms = $current_ms;
    }
    
    # Small delay to prevent burning CPU
    select(undef, undef, undef, 0.001);  # 1ms delay
}
