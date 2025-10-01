#!/usr/bin/perl
package String::ShortcutsAuto;
use v5.36;
use Exporter 'import';
# use Data::Dumper; #debug
# use bansi; #debug
# sub pdd($v) { print Dumper($v) } #debug

our @EXPORT_OK = qw(assign_shortcuts);
our $VERSION = '1.0';

# Default conflict delay in seconds
our $def_conflict_delay_s = 1;

sub assign_shortcuts {
    my %args = @_;

    my $strings = $args{strings} // [];
    my $exclude = $args{exclude} // [];
    my $conflict_delay = $args{conflict_delay} // $def_conflict_delay_s;
    my $manual_assignments = $args{manual} // {};

	# my $unique_count = keys %{{ map { $_ => 1 } @$strings }};
	# say "Total strings: " . scalar(@$strings) . ", Unique: " . $unique_count;
	# die;
	# pdd(\%args);
    
    return {} unless @$strings;
    
    my %result = %$manual_assignments;  # Start with manual assignments
    my %used_keys = map { $_ => 1 } (values %$manual_assignments, @$exclude);
    my @conflicts = ();
    
    # Check for conflicts in manual assignments
    my %key_count;
    for my $key (values %$manual_assignments) {
        $key_count{$key}++;
    }
    for my $key (@$exclude) {
        $key_count{$key}++;
    }
    
    # Find conflicts and warn
    for my $str (keys %$manual_assignments) {
        my $key = $manual_assignments->{$str};
        if ($key_count{$key} > 1 || grep { $_ eq $key } @$exclude) {
            push @conflicts, "Conflict: '$key' assigned to '$str' but already used";
            delete $result{$str};  # Will be auto-assigned
            delete $used_keys{$key} if $key_count{$key} == 1;  # Remove if this was only use
        }
    }
    
    # Warn about conflicts
    if (@conflicts) {
        for my $conflict (@conflicts) {
            warn "$conflict\n";
        }
        sleep $conflict_delay if $conflict_delay > 0;
    }
    
    # Get list of strings that need auto-assignment
    my @auto_strings = grep { !exists $result{$_} } @$strings;
    return %result unless @auto_strings;
    # die "Assigned: " . join(' ', keys %result) . "  Auto remaining: " . join(' ', @auto_strings);
    
    # Calculate commonality scores for auto-assignment
    my %char_commonality = _calculate_commonality(\@auto_strings);
    
    # Generate candidate keys in preference order
    my @candidates = _generate_candidates(\%used_keys);
    
    # Assign keys to auto strings
    for my $str (@auto_strings) {
        my $assigned_key = _find_best_key($str, \@candidates, \%char_commonality, \%used_keys);
        say "Assigning: $assigned_key";
        if (defined $assigned_key) {
            $result{$str} = $assigned_key;
            $used_keys{$assigned_key} = 1;
		} else {
			warn "Failed to assign key to: '$str'\n";
			warn "Available candidates: " . join(',', grep { !$used_keys{$_} } @candidates) . "\n";
        }
    }

	# for my $str (@$strings) {
	# 	if (exists $result{$str}) { say "* $str => $result{$str}"; }
	# 	else { say "  $red$str$rst"; }
	# }
	# say map { "Assigning: $result{$_} -> $_\n" }  keys %result;
	# say "Count: " . scalar(keys %result);
	# die;
    return %result;
}

sub _calculate_commonality {
    my ($strings) = @_;
    my %char_score;
    my $total_strings = @$strings;
    return %char_score unless $total_strings;
    
    # Calculate 75th percentile length
    my @lengths = sort { $a <=> $b } map { length($_) } @$strings;
    my $percentile_75_idx = int($total_strings * 0.75);
    my $fields_highmean = $lengths[$percentile_75_idx] // 1;
    
    # Score each character based on position and frequency
    for my $str (@$strings) {
        my @chars = split //, lc($str);
        for my $i (0..$#chars) {
            my $char = $chars[$i];
            next unless $char =~ /[a-z0-9]/;
            
            # Weight: higher for earlier positions, scaled by field length percentile
            my $position_weight = max(1, $fields_highmean - $i) / $fields_highmean;
            $char_score{$char} += $position_weight;
        }
    }
    
    # Normalize scores (lower scores are better for selection)
    for my $char (keys %char_score) {
        $char_score{$char} /= $total_strings;
    }
    
    return %char_score;
}

sub _generate_candidates {
    my ($used_keys) = @_;
    my @candidates;
    
    # Primary candidates: a-z
    for my $c ('a'..'z') {
        push @candidates, $c unless $used_keys->{$c};
    }
    
    # Secondary candidates: 0-9
    for my $c ('0'..'9') {
        push @candidates, $c unless $used_keys->{$c};
    }
    
    # Tertiary candidates: A-Z
    for my $c ('A'..'Z') {
        push @candidates, $c unless $used_keys->{$c};
    }
    
    return @candidates;
}

sub _find_best_key {
    my ($str, $candidates, $char_commonality, $used_keys) = @_;
    
    # Get characters from the string (prefer lowercase)
    my @str_chars = map { lc($_) } split //, $str;
    @str_chars = grep { /[a-z0-9]/ } @str_chars;
    
    # Try characters from the string first, in order of lowest commonality
    my @string_candidates = sort { 
        ($char_commonality->{$a} // 0) <=> ($char_commonality->{$b} // 0) 
    } @str_chars;
    
    for my $char (@string_candidates) {
        return $char if !$used_keys->{$char} && grep { $_ eq $char } @$candidates;
    }
    
    # Fall back to first available candidate
    for my $char (@$candidates) {
        return $char unless $used_keys->{$char};
    }
    
    return undef;  # No available keys
}

sub max {
    my ($a, $b) = @_;
    return $a > $b ? $a : $b;
}

# Command-line interface when run directly
sub main {
    my @test_strings = @ARGV;
    
    # Default test if no arguments
    unless (@test_strings) {
        @test_strings = qw(
            d1.Zraw d2.Zraw d1.btn d2.btn d1.chg_rate d2.chg_rate
            d1.humanPct d2.humanPct temperature pressure humidity
            voltage current power status error debug
        );
    }
    
    my %assignments = assign_shortcuts(
        strings => \@test_strings,
        exclude => [],
        conflict_delay => 0,  # Don't sleep in CLI mode
    );
    
    print "String -> Key mappings:\n";
    for my $str (sort keys %assignments) {
        printf "  %-20s -> %s\n", $str, $assignments{$str};
    }
    
    print "\nKey -> String mappings:\n";
    my %reverse = reverse %assignments;
    for my $key (sort keys %reverse) {
        printf "  %s -> %s\n", $key, $reverse{$key};
    }
}

# Run main if called directly
main() unless caller;

1;

__END__

=head1 NAME

String::ShortcutsAuto - Automatic keyboard shortcut assignment for strings

=head1 SYNOPSIS

    use String::ShortcutsAuto qw(assign_shortcuts);
    
    my %shortcuts = assign_shortcuts(
        strings => ['field1', 'field2', 'field3'],
        exclude => ['q', 'x'],  # Keys to avoid
        manual => { 'field1' => 'f' },  # Manual assignments
        conflict_delay => 1,  # Delay after conflict warnings
    );

=head1 DESCRIPTION

This module automatically assigns keyboard shortcuts to a list of strings,
avoiding conflicts and preferring characters that are less common as prefixes
in the provided strings.

=head1 FUNCTIONS

=head2 assign_shortcuts(%args)

Assigns keyboard shortcuts to strings. Arguments:

=over 4

=item strings

Arrayref of strings to assign shortcuts to.

=item exclude

Arrayref of characters to exclude from assignment.

=item manual

Hashref of manual string->key assignments.

=item conflict_delay

Seconds to sleep after printing conflict warnings (default: 1).

=back

Returns a hash of string->key assignments.

=head1 ALGORITHM

The algorithm prioritizes characters that appear less frequently as prefixes
in the provided strings. The preference order for candidates is:
[a-z], [0-9], [A-Z].

=cut
