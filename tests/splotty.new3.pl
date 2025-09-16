sub load_state {
    return unless -f $state_file;
    
    eval {
        my $state = LoadFile($state_file);
        
        # Load last used fieldspec if no fieldspec specified
        if (!$opt{fieldspec} && $state->{last_state} && $state->{last_state}->{fieldspec_path}) {
            $opt{fieldspec} = $state->{last_state}->{fieldspec_path};
        }
        
        # Load saved states if using same fieldspec
        if ($state->{last_state} && 
            $state->{last_state}->{fieldspec_path} eq abs_path($opt{fieldspec} // '')) {
            %group_states = %{$state->{last_state}->{groups} // {}};
            %field_states = %{$state->{last_state}->{fields} // {}};
        }
    };
    warn "Failed to load state: $@" if $@;
}

sub save_state {
    return unless $fieldspec_path;
    
    get_config_dir();  # Ensure directory exists
    my $state = {};
    if (defined $fieldspec_path) {
        $state = {
            last_state => {
                fieldspec_path => $fieldspec_path,
                groups => \%group_states,
                fields => \%field_states,
            }
        };
    }
    
    eval {
        DumpFile($state_file, $state);
    };
    warn "Failed to save state: $@" if $@;
}

sub load_fieldspec {
    my ($file) = @_;
    return unless $file && -f $file;
    
    eval {
        %fieldspec = %{LoadFile($file)};
        $fieldspec_path = abs_path($file);
        
        # Initialize group states from fieldspec
        if ($fieldspec{groups}) {
            for my $group_name (keys %{$fieldspec{groups}}) {
                my $group = $fieldspec{groups}->{$group_name};
                $group_states{$group_name} //= $group->{state} // 1;
                
                if ($group->{key} && $group->{key} ne 'auto') {
                    $group_shortcuts{$group_name} = $group->{key};
                    $shortcut_to_group{$group->{key}} = $group_name;
                }
            }
        }
        
        # Initialize field states and collect manual shortcuts (skip hidden fields)
        my %manual_field_shortcuts;
        if ($fieldspec{fields}) {
            for my $field_name (keys %{$fieldspec{fields}}) {
                my $field = $fieldspec{fields}->{$field_name};
                
                # Skip hidden fields - they don't get state or shortcuts
                next if $field->{hidden};
                
                # Field starts with global start state, then affected by groups
                my $start_state = $fieldspec{state}->{start} // 1;
                $field_states{$field_name} //= $start_state;
                
                if ($field->{key} && $field->{key} ne 'auto') {
                    $manual_field_shortcuts{$field_name} = $field->{key};
                }
            }
        }
        
        # Apply group states to fields in order
        apply_group_states_to_fields();
        
        # Auto-assign shortcuts for 'auto' fields and groups
        assign_auto_shortcuts(\%manual_field_shortcuts);
        
        set_debug("Loaded fieldspec: $file");
    };
    
    if ($@) {
        my $err = <<~"EOT";
            Failed to load fieldspec '$file': $@
            Use --wipe to clear it from our state file at:
              $state_file
            Use --force to just run, ignoring the fieldspec file
            EOT
        if ($opt{force} || $opt{wipe}) {
            swarn($err);
        }
        if ($opt{wipe}) {
            $fieldspec_path = undef;
            save_state();
            swarn("Wiped.");
            exit 0;
        } elsif (!$opt{force}) {
            swarn($err);
            exit 1;
        }
        return;
    }
    
    return 1;
}

sub apply_group_states_to_fields {
    return unless $fieldspec{groups} && $fieldspec{fields};
    
    # Get groups sorted by order
    my @ordered_groups = sort { 
        ($fieldspec{groups}->{$a}->{order} // 999) <=> 
        ($fieldspec{groups}->{$b}->{order} // 999) 
    } keys %{$fieldspec{groups}};
    
    # Apply group states to their fields (skip hidden fields)
    for my $group_name (@ordered_groups) {
        my $group_state = $group_states{$group_name};
        
        for my $field_name (keys %{$fieldspec{fields}}) {
            my $field = $fieldspec{fields}->{$field_name};
            next if $field->{hidden};  # Skip hidden fields
            
            my $field_groups = $field->{groups} // [];
            
            if (grep { $_ eq $group_name } @$field_groups) {
                $field_states{$field_name} = $group_state;
            }
        }
    }
}

sub assign_auto_shortcuts {
    my ($manual_field_shortcuts) = @_;
    
    # Collect all strings that need auto-assignment
    my @auto_fields = ();
    my @auto_groups = ();
    
    # Find auto fields (skip hidden fields)
    if ($fieldspec{fields}) {
        for my $field_name (keys %{$fieldspec{fields}}) {
            my $field = $fieldspec{fields}->{$field_name};
            next if $field->{hidden};  # Skip hidden fields
            
            if (($field->{key} // '') eq 'auto') {
                push @auto_fields, $field_name;
            }
        }
    }
    
    # Find auto groups
    if ($fieldspec{groups}) {
        for my $group_name (keys %{$fieldspec{groups}}) {
            my $group = $fieldspec{groups}->{$group_name};
            if (($group->{key} // '') eq 'auto') {
                push @auto_groups, $group_name;
            }
        }
    }
    
    # Collect excluded keys (UI keys + manual assignments)
    my @exclude = ('q', 'N', 'Q');  # Reserved UI keys
    push @exclude, values %$manual_field_shortcuts;
    push @exclude, values %group_shortcuts;
    
    # Assign shortcuts for auto fields
    if (@auto_fields) {
        my %auto_field_shortcuts = assign_shortcuts(
            strings => \@auto_fields,
            exclude => \@exclude,
            manual => {},
        );
        
        for my $field_name (@auto_fields) {
            if (my $key = $auto_field_shortcuts{$field_name}) {
                $field_shortcuts{$field_name} = $key;
                $shortcut_to_field{$key} = $field_name;
                push @exclude, $key;
            }
        }
    }
    
    # Assign shortcuts for auto groups
    if (@auto_groups) {
        my %auto_group_shortcuts = assign_shortcuts(
            strings => \@auto_groups,
            exclude => \@exclude,
            manual => {},
        );
        
        for my $group_name (@auto_groups) {
            if (my $key = $auto_group_shortcuts{$group_name}) {
                $group_shortcuts{$group_name} = $key;
                $shortcut_to_group{$key} = $group_name;
            }
        }
    }
    
    # Add manual field shortcuts
    for my $field_name (keys %$manual_field_shortcuts) {
        my $key = $manual_field_shortcuts->{$field_name};
        $field_shortcuts{$field_name} = $key;
        $shortcut_to_field{$key} = $field_name;
    }
}

sub is_field_enabled {
    my ($field_name) = @_;
    return $field_states{$field_name} // 1;
}

sub is_field_hidden {
    my ($field_name) = @_;
    my $config = get_field_config($field_name);
    return $config->{hidden} // 0;
}

sub get_field_config {
    my ($field_name) = @_;
    return $fieldspec{fields}->{$field_name} // {};
}

# Calculate how many lines we need for legend
sub calculate_legend_lines_needed {
    return 0 if $S == 0;
    
    # Get non-hidden fields for display
    my @display_fields;
    for my $i (0..$S-1) {
        my $field_name = $field_names[$i] // ($i + 1);
        next if is_field_hidden($field_name);  # Skip hidden fields
        push @display_fields, $i;
    }
    
    return 1 if @display_fields == 0;  # At least one line for "no fields to show"
    
    # Calculate field display lengths
    my $total_length = 8;  # "Fields: " prefix
    my $available_width = $COLS - 2;  # Account for padding
    my $lines = 1;
    
    for my $i (@display_fields) {
        my $field_name = $field_names[$i] // ($i + 1);
        my $config = get_field_config($field_name);
        my $shortcut = $field_shortcuts{$field_name} // '';
        
        # Calculate display text length (approximating highlighted chars)
        my $display_length = length($field_name) + 20;  # glyph + value + padding + shortcut + OFF indicator
        
        if ($total_length + $display_length > $available_width) {
            $lines++;
            $total_length = 8 + $display_length;  # Reset with indent
        } else {
            $total_length += $display_length;
        }
    }
    
    return $lines;
}

# Color definitions for field name highlighting
sub a_fieldname { reset_attrs_str() }  # Normal field name color
sub a_fieldname_disabled { $opt{no_color} ? "" : fg256(240) }  # Dimmed for disabled fields
sub a_hotkey { $opt{no_color} ? "" : fg256(226) . bold() }  # Bright yellow for hotkey
sub a_rst { reset_attrs_str() }  # Reset
sub a_warn { esc("33;1m") }

sub highlight_field_name {
    my ($field_name, $shortcut, $is_enabled) = @_;
    
    my $base_color = $is_enabled ? a_fieldname() : a_fieldname_disabled();
    return $base_color . $field_name . a_rst() unless $shortcut;
    
    # Highlight the shortcut character in the field name
    my $highlighted_name = $field_name;
    if ($highlighted_name =~ s/(\Q$shortcut\E)/x${a_hotkey()}$1${base_color}z/i) {
        return $base_color . $highlighted_name . a_rst();
    } else {
        # If shortcut not found in name, just append it
        return $base_color . $field_name . a_rst() . "(" . a_hotkey() . $shortcut . a_rst() . ")";
    }
}

sub draw_legend {
    return if $legend_lines_needed <= 0 || $S == 0;
    
    my $barbg = 236;  # Slightly different background for legend
    
    # Get non-hidden fields for display (both enabled and disabled)
    my @display_fields;
    for my $i (0..$S-1) {
        my $field_name = $field_names[$i] // ($i + 1);
        next if is_field_hidden($field_name);  # Skip hidden fields only
        push @display_fields, $i;
    }
    
    # Handle case where no fields are available for display
    if (@display_fields == 0) {
        my $r = $legend_start_row;
        print gotorc($r, 1), bg256($barbg), fg256(231);
        my $msg = " No fields to display ";
        my $line = $msg . " " x ($COLS - 1 - length($msg));
        print $line, reset_attrs_str(), clr_eol();
        
        # Clear remaining legend lines
        for my $remaining_line (1..$legend_lines_needed-1) {
            my $clear_r = $legend_start_row + $remaining_line;
            print gotorc($clear_r, 1), bg256($barbg), fg256(231);
            print " " x ($COLS - 1), reset_attrs_str(), clr_eol();
        }
        return;
    }
    
    # Pre-calculate field display strings
    my @field_displays;
    for my $i (@display_fields) {
        my $field_name = $field_names[$i] // ($i + 1);
        my $config = get_field_config($field_name);
        my $is_enabled = is_field_enabled($field_name);
        my $g = $config->{ch} // $glyphs[$i % @glyphs];
        my $shortcut = $field_shortcuts{$field_name} // '';
        
        my $value_str;
        if (defined $values[$i]) {
            # Format numbers based on magnitude for better display
            my $val = $values[$i];
            if (abs($val) >= 1000) {
                $value_str = sprintf("%.0f", $val);
            } elsif (abs($val) >= 100) {
                $value_str = sprintf("%.1f", $val);
            } elsif (abs($val) >= 10) {
                $value_str = sprintf("%.2f", $val);
            } else {
                $value_str = sprintf("%.3f", $val);
            }
        } else {
            $value_str = "-.---";
        }
        
        # Create highlighted field name
        my $highlighted_name = highlight_field_name($field_name, $shortcut, $is_enabled);
        
        # Add OFF indicator for disabled fields
        my $status_indicator = $is_enabled ? "" : " [OFF]";
        
        # Build display text with glyph and value
        my $display_text = sprintf("%s %s:%s%s  ", $g, $highlighted_name, $value_str, $status_indicator);
        
        # Approximate length for layout (ignoring color codes)
        my $approx_length = length($g) + 1 + length($field_name) + 1 + length($value_str) + 
                           ($shortcut ? length($shortcut) + 2 : 0) + 
                           ($is_enabled ? 0 : 6) + 3;  # 6 for " [OFF]"
        
        # Determine color from field config or default
        my $color;
        my $is_rgb = 0;
        if ($config->{fg24}) {
            # RGB color specified
            $color = $config->{fg24};
            $is_rgb = 1;
        } elsif (defined $config->{fg}) {
            # 256-color specified
            $color = $config->{fg};
        } else {
            # Default color
            $color = $colors[$i % @colors];
        }
        
        # Dim color for disabled fields
        if (!$is_enabled && !$is_rgb) {
            # For 256-color, use a dimmed version
            $color = 240;  # Gray
        } elsif (!$is_enabled && $is_rgb) {
            # For RGB, dim by reducing all components
            $color = [map { int($_ * 0.5) } @$color];
        }
        
        push @field_displays, {
            text => $display_text,
            length => $approx_length,
            color => $color,
            index => $i,
            is_rgb => $is_rgb,
            is_enabled => $is_enabled,
        };
    }
    
    # Distribute fields across available lines
    my $current_field = 0;
    
    for my $line_idx (0..$legend_lines_needed-1) {
        my $r = $legend_start_row + $line_idx;
        print gotorc($r, 1), bg256($barbg), fg256(231);
        
        my $line_content = " ";
        my $available_width = $COLS - 2;  # Account for padding
        
        if ($line_idx == 0) {
            $line_content .= "Fields: ";
            $available_width -= 8;  # "Fields: " = 8 chars
        } else {
            $line_content .= "        ";  # Indent continuation lines
            $available_width -= 8;
        }
        
        my $current_line_length = 8;  # Start with prefix length
        
        # Add as many fields as will fit on this line
        while ($current_field < @field_displays && 
               $current_line_length + $field_displays[$current_field]->{length} <= $available_width) {
            
            my $field = $field_displays[$current_field];
            
            # Add the field with proper color coding for the glyph
            my $color_code;
            if ($field->{is_rgb}) {
                $color_code = fg24(@{$field->{color}});
            } else {
                $color_code = fg256($field->{color});
            }
            
            # Get the actual display text and add glyph coloring
            my $display = $field->{text};
            if ($display =~ /^(\S+) (.+)$/) {
                my ($glyph, $rest) = ($1, $2);
                $line_content .= reset_attrs_str() . $color_code . $glyph . 
                               reset_attrs_str() . bg256($barbg) . fg256(231) . " " . $rest;
            } else {
                $line_content .= reset_attrs_str() . bg256($barbg) . fg256(231) . $display;
            }
            
            $current_line_length += $field->{length};
            $current_field++;
        }
        
        # Pad the line to full width
        my $padding_needed = $COLS - 1 - length($line_content);
        # Calculate padding more accurately by removing ANSI codes
        my $clean_content = $line_content;
        $clean_content =~ s/\e\[[0-9;]*m//g;
        $padding_needed = $COLS - 1 - length($clean_content);
        $padding_needed = 0 if $padding_needed < 0;
        $line_content .= " " x $padding_needed;
        
        print $line_content, reset_attrs_str(), clr_eol();
        
        # If we've shown all fields, clear remaining legend lines
        if ($current_field >= @field_displays) {
            for my $remaining_line ($line_idx + 1..$legend_lines_needed-1) {
                my $clear_r = $legend_start_row + $remaining_line;
                print gotorc($clear_r, 1), bg256($barbg), fg256(231);
                print " " x ($COLS - 1), reset_attrs_str(), clr_eol();
            }
            last;
        }
    }
}

# Build one row string containing all series glyphs at mapped columns
sub build_plot_row {
    my ($vmin, $vmax) = @_;
    return "" if $S == 0;  # No data yet
    
    my $width = $plot_width;
    my @buf = (' ') x $COLS;
    
    # draw series points (only for enabled and non-hidden fields)
    for my $i (0..$S-1) {
        my $field_name = $field_names[$i] // ($i + 1);
        next if is_field_hidden($field_name);   # Skip hidden fields
        next unless is_field_enabled($field_name);  # Skip disabled fields
        
        my $col = val_to_col($values[$i], $vmin, $vmax);
        my $config = get_field_config($field_name);
        my $glyph = $config->{ch} // $glyphs[$i % @glyphs];
        
        # Determine color from field config or default
        my $color_code;
        if ($config->{fg24}) {
            $color_code = fg24(@{$config->{fg24}});
        } elsif (defined $config->{fg}) {
            $color_code = fg256($config->{fg});
        } else {
            $color_code = fg256($colors[$i % @colors]);
        }
        
        if ($col >= 1 && $col <= $COLS) {
            # place only inside plot area; other cols remain spaces
            if ($col >= $plot_left && $col <= $plot_right) {
                $buf[$col-1] = $color_code . $glyph . reset_attrs_str();
                if ($inline_nums_on) {
                    my $num = ($i+1);
                    my $num_s = "$num";
                    for (my $k=0; $k<length($num_s); $k++) {
                        my $cc = $col + $k;
                        last if $cc > $plot_right;  # stay within plot boundaries
                        $buf[$cc-1] = $color_code . substr($num_s,$k,1) . reset_attrs_str();
                    }
                }
            }
        }
    }
    
    # optional subtle left/right borders for the plot area
    my $border_col = 244;
    # Left border: one column before plot area
    if ($plot_left-1 >= 1) {
        $buf[$plot_left-2] = fg256($border_col) . '│' . reset_attrs_str();
    }
    # Right border: one column after plot area  
    my $right_border_col = $plot_right + 1;
    if ($right_border_col <= $COLS) {
        $buf[$right_border_col-1] = fg256($border_col) . '│' . reset_attrs_str();
    }
    
    # Return the visible line covering the whole width
    return join('', @buf[0..$COLS-1]);
}

sub window_minmax {
    my ($lo,$hi) = (1e9, -1e9);
    for my $i (0..$S-1) {
        my $field_name = $field_names[$i] // ($i + 1);
        next if is_field_hidden($field_name);    # Skip hidden fields
        next unless is_field_enabled($field_name);  # Skip disabled fields
        
        for my $v (@{$hist[$i]}) {
            $lo = $v if $v < $lo;
            $hi = $v if $v > $hi;
        }
    }
    # Ensure non-degenerate range
    if ($hi - $lo < 1e-6) { $hi += 1; $lo -= 1 }
    return ($lo,$hi);
}