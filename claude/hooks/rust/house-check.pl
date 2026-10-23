#!/usr/bin/env perl
# house-check: line-level rust-style rules that clippy cannot express
# (research/SYNTHESIS.md 5.2). Called by check-on-stop.sh with the files an agent changed;
# the caller keeps only findings on changed lines.
#
# Usage: house-check.pl FILE...    (.rs files and Cargo.toml; anything else is ignored)
# Output: `path:line: [ID] (rust-style RULE) message` per finding on stdout.
# Exit: 0 clean, 1 findings, 2 usage or read error.
#
# Escape hatch for a false positive: `// house-check: allow(<ID>): <reason>` (`#` in a
# Cargo.toml) at the end of the line or on its own line directly above. The reason is
# mandatory; an allow without one is itself a finding (HC-ALLOW) and suppresses nothing.
#
# Rust files go through a small lexer first: string and char literal contents are blanked
# and comments split off, so code rules never fire on text inside a string or a comment
# (doc examples included), and comment rules never fire on code. It is not a parser:
# multi-line constructs are matched with simple, local heuristics.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(basename dirname);
use FindBin;

my @findings;
my $ALLOW = qr{house-check:\s*allow\(\s*([A-Z][A-Z-]*)\s*\)\s*(?::\s*(.*?))?\s*$};

