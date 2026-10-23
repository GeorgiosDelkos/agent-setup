#!/usr/bin/env perl
# Merge the house lint template (rust-style/templates/Cargo.lints.toml) with a workspace's
# own lint tables and print the result as clippy command-line lint flags, one argument per
# line: `-W`, `clippy::pedantic`, ...
#
# Usage: baseline-lints.pl TEMPLATE [WORKSPACE_CARGO_TOML]
#
# check-on-stop.sh passes these after `cargo clippy --`. Cargo applies the workspace's
# [lints] first and these flags come after them, so the last flag for a lint wins (verified
# on clippy 1.99). That is why the workspace's own entries are re-emitted here, merged with
# the template the way Cargo merges one table: the workspace's entry replaces the
# template's entry of the same name (repo config wins where it speaks), and everything is
# sorted by `priority` (stable), so groups at -1 come before the single lints that refine
# them. rustdoc lints are skipped (clippy does not run them), and so is any entry with
# `check-cfg`, which configures cfg names rather than a lint level.
use strict;
use warnings;

my %flag_for = (allow => '-A', warn => '-W', deny => '-D', forbid => '-F');
my %prefix_for = (rust => '', clippy => 'clippy::');

sub fail {
  my ($msg) = @_;
  print STDERR "baseline-lints.pl: $msg\n";
  exit 2;
}

# One lint entry from `name` and its TOML value (`"warn"` or `{ level = .., priority = .. }`).
# Level is undef when the value cannot be read; the name still counts as mentioned.
sub entry {
  my ($tool, $name, $value) = @_;
  my ($level) = $value =~ /^"(\w+)"$/;
  ($level) = $value =~ /\blevel\s*=\s*"(\w+)"/ unless defined $level;
  my ($priority) = $value =~ /\bpriority\s*=\s*(-?\d+)/;
  return {
    key => "${tool}::" . ($name =~ tr/-/_/r),
    flag => defined $level ? $flag_for{$level} : undef,
    arg => $prefix_for{$tool} . ($name =~ tr/-/_/r),
    priority => $priority // 0,
    check_cfg => ($value =~ /check-cfg/ ? 1 : 0),
  };
}

# Entries of one inline table body: `a = "warn", b = { level = "deny", priority = -1 }`.
sub inline_entries {
  my ($tool, $body) = @_;
  my @entries;
  while ($body =~ /([\w-]+)\s*=\s*("\w+"|\{[^{}]*\})/g) {
    push @entries, entry($tool, $1, $2);
  }
  return @entries;
}

# Lint entries from the [lints.*] / [workspace.lints.*] tables of a Cargo.toml, in file
# order, in all three TOML spellings: a `[lints.clippy]` table, dotted keys under
# `[lints]` (`clippy.x = "warn"`), and an inline table (`clippy = { x = "warn" }`).
sub parse_lints {
  my ($path) = @_;
  open my $fh, q{<}, $path or fail("cannot read $path: $!");
  my ($section, @entries) = ('');
  while (my $line = <$fh>) {
    $line =~ s/\s+#.*$|^\s*#.*$//;
    if ($line =~ /^\s*\[\s*([^\]]+?)\s*\]/) {
      $section = $1 =~ s/^workspace\.//r;
      next;
    }
    my ($table_tool) = $section =~ /^lints\.(\w+)$/;
    if (defined $table_tool && exists $prefix_for{$table_tool}) {
      push @entries, entry($table_tool, $1, $2) if $line =~ /^\s*([\w-]+)\s*=\s*(.+?)\s*$/;
    } elsif ($section eq 'lints' && $line =~ /^\s*(\w+)\.([\w-]+)\s*=\s*(.+?)\s*$/) {
      push @entries, entry($1, $2, $3) if exists $prefix_for{$1};
    } elsif ($section eq 'lints' && $line =~ /^\s*(\w+)\s*=\s*\{(.*)\}\s*$/) {
      push @entries, inline_entries($1, $2) if exists $prefix_for{$1};
    }
  }
  close $fh;
  return grep { !$_->{check_cfg} } @entries;
}

my ($template, $workspace) = @ARGV;
fail('usage: baseline-lints.pl TEMPLATE [WORKSPACE_CARGO_TOML]') unless defined $template;

my @merged = parse_lints($template);
for my $entry (@merged) {
  fail("$template: cannot read the level of `$entry->{arg}`") unless defined $entry->{flag};
}
if (defined $workspace) {
  my @own = parse_lints($workspace);
  my %mentioned = map { $_->{key} => 1 } @own;
  @merged = ((grep { !$mentioned{$_->{key}} } @merged), (grep { defined $_->{flag} } @own));
}

# Perl's sort is stable, so equal priorities keep template order, then workspace order.
print "$_->{flag}\n$_->{arg}\n" for sort { $a->{priority} <=> $b->{priority} } @merged;
