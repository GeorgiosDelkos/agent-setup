#!/usr/bin/env bash
# What changed, for the stop check (check-on-stop.sh), the review gate and its record
# (review-gate.sh, review-done.sh), and the hooks that take a session's baseline. Sourced
# after common.sh, not executed.
#
# Edits made through Bash (heredocs, sed -i, cargo add) never reach the edit-tool hooks, so
# in git the changed set is git's view of the repo plus the paths the edit hooks recorded.
# Outside git only recorded paths are known.
#
# The change is the branch: everything since the merge-base with the default branch, which
# is what the pull request and CI judge (diff_base). A pull, or a checkout of main after a
# merge, moves the merge-base with it and counts for nothing. This replaced a walk of the
# reflogs that undid "the session's own commits"; it needed a model of subagents pausing,
# resuming and editing by shell, and kept breaking on the next case. The cost accepted:
# commits made on the branch before this session count as changed too.
#
# The session's baseline for a repo, recorded when the session first touches it (its first
# prompt, edit, or stop there), holds the commit HEAD was at and a hash of the repo's state.
# The hash tells a repo this session changed from one that was merely dirty when it started;
# the commit is the base on a repo without a default branch to measure from.
#
# List-file arguments are read with `cat /dev/null "$@"`: a bare `cat` with no arguments
# would read the hook's stdin.

# The tree of an empty commit: the baseline of a repo that has no commits yet.
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

# Physical git toplevel of directory $1, or nothing.
git_root() {
  local top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 0
  (cd "$top" && pwd -P)
}

# Physical cargo workspace root of the crate in directory $1, or nothing when there is no
# Cargo.toml. Any other cargo failure (a broken manifest) is printed on stderr.
workspace_root_of() {
  local manifest
  if ! manifest="$(cd "$1" && cargo locate-project --workspace --message-format plain 2>&1)"; then
    if [[ "$manifest" != *"could not find \`Cargo.toml\`"* ]]; then
      printf 'cargo locate-project failed in %s:\n%s\n' "$1" "$manifest" >&2
    fi
    return 0
  fi
  (cd "$(dirname "$manifest")" && pwd -P)
}

# Root that keys state for path $1: its git toplevel, else its cargo workspace root, else
# nothing. $1 may be a deleted file; the nearest existing directory above it is used.
state_root_of() {
  local dir="$1" root crate
  while [[ ! -d "$dir" ]]; do
    dir="$(dirname "$dir")"
  done
  root="$(git_root "$dir")"
  if [[ -z "$root" ]]; then
    crate="$(crate_dir_of "$dir")"
    if [[ -n "$crate" ]]; then
      root="$(workspace_root_of "$crate")"
    fi
  fi
  printf '%s' "$root"
}

# Roots this stop concerns, one per line, sorted: the root of the hook input's cwd, and the
# root of every path recorded in the list files $@. A recorded file outside git and outside
# any crate is its own directory's root, so it is still checked.
stop_roots() {
  local cwd dir root
  cwd="$(hook_field '.cwd')"
  {
    if [[ -n "$cwd" && -d "$cwd" ]]; then
      state_root_of "$cwd"
      echo
    fi
    cat /dev/null "$@" 2>/dev/null | sed 's|/[^/]*$||' | sort -u | while IFS= read -r dir; do
      root="$(state_root_of "$dir")"
      if [[ -z "$root" && -d "$dir" ]]; then
        root="$(cd "$dir" && pwd -P)"
      fi
      printf '%s\n' "$root"
    done
  } | grep -v '^$' | sort -u || true
}

is_git_root() {
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1
}

# Hash of git repo $1's state: HEAD, the working-tree changes against it, and the contents
# of untracked files.
repo_state() {
  local root="$1" head
  {
    if head="$(git -C "$root" rev-parse -q --verify HEAD)"; then
      printf '%s\n' "$head"
      git -C "$root" diff HEAD
    else
      git -C "$root" ls-files --cached | git -C "$root" hash-object --stdin-paths
    fi
    git -C "$root" ls-files --others --exclude-standard |
      git -C "$root" hash-object --stdin-paths
  } | shasum -a 256 | cut -d ' ' -f 1
}

