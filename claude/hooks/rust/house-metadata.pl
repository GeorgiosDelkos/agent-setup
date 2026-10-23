#!/usr/bin/env perl
# Repo-level settings the Rust hooks read from Cargo.toml.
#
# Usage:
#   house-metadata.pl features MANIFEST     cargo feature arguments for clippy, one per line
#   house-metadata.pl baseline MANIFEST     exit 0 when the repo opted in to the house rules
#   house-metadata.pl low-level MANIFEST    exit 0 when the crate opted in to the low-level
#                                           profile (rust-style topics/low-level.md)
#   house-metadata.pl published CRATE_DIR   exit 0 when the crate opts in to being published
# Exit 1 means "no" for baseline and published; 2 is a usage or read error.
#
# A repo opts in under [workspace.metadata.house-check] (or [package.metadata.house-check]):
#
#   baseline = true          house-check and the column check run on stop, and the house rules
#                            apply in full (the repo commits the lint table, REPO-1)
#   low-level = true         a zero-dependency, low-level crate: the low-level profile's rules
#                            apply on top (topics/low-level.md)
#   all-features = true      clippy with --all-features
#   features = ["a", "b"]    clippy with --features a,b
#
# Features default to the crate defaults: `--all-features` is not safe as a default (mutually
# exclusive features, optional native deps that fail to build, errors the agent cannot fix).
#
# Published is opt-in, unlike Cargo's default: `publish = true` or a non-empty registry list in
# [package], or `publish.workspace = true` with one of those in the workspace root's
# [workspace.package]. A crate without the key counts as internal: most workspace crates never
# set it and are never published, and published-library ceremony would cost them for nothing.
use strict;
use warnings;
use File::Basename qw(dirname);

sub fail {
  my ($msg) = @_;
  print STDERR "house-metadata.pl: $msg\n";
  exit 2;
}

# key => raw value for every key of the tables whose name matches $want, in file order (a later
# table wins). Multi-line arrays are joined onto one line.
sub table {
  my ($manifest, $want) = @_;
  open my $fh, q{<}, $manifest or fail("cannot read $manifest: $!");
  my ($in_table, %values) = (0);
  while (my $line = <$fh>) {
    $line =~ s/\s+#.*$|^\s*#.*$//;
    if ($line =~ /^\s*\[\s*([^\]]+?)\s*\]/) {
      $in_table = $1 =~ $want;
      next;
    }
    next unless $in_table && $line =~ /^\s*([\w.-]+)\s*=\s*(.*?)\s*$/;
    my ($key, $value) = ($1, $2);
    $value .= ' ' . (<$fh> // '') while $value =~ /^\[/ && $value !~ /\]/ && !eof $fh;
    $values{$key} = $value;
  }
  close $fh;
  return \%values;
}

sub house_check_table {
  my ($manifest) = @_;
  return table($manifest, qr/^(?:workspace|package)\.metadata\.house-check$/);
}

sub features {
  my ($manifest) = @_;
  my $values = house_check_table($manifest);
  if (($values->{'all-features'} // '') eq 'true') {
    print "--all-features\n";
    return 0;
  }
  my $features = join ',', ($values->{features} // '') =~ /"([^"]+)"/g;
  print "--features\n$features\n" if length $features;
  return 0;
}

# Exit status for a `name = true` switch in the house-check table.
sub switch {
  my ($manifest, $name) = @_;
  return ((house_check_table($manifest)->{$name} // '') eq 'true') ? 0 : 1;
}

# True for `true` or an array naming at least one registry.
sub publishes {
  my ($value) = @_;
  return defined $value && ($value eq 'true' || $value =~ /^\[.*"[^"]+".*\]$/);
}

# Nearest directory at or above $dir whose Cargo.toml has a [workspace] table, or undef.
sub workspace_root {
  my ($dir) = @_;
  while (1) {
    my $manifest = "$dir/Cargo.toml";
    if (-f $manifest) {
      open my $fh, q{<}, $manifest or fail("cannot read $manifest: $!");
      my $is_root = grep { /^\s*\[\s*workspace\s*[\].]/ } <$fh>;
      close $fh;
      return $dir if $is_root;
    }
    my $parent = dirname $dir;
    return undef if $parent eq $dir;
    $dir = $parent;
  }
}

sub published {
  my ($crate) = @_;
  my $package = table("$crate/Cargo.toml", qr/^package$/);
  my $inherits = ($package->{'publish.workspace'} // '') eq 'true'
    || ($package->{publish} // '') =~ /^\{\s*workspace\s*=\s*true\s*\}$/;
  return publishes($package->{publish}) ? 0 : 1 unless $inherits;

  my $root = workspace_root($crate) // return 1;
  return publishes(table("$root/Cargo.toml", qr/^workspace\.package$/)->{publish}) ? 0 : 1;
}

my ($mode, $arg) = @ARGV;
fail('usage: house-metadata.pl features|baseline|low-level MANIFEST, or published CRATE_DIR')
  unless defined $arg;
exit features($arg) if $mode eq 'features';
exit switch($arg, $mode) if $mode eq 'baseline' || $mode eq 'low-level';
exit published($arg) if $mode eq 'published';
fail("unknown mode `$mode`");