# True when line $i of file $f carries, or sits under, an allow with a reason for $id.
sub allowed {
  my ($f, $i, $id) = @_;
  for my $j ($i, $i - 1) {
    next if $j < 0;
    my $line = $f->{raw}[$j];
    next if $j < $i && $line !~ m{^\s*(?://|#)};
    return 1 if $line =~ $ALLOW && $1 eq $id && defined $2 && $2 =~ /\S/;
  }
  return 0;
}

# Record a finding on 0-based line $i unless an allow covers it.
sub report {
  my ($f, $i, $id, $msg) = @_;
  return if allowed($f, $i, $id);
  push @findings, sprintf '%s:%d: [%s] %s', $f->{path}, $i + 1, $id, $msg;
  return;
}

# Usage and read errors exit 2, so a caller can tell them from findings (exit 1).
sub fail {
  my ($msg) = @_;
  print STDERR "house-check: $msg\n";
  exit 2;
}

sub read_lines {
  my ($path) = @_;
  open my $fh, q{<}, $path or fail("cannot read $path: $!");
  chomp(my @lines = <$fh>);
  close $fh;
  return @lines;
}

sub check_allow_reasons {
  my ($f) = @_;
  my $raw = $f->{raw};
  for my $i (0 .. $#$raw) {
    next unless $raw->[$i] =~ $ALLOW && !(defined $2 && $2 =~ /\S/);
    push @findings, sprintf '%s:%d: [HC-ALLOW] house-check allow without a reason: write'
      . ' `house-check: allow(%s): <why the rule is wrong here>`', $f->{path}, $i + 1, $1;
  }
  return;
}

# ---- Lexer -------------------------------------------------------------------------------

# Returns (\@code, \@comment). $code[i] is line i with string/char contents and comments
# replaced by spaces (same length, so offsets match the raw line). $comment[i] is the
# comment text on line i, starting at its `//` or `/*`, or ''. State carries across lines
# for block comments and multi-line strings.
sub lex {
  my ($raw) = @_;
  my (@code, @comment);
  my ($state, $hashes, $depth) = ('code', 0, 0);
  for my $line (@$raw) {
    my ($code, $comment) = ('', '');
    pos($line) = 0;
    while (pos($line) < length $line) {
      if ($state eq 'str') {
        if ($line =~ /\G(\\.?)/gc) { $code .= ' ' x length $1 }
        elsif ($line =~ /\G"/gc) { $code .= '"'; $state = 'code' }
        else { $line =~ /\G./gc; $code .= ' ' }
      } elsif ($state eq 'raw') {
        my $end = '"' . ('#' x $hashes);
        if ($line =~ /\G\Q$end\E/gc) { $code .= $end; $state = 'code' }
        else { $line =~ /\G./gc; $code .= ' ' }
      } elsif ($state eq 'block') {
        if ($line =~ m{\G\*/}gc) { $state = 'code' if --$depth == 0; $comment .= '*/' }
        elsif ($line =~ m{\G/\*}gc) { $depth++; $comment .= '/*' }
        else { $line =~ /\G(.)/gc; $comment .= $1 }
        $code .= length($code) < pos($line) ? ' ' x (pos($line) - length $code) : '';
      } elsif ($line =~ m{\G//}gc) {
        $comment = substr $line, pos($line) - 2;
        $code .= ' ' x length $comment;
        last;
      } elsif ($line =~ m{\G/\*}gc) {
        ($state, $depth) = ('block', 1);
        $comment .= '/*';
        $code .= '  ';
      } elsif ($line =~ /\G(?<![\w])(b?r)(#*)"/gc) {
        ($state, $hashes) = ('raw', length $2);
        $code .= "$1$2\"";
      } elsif ($line =~ /\G"/gc) {
        $code .= '"';
        $state = 'str';
      } elsif ($line =~ /\G'(\\u\{[0-9a-fA-F]+\}|\\x[0-9a-fA-F]{2}|\\.|[^\\'])'/gc) {
        $code .= "'" . (' ' x length $1) . "'";
      } else {
        $line =~ /\G(.)/gcs;
        $code .= $1;
      }
    }
    push @code, $code;
    push @comment, $comment;
  }
  return (\@code, \@comment);
}

sub is_doc_comment {
  my ($comment) = @_;
  return $comment =~ m{^//[/!](?!/)};
}

# Strip complete leading attributes from a code line. Returns (rest, open_depth): open_depth
# is the bracket depth left open when an attribute continues on the next line.
sub strip_attrs {
  my ($code) = @_;
  while ($code =~ /^\s*#!?\[/) {
    my $depth = 0;
    my $i = index $code, '[';
    for (; $i < length $code; $i++) {
      my $c = substr $code, $i, 1;
      $depth++ if $c eq '[';
      $depth-- if $c eq ']';
      last if $depth == 0;
    }
    return ('', $depth) if $depth > 0;
    $code = substr $code, $i + 1;
  }
  return ($code, 0);
}

# First item code after line $i (from $rest, else the following lines), skipping blank
# lines, comments, and attributes. Returns '' at end of file.
sub next_item {
  my ($code, $i, $rest) = @_;
  my ($text, $depth) = strip_attrs($rest);
  return $text if $text =~ /\S/;
  for my $j ($i + 1 .. $#$code) {
    my $line = $code->[$j];
    if ($depth > 0) {
      $depth += () = $line =~ /\[/g;
      $depth -= () = $line =~ /\]/g;
      $line = $depth > 0 ? '' : substr $line, rindex($line, ']') + 1;
    }
    ($text, $depth) = strip_attrs($line) if $depth == 0;
    return $text if $text =~ /\S/;
  }
  return '';
}

# Brace depth before each line, from the blanked code.
sub brace_depths {
  my ($code) = @_;
  my ($depth, @before) = (0);
  for my $line (@$code) {
    push @before, $depth;
    $depth += () = $line =~ /\{/g;
    $depth -= () = $line =~ /\}/g;
  }
  return \@before;
}

# Line indexes inside the brace block opened at or after line $i (the body only).
sub block_lines {
  my ($code, $depths, $i) = @_;
  my $open = $i;
  $open++ while $open <= $#$code && $code->[$open] !~ /\{/;
  my $j = $open + 1;
  $j++ while $j <= $#$code && $depths->[$j] > $depths->[$open];
  return ($open + 1 .. $j - 1);
}

# ---- File classification ------------------------------------------------------------------

# Nearest directory at or above $dir holding a Cargo.toml, or undef.
sub crate_dir {
  my ($dir) = @_;
  while (1) {
    return $dir if -f "$dir/Cargo.toml";
    my $parent = dirname $dir;
    return undef if $parent eq $dir;
    $dir = $parent;
  }
}

# Crate dir when $path is a library src file: under the crate's src/, the crate has
# src/lib.rs, and the file is not a binary root (src/main.rs, src/bin/**). tests/,
# examples/, benches/ sit outside src/. Otherwise undef.
sub library_crate {
  my ($path) = @_;
  my $abs = abs_path($path) // return undef;
  my $crate = crate_dir(dirname $abs) // return undef;
  return undef unless -f "$crate/src/lib.rs";
  my $rel = substr $abs, length($crate) + 1;
  return undef if $rel !~ m{^src/} || $rel eq 'src/main.rs' || $rel =~ m{^src/bin/};
  return $crate;
}

# Same scope as the library-api topic gate: publishing is opt-in (house-metadata.pl).
my %published;
sub is_published {
  my ($crate) = @_;
  $published{$crate} //=
    system('perl', "$FindBin::Bin/house-metadata.pl", 'published', $crate) == 0 ? 1 : 0;
  return $published{$crate};
}

# True when the crate at $dir has a library target: src/lib.rs or a [lib] table.
sub has_lib_target {
  my ($dir) = @_;
  return 1 if -f "$dir/src/lib.rs";
  return grep { /^\s*\[\s*lib\s*\]/ } read_lines("$dir/Cargo.toml");
}

# ---- Rust rules ---------------------------------------------------------------------------

# Comment lines directly above line $i (skipping attributes), top to bottom.
sub comment_block_above {
  my ($f, $i) = @_;
  my ($code, $comment) = @$f{qw(code comment)};
  my $j = $i - 1;
  $j-- while $j >= 0 && $code->[$j] =~ /^\s*#!?\[/;
  my @block;
  while ($j >= 0 && $code->[$j] !~ /\S/ && $comment->[$j] =~ m{^//(?![/!])}) {
    unshift @block, $comment->[$j--];
  }
  return ($j, @block);
}

sub has_safety_comment {
  my (@block) = @_;
  return grep { $block[$_] =~ m{^//\s*SAFETY:(.*)$} && ($1 =~ /\S/ || $_ < $#block) }
    0 .. $#block;
}

# Like clippy, accept the safety comment above the unsafe line or above the start of the
# statement holding it: walk up through lines that do not end a statement (`;`, `{`, `}`).
sub check_unsafe_spelling {
  my ($f) = @_;
  my $code = $f->{code};
  my $why = '(rust-style topics/unsafe.md)';
  for my $i (0 .. $#$code) {
    next unless $code->[$i] =~ /\bunsafe\s*\{|\bunsafe\s+impl\b/;
    my ($line, $first_seen, $ok) = ($i, undef, 0);
    while (1) {
      my ($above, @block) = comment_block_above($f, $line);
      if (has_safety_comment(@block)) {
        $ok = 1;
        last;
      }
      $first_seen //= $block[0] if @block;
      last if $above < 0 || $code->[$above] !~ /\S/ || $code->[$above] =~ /[;{}]\s*$/;
      $line = $above;
    }
    next if $ok;
    if (!defined $first_seen) {
      report($f, $i, 'UNS-SPELL', "$why unsafe without a safety comment: put"
          . ' `// SAFETY: <why this is sound>` above it or above its statement');
      next;
    }
    my $found = $first_seen =~ s/^\s+|\s+$//gr;
    report($f, $i, 'UNS-SPELL',
      "$why safety comment must be spelled exactly `// SAFETY: <reason>` (found `$found`)");
  }
  return;
}

sub check_panics {
  my ($f) = @_;
  my ($raw, $code) = @$f{qw(raw code)};
  for my $i (0 .. $#$code) {
    if ($code->[$i] =~ /\bunreachable!\s*[(\[{]\s*[)\]}]/) {
      report($f, $i, 'PAN-UNREACHABLE',
        '(rust-style PAN-6) bare unreachable!(): state the invariant,'
          . ' unreachable!("<why this cannot happen>")');
    }
    while ($code->[$i] =~ /\.expect\(\s*"([^"]*)"\s*\)/g) {
      my $msg = substr $raw->[$i], $-[1], $+[1] - $-[1];
      next if length($msg =~ s/^\s+|\s+$//gr) >= 4;
      report($f, $i, 'PAN-EXPECT',
        "(rust-style PAN-6) expect message \"$msg\" says nothing: name the invariant that"
          . ' makes this infallible, .expect("<invariant>")');
    }
  }
  return;
}

# The first TODO/FIXME/XXX/HACK in comment $text that is used as a marker and lacks a
# tracker, or undef. A marker opens the comment text or is followed by `:` or `(`; the
# same word in prose ("returns the TODO items") is not one.
sub untracked_marker {
  my ($text, $tracker) = @_;
  while ($text =~ /\b(TODO|FIXME|XXX|HACK)\b/g) {
    my ($word, $start, $end) = ($1, $-[0], $+[0]);
    my $opens = substr($text, 0, $start) =~ m{^\s*(?://[/!]?|/\*[*!]?|\*)?\s*$};
    next unless $opens || substr($text, $end, 1) =~ /[:(]/;
    return $word if substr($text, $end) !~ /^$tracker/;
  }
  return undef;
}

sub check_comments {
  my ($f) = @_;
  my $comment = $f->{comment};
  my $tracker = qr{\((?:#\d+|https?://[^\s)]+|MSRV 1\.\d+(?:\.\d+)?)\)};
  for my $i (0 .. $#$comment) {
    my $text = $comment->[$i];
    next if $text =~ /house-check:\s*allow/;
    if (my $marker = untracked_marker($text, $tracker)) {
      report($f, $i, 'DOC-TODO',
        "(rust-style DOC-10) $marker needs a tracker: $marker(#N), $marker(<url>), or"
          . " $marker(MSRV 1.xx)");
    }
    if ($text =~ /\b((?:LAY|NAM|DAT|API|CTL|ERR|PAN|DOC|LOG|LNT|TST|UNS|CON|ASY|LIB|REPO)-\d+)\b/) {
      report($f, $i, 'DOC-RULEID',
        "(rust-style DOC-11) rule ID $1 in a comment: state the reason itself; rule IDs"
          . ' belong in reviews and commit messages');
    }
    if (is_doc_comment($text) && $text =~ m{^//[/!]\s*```\s*(\S*)}) {
      my $info = $1;
      if ($info =~ /\bcompile_fail\b/ && $info !~ /\bE\d{4}\b/) {
        report($f, $i, 'DOC-COMPILE-FAIL',
          '(rust-style DOC-3) compile_fail doctest without an error code: write'
            . ' ```compile_fail,E0XXX so it fails for the intended reason only');
      }
    }
  }
  return;
}

sub check_code_lines {
  my ($f) = @_;
  my ($code, $comment) = @$f{qw(code comment)};
  my $type = qr{^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|union)\b};
  for my $i (0 .. $#$code) {
    my $line = $code->[$i];
    if ($line =~ /#\[\s*cfg_attr\s*\(\s*miri\s*,\s*ignore\s*\)\s*\]/
      && $comment->[$i] !~ m{^//\s*\S})
    {
      report($f, $i, 'TST-MIRI',
        '(rust-style topics/testing.md) say why Miri cannot run this test:'
          . ' #[cfg_attr(miri, ignore)] // <reason>');
    }
    if ($line =~ /\bsuper::super::/) {
      report($f, $i, 'LAY-SUPER',
        '(rust-style LAY-4) super::super:: path: use an absolute crate:: path');
    }
    if ($line =~ /#\[\s*must_use\s*\]/ && next_item($code, $i, substr($line, $+[0])) =~ $type) {
      report($f, $i, 'API-MUSTUSE',
        '(rust-style API-8) bare #[must_use] on a type: give the reason,'
          . ' #[must_use = "<what is lost if this is dropped>"]');
    }
  }
  return;
}

# ERR-3: library code never uses anyhow or eyre. Binaries, tests and examples may.
sub check_library_errors {
  my ($f) = @_;
  my $code = $f->{code};
  for my $i (0 .. $#$code) {
    next unless $code->[$i] =~ /(?<!::)\b(anyhow|eyre|color_eyre)::/;
    report($f, $i, 'ERR-ANYHOW',
      "(rust-style ERR-3) `$1` in library code: define a concrete error type"
        . ' (enum or opaque struct) and use `?` with From impls');
  }
  return;
}

# Per-line flags for ERR-BOXDYN: `test` for lines in a #[cfg(test)] module, and the body
# depth of a `pub trait` / `pub enum` whose direct members are public API.
sub api_scopes {
  my ($code, $depths) = @_;
  my (@test, @member_depth);
  my $pending_test = 0;
  for my $i (0 .. $#$code) {
    next unless $code->[$i] =~ /\S/;
    $pending_test = 1 if $code->[$i] =~ /#\[\s*cfg\s*\(\s*test\s*\)\s*\]/;
    my ($item) = strip_attrs($code->[$i]);
    next unless $item =~ /\S/;
    if ($pending_test && $item =~ /\bmod\s+\w+/) {
      $test[$_] = 1 for block_lines($code, $depths, $i);
    }
    $pending_test = 0;
    if ($item =~ /^\s*pub\s+(?:unsafe\s+)?(?:trait|enum)\b/) {
      my @body = block_lines($code, $depths, $i);
      $member_depth[$_] //= $depths->[$i] + 1 for @body;
    }
  }
  return (\@test, \@member_depth);
}

# Box<dyn Error> as the trait object itself; `Box<dyn Fn(Error)>` does not match.
my $BOX_DYN_ERROR = qr{\bBox\s*<\s*dyn\s+(?:(?:::)?(?:std|core)::error::)?Error\b};

# Only public signatures count: `pub fn` signatures (to the body's `{` or the `;`),
# `pub type`, `pub` fields, and the members of a `pub trait` / `pub enum`.
sub check_box_dyn_error {
  my ($f) = @_;
  my $code = $f->{code};
  my $depths = brace_depths($code);
  my ($test, $member_depth) = api_scopes($code, $depths);
  my $pub_fn = qr{^\s*pub\s+(?:(?:const|async|unsafe|extern\s*"[^"]*")\s+)*fn\b};
  my $member_fn = qr{^\s*(?:(?:const|async|unsafe|extern\s*"[^"]*")\s+)*fn\b};
  my %public;
  for my $i (0 .. $#$code) {
    next if $test->[$i];
    my $line = $code->[$i];
    my $member = defined $member_depth->[$i] && $depths->[$i] == $member_depth->[$i];
    if ($line =~ $pub_fn || $line =~ /^\s*pub\s+type\b/ || ($member && $line =~ $member_fn)) {
      for my $j ($i .. $#$code) {
        $public{$j} = 1;
        last if $code->[$j] =~ /[{;]/;
      }
    }
    $public{$i} = 1 if $member || $line =~ /^\s*pub\s+\w+\s*:/ || $line =~ /\bpub\s+Box\b/;
  }
  for my $i (sort { $a <=> $b } keys %public) {
    next unless $code->[$i] =~ $BOX_DYN_ERROR;
    report($f, $i, 'ERR-BOXDYN',
      '(rust-style ERR-2) Box<dyn Error> in a public library signature: return a concrete'
        . ' error type (an enum or an opaque struct) so callers can match on it');
  }
  return;
}

# True when the item starting at line $i is a `pub async fn` or a `pub fn` returning
# `impl Future`.
sub is_pub_async_fn {
  my ($code, $i, $item) = @_;
  my $quals = qr{(?:(?:const|async|unsafe|extern\s*"[^"]*")\s+)*};
  return 1 if $item =~ /^\s*pub\s+(?:(?:const|unsafe)\s+)*async\s+$quals fn\b/x;
  return 0 unless $item =~ /^\s*pub\s+$quals fn\b/x;
  my $sig = $item;
  for (my $j = $i + 1; $sig !~ /[{;]/ && $j <= $#$code && $j <= $i + 15; $j++) {
    $sig .= " $code->[$j]";
  }
  $sig =~ s/[{;].*//s;
  return $sig =~ /->\s*impl\s+(?:[\w:]+::)?Future\b/;
}

sub check_cancel_safety {
  my ($f) = @_;
  my ($code, $comment) = @$f{qw(code comment)};
  my ($cancel_doc, $depth) = (0, 0);
  for my $i (0 .. $#$code) {
    my $line = $code->[$i];
    if ($depth > 0) {
      $depth += () = $line =~ /\[/g;
      $depth -= () = $line =~ /\]/g;
      next;
    }
    if ($line !~ /\S/) {
      $cancel_doc ||= $comment->[$i] =~ m{^///\s*#\s+Cancel safety\b}i;
      next;
    }
    (my $item, $depth) = strip_attrs($line);
    next if $depth > 0 || $item !~ /\S/;

    if (!$cancel_doc && is_pub_async_fn($code, $i, $item)) {
      report($f, $i, 'DOC-CANCEL',
        '(rust-style ASY-1) public async fn (or fn returning impl Future) without a'
          . ' `# Cancel safety` doc section: say what is lost if the future is dropped'
          . ' before it completes');
    }
    $cancel_doc = 0;
  }
  return;
}

sub check_rust_file {
  my ($path) = @_;
  my @raw = read_lines($path);
  my ($code, $comment) = lex(\@raw);
  my $f = { path => $path, raw => \@raw, code => $code, comment => $comment };
  check_allow_reasons($f);
  check_unsafe_spelling($f);
  check_panics($f);
  check_comments($f);
  check_code_lines($f);
  if (my $crate = library_crate($path)) {
    check_library_errors($f);
    check_box_dyn_error($f);
    check_cancel_safety($f) if is_published($crate);
  }
  return;
}

# ---- Cargo.toml rules ---------------------------------------------------------------------

# ERR-3 in a published library crate's manifest: a banned crate in a normal dependencies
# table (also target-specific ones): `anyhow = ..`, `"anyhow" = ..`, `anyhow.workspace = true`,
# `x = { package = "anyhow" }`, `[dependencies.anyhow]`. An internal crate's binary may depend
# on it directly (the library sources are still checked by check_library_errors). Dev- and
# build-dependencies are fine, as is `optional = true` (a CLI-only dependency behind a `cli`
# feature, LAY-9) and [workspace.dependencies], which only declares a version.
sub check_manifest {
  my ($path) = @_;
  my @raw = read_lines($path);
  my $f = { path => $path, raw => \@raw };
  check_allow_reasons($f);
  my $dir = dirname(abs_path($path) // $path);
  return unless has_lib_target($dir) && is_published($dir);

  my $banned = qr/anyhow|eyre|color-eyre/;
  my $deps = qr/^(?:target\.[^.]+(?:\.[^.]+)*\.)?dependencies/;
  my $in_deps = 0;
  for my $i (0 .. $#raw) {
    (my $line = $raw[$i]) =~ s/\s+#.*$|^\s*#.*$//;
    my $crate;
    if ($line =~ /^\s*\[([^\]]+)\]/) {
      my $table = $1 =~ s/\s|["']//gr;
      $in_deps = $table =~ /$deps$/;
      ($crate) = $table =~ /$deps\.($banned)$/;
    } elsif ($in_deps && $line !~ /\boptional\s*=\s*true\b/) {
      ($crate) = $line =~ /^\s*["']?($banned)["']?\s*[=.]/;
      ($crate) = $line =~ /\bpackage\s*=\s*"($banned)"/ unless defined $crate;
    }
    next unless defined $crate;
    report($f, $i, 'ERR-ANYHOW',
      "(rust-style ERR-3) `$crate` in a published library's dependencies: its users would"
        . ' build it too; make it optional behind a `cli` feature, or a dev-/build-dependency');
  }
  return;
}

# ---- Main ---------------------------------------------------------------------------------

fail("usage: house-check.pl FILE...") unless @ARGV;
for my $path (@ARGV) {
  next if $path =~ m{(?:^|/)target/} || !-f $path;
  if (basename($path) eq 'Cargo.toml') {
    check_manifest($path);
  } elsif ($path =~ /\.rs$/) {
    check_rust_file($path);
  }
}
print "$_\n" for @findings;
exit(@findings ? 1 : 0);