# This session's baseline record for root $1: `<commit or empty tree><TAB><repo_state>`.
baseline_file() {
  session_file "baseline-$(printf '%s' "$1" | shasum -a 256 | cut -c 1-32)"
}

# Record the session's baseline for git root $1 unless it has one already.
ensure_baseline() {
  local root="$1" file head
  file="$(baseline_file "$root")"
  if [[ -f "$file" ]] || ! is_git_root "$root"; then
    return 0
  fi
  head="$(git -C "$root" rev-parse -q --verify HEAD)" || head="$EMPTY_TREE"
  printf '%s\t%s\n' "$head" "$(repo_state "$root")" >"$file"
}

# The repo's default branch: origin's HEAD, else origin's main or master, else a local main or
# master, else nothing. origin comes first: a repo pushed after `git init` has no origin/HEAD,
# and its local main may be stale.
default_branch() {
  local root="$1" branch
  if branch="$(git -C "$root" symbolic-ref -q --short refs/remotes/origin/HEAD)"; then
    printf '%s' "$branch"
    return 0
  fi
  for branch in origin/main origin/master main master; do
    if git -C "$root" rev-parse -q --verify "$branch^{commit}" >/dev/null; then
      printf '%s' "$branch"
      return 0
    fi
  done
}

# Commit (or empty tree) that git root $1's changes are measured from: the merge-base of
# HEAD with the default branch. With a remote default branch (origin/main) that is the base
# even when it is HEAD itself: on an up-to-date main only uncommitted work counts, and a pull
# adds nothing. A local default branch has no remote to pull from, so when the merge-base is
# HEAD (the session commits on main itself) the session's baseline is used while it is an
# ancestor of HEAD, and commits made before the stop still count. Else HEAD.
diff_base() {
  local root="$1" branch base head
  ensure_baseline "$root"
  if ! head="$(git -C "$root" rev-parse -q --verify HEAD)"; then
    printf '%s' "$EMPTY_TREE"
    return 0
  fi

  branch="$(default_branch "$root")"
  if [[ -n "$branch" ]] && base="$(git -C "$root" merge-base HEAD "$branch" 2>/dev/null)" &&
    { [[ "$branch" == */* ]] || [[ "$base" != "$head" ]]; }; then
    printf '%s' "$base"
    return 0
  fi

  base="$(cut -f 1 "$(baseline_file "$root")")"
  if [[ "$base" == "$EMPTY_TREE" ]] ||
    git -C "$root" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
    printf '%s' "$base"
    return 0
  fi
  printf '%s' "$head"
}

# True when this session changed root $1: it recorded a path there (list files $2...), or,
# in git, the repo's state differs from the one stored with the baseline. A session that
# only answered questions in a dirty repo did neither.
session_caused() {
  local root="$1" baseline_state
  shift
  # grep reads the lists itself: `cat ... | grep -q` lets grep exit at the first match, cat
  # dies of SIGPIPE on the next file, and pipefail turns the match into "not caused".
  if grep -qsF -- "$root/" /dev/null "$@"; then
    return 0
  fi
  if ! is_git_root "$root"; then
    return 1
  fi
  ensure_baseline "$root"
  baseline_state="$(cut -f 2 "$(baseline_file "$root")")"
  [[ "$baseline_state" != "$(repo_state "$root")" ]]
}

# The `root<TAB>file` pairs on stdin with each file kept once, under its deepest root. A
# recorded path inside a nested git repo also lies under any non-git directory root above
# it; counted under both, it was reported twice and diffed as all-new under the outer one.
deepest_root() {
  awk -F '\t' '{ if (!($2 in best) || length($1) > length(best[$2])) best[$2] = $1 }
    END { for (f in best) printf "%s\t%s\n", best[f], f }' | sort
}

# Changed .rs and Cargo.toml paths under root $1 (absolute, possibly deleted): in git, the
# changes since base $2 plus untracked files; unioned with the paths recorded in the list
# files $3.... One per line, sorted. Scratchpad paths are kept: the stop check drops them,
# but a reviewer may review a real branch checked out in a worktree under the scratchpad.
changed_files() {
  local root="$1" base="$2"
  shift 2
  {
    if is_git_root "$root"; then
      git -C "$root" -c core.quotepath=off diff --name-only --no-renames "$base" --
      git -C "$root" -c core.quotepath=off ls-files --others --exclude-standard
    fi | awk -v root="$root/" '{ print root $0 }'
    cat /dev/null "$@" 2>/dev/null | awk -v root="$root/" 'index($0, root) == 1' || true
  } | grep -E '(\.rs|/Cargo\.toml)$' | sort -u || true
}

# Changed line ranges of the existing files $3... under root $1, measured from base $2, as
# `path<TAB>first<TAB>last` lines: the new-side hunks of one `git diff -U0` for all files.
# An untracked file, or any file outside git, is new as a whole. A pure deletion has no
# new-side lines and yields no range.
changed_ranges() {
  local root="$1" base="$2" file
  shift 2
  if ! is_git_root "$root"; then
    for file in "$@"; do
      printf '%s\t1\t%d\n' "$file" 1000000000
    done
    return 0
  fi
  git -C "$root" -c core.quotepath=off ls-files --others --exclude-standard -- "$@" |
    awk -v root="$root/" '{ printf "%s%s\t1\t%d\n", root, $0, 1000000000 }'
  git -C "$root" -c core.quotepath=off diff -U0 "$base" -- "$@" | awk -v root="$root/" '
    /^\+\+\+ / {
      # git ends a name that holds a space with a tab.
      file = ($0 == "+++ /dev/null") ? "" : root substr($0, 7)
      sub(/\t$/, "", file)
      next
    }
    /^@@/ && file != "" {
      match($0, /\+[0-9]+(,[0-9]+)?/)
      n = split(substr($0, RSTART + 1, RLENGTH - 1), part, ",")
      count = n > 1 ? part[2] : 1
      if (count > 0) printf "%s\t%d\t%d\n", file, part[1], part[1] + count - 1
    }'
}

# Filter stdin `path:line:...` findings down to those inside the ranges $1 (the lines
# changed_ranges prints). Paths may hold spaces but not colons. The ranges go through the
# environment: macOS awk rejects a newline in a -v value.
in_changed_lines() {
  RANGES="$1" awk '
    BEGIN {
      rows = split(ENVIRON["RANGES"], row, "\n")
      for (r = 1; r <= rows; r++) {
        if (split(row[r], field, "\t") == 3) {
          key = field[1]
          count[key]++
          first[key, count[key]] = field[2]
          last[key, count[key]] = field[3]
        }
      }
    }
    match($0, /^[^:]+:[0-9]+:/) {
      path = substr($0, 1, RLENGTH - 1)
      line = path
      sub(/:[0-9]+$/, "", path)
      sub(/^.*:/, "", line)
      for (i = 1; i <= count[path]; i++) {
        if (line + 0 >= first[path, i] && line + 0 <= last[path, i]) {
          print
          break
        }
      }
    }'
}

# Hash of paths and contents of the files $@, to tell whether anything changed since the
# last check.
fingerprint() {
  local file
  for file in "$@"; do
    printf '%s\n' "$file"
    cat "$file" 2>/dev/null || true
  done | shasum -a 256 | cut -d ' ' -f 1
}

# Review record of git root $1's repository: a directory of snapshots of the .rs files as
# rust-style-reviewer runs saw them. One per repository (its common git directory), not per
# worktree or session: a review in a subagent's worktree, or in an earlier session, covers the
# same files in every checkout.
#
# A snapshot is named `<path key>.<blob id>`: the key is a hash of the repo-relative path, the
# id is git's blob id of the snapshotted bytes. Agents in several worktrees of one repo review
# different versions of the same file on different branches. With one snapshot per path each
# review overwrote the others', and a reviewed pull request read as unreviewed (five hcfs PRs
# that all changed hcfs-server/src/billing/gate.rs, 2026-10-29). The blob id lets the gate
# find a commit's exact version without running diff.
review_dir() {
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
  printf '%s/review-%s' "$RUST_HOOKS_STATE" \
    "$(printf '%s' "$common" | shasum -a 256 | cut -c 1-32)"
}

# Snapshots kept per path, newest first. Enough for a few dozen parallel branches that touch
# one file, each with its latest review rounds; more only slows the gate, which diffs every
# snapshot of a file whose exact version no review saw. Arbitrary within that.
REVIEW_KEEP=32

# Each line on stdin with `<TAB>key` appended: the snapshot path prefix (the review record of
# root $1, then the path key) of the repo-relative path that is the line's last tab-separated
# field. One perl process for all paths: a shasum per path takes tens of seconds over
# thousands of files.
review_keys() {
  REVIEW_DIR="$(review_dir "$1")" perl -MDigest::SHA=sha256_hex -ne \
    'chomp; my $path = (split /\t/)[-1];
    print "$_\t$ENV{REVIEW_DIR}/", substr(sha256_hex($path), 0, 32), "\n"'
}

# Snapshot the files of root $1 named by the `path<TAB>key` lines on stdin (review_keys
# output), then keep only the newest REVIEW_KEEP snapshots of each path. A missing file
# snapshots as empty: the reviewed state of a deletion. Each snapshot is written to a
# temporary file and renamed into place, so a reviewer finishing at the same time, or the
# gate, never reads a partial one. Two runs at once each prune only snapshots they listed
# before writing their own, so neither removes the snapshot the other just wrote.
save_review_snapshots() {
  ROOT="$1" KEEP="$REVIEW_KEEP" perl -MDigest::SHA=sha1_hex -MFile::Temp=tempfile \
    -MTime::HiRes -we '
    use strict;
    my (%names, $listed);
    while (my $line = <STDIN>) {
      chomp $line;
      my ($path, $key) = split /\t/, $line;
      my ($dir, $hash) = $key =~ m{^(.*)/([^/]+)\z} or die "review: bad key $key\n";
      # One directory listing for all paths: a glob per path is quadratic in the record.
      # A temporary file an hour old belongs to a run that was killed (hooks time out
      # within minutes); nothing else would remove it.
      if (!$listed++) {
        opendir my $list, $dir or die "review: cannot read $dir: $!\n";
        for (readdir $list) {
          if (/^([0-9a-f]{32})\.[0-9a-f]+\z/) {
            push @{ $names{$1} }, $_;
          } elsif (/^\.tmp-/ && -M "$dir/$_" > 1 / 24) {
            unlink "$dir/$_";
          }
        }
      }
      my $content = "";
      if (open my $in, "<:raw", "$ENV{ROOT}/$path") {
        local $/;
        $content = <$in> // "";
      }
      # git hash-object, without a process per file.
      my $name = "$hash." . sha1_hex("blob " . length($content) . "\0" . $content);
      # One file that cannot be saved costs only its own review, not the rest of the run.
      my $tmp;
      my $saved = eval {
        (my $out, $tmp) = tempfile(".tmp-XXXXXX", DIR => $dir);
        binmode $out;
        print {$out} $content or die "$!\n";
        close $out or die "$!\n";
        rename $tmp, "$dir/$name" or die "$!\n";
      };
      if (!$saved) {
        warn "review: cannot save the snapshot of $path as $dir/$name: $@";
        unlink $tmp if defined $tmp;
        next;
      }
      # Sub-second mtimes: several review rounds can land in one second.
      my %mtime = map { $_ => (Time::HiRes::stat("$dir/$_"))[9] // 0 }
        grep { $_ ne $name } @{ $names{$hash} || [] };
      my @older = sort { $mtime{$b} <=> $mtime{$a} || $a cmp $b } keys %mtime;
      unlink map { "$dir/$_" } splice @older, $ENV{KEEP} - 1 if @older >= $ENV{KEEP};
      $names{$hash} = [$name, @older];
    }'
}
