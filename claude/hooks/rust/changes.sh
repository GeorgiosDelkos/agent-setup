#!/usr/bin/env bash
# What changed, for the stop-time hooks (check-on-stop.sh, review-gate.sh, review-done.sh)
# and the hooks that take a session's baseline. Sourced after common.sh, not executed.
#
# Edits made through Bash (heredocs, sed -i, cargo add) never reach the edit-tool hooks, so
# in git the changed set is git's view of the repo plus the paths the edit hooks recorded.
# Outside git only recorded paths are known.
#
# Changes are measured against a base that holds everything except this session's own work
# (diff_base): HEAD with the commits the session made undone, so committing before stopping
# hides nothing, while commits that only arrived (a pull, a checkout of main after a pull
# request merged, a fast-forward) count for nothing. The session's baseline for the repo is
# recorded when the session first touches it (its first prompt, edit, or stop there): the
# commit HEAD was at, a hash of the repo's state, and the time. The state hash tells a repo
# this session changed from a repo that was merely dirty when the session started; the time
# tells which reflog entries are the session's.
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

# This session's baseline record for root $1:
# `<commit or empty tree><TAB><repo_state><TAB><unix time><TAB><HEAD reflog lines>`.
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
  printf '%s\t%s\t%s\t%s\n' "$head" "$(repo_state "$root")" "$(date +%s)" \
    "$(reflog_lines "$root")" >"$file"
}

# Number of entries in git root $1's HEAD reflog; 0 when it keeps none.
reflog_lines() {
  local log
  log="$(git -C "$1" rev-parse --path-format=absolute --git-path logs/HEAD)"
  if [[ -f "$log" ]]; then
    wc -l <"$log" | tr -d ' '
  else
    printf '0'
  fi
}

# Unix time root $1's baseline was recorded: its third field, or the file's modification
# time for a baseline written before the field existed.
baseline_time() {
  local file
  file="$(baseline_file "$1")"
  awk -F '\t' 'NF >= 3 { print $3; found = 1 } END { exit !found }' "$file" ||
    perl -e 'print +(stat shift)[9]' "$file"
}

# The repo's default branch: origin's HEAD, else a local main or master, else nothing.
default_branch() {
  local root="$1" branch
  if branch="$(git -C "$root" symbolic-ref -q --short refs/remotes/origin/HEAD)"; then
    printf '%s' "$branch"
    return 0
  fi
  for branch in main master; do
    if git -C "$root" rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
      printf '%s' "$branch"
      return 0
    fi
  done
}

# Commits made in this checkout of git root $1 after HEAD reflog entry $2 that HEAD still
# contains, newest first. When $2 is -1 (a record from before positions were kept), the
# entries timed at or after unix time $3 instead. A commit, an amend or a hand-finished
# merge always counts; a cherry-pick, revert or rebase step only when its commit was authored
# at or after $3, so replaying older work does not count as writing it. Moves that only
# arrive at a commit (checkout, pull, merge, reset, rebase start and finish) are not listed.
# Fails when the repo keeps no HEAD reflog.
commits_since() {
  local root="$1" skip="$2" since="$3" log commit kind
  log="$(git -C "$root" rev-parse --path-format=absolute --git-path logs/HEAD)"
  [[ -f "$log" ]] || return 1
  # Reflog line: `<old> <new> <name> <email> <time> <zone><TAB><message>`.
  awk -F '\t' -v since="$since" -v skip="$skip" '
    {
      n = split($1, field, " ")
      if (skip >= 0 ? NR <= skip : field[n - 1] + 0 < since + 0) next
      if ($2 ~ /^commit/) kind = "own"
      else if ($2 ~ /^(cherry-pick|revert)/ ||
        $2 ~ /^(rebase|pull --rebase)[^:]*\((pick|reword|edit|squash|fixup|continue)\)/)
        kind = "replay"
      else next
      line[++count] = field[2] "\t" kind
    }
    END { for (i = count; i >= 1; i--) if (!seen[line[i]]++) print line[i] }' "$log" |
    while IFS=$'\t' read -r commit kind; do
      git -C "$root" merge-base --is-ancestor "$commit" HEAD 2>/dev/null || continue
      if [[ "$kind" == replay ]] &&
        (($(git -C "$root" log -1 --format=%at "$commit") < since)); then
        continue
      fi
      printf '%s\n' "$commit"
    done
}

# A commit in root $1 whose tree is tree-ish $2. merge-tree and diff take commits; the
# fixed metadata makes the same tree give the same object, so stops do not litter the repo.
tree_commit() {
  GIT_AUTHOR_NAME=rust-hooks GIT_AUTHOR_EMAIL=rust-hooks GIT_AUTHOR_DATE='@0 +0000' \
    GIT_COMMITTER_NAME=rust-hooks GIT_COMMITTER_EMAIL=rust-hooks \
    GIT_COMMITTER_DATE='@0 +0000' \
    git -C "$1" commit-tree "$2^{tree}" -m 'rust-hooks diff base' </dev/null
}

# Tree of the three-way merge in root $1 of base $2, ours $3 and theirs $4 (tree-ish each),
# a conflicting hunk taking theirs. It only undoes a commit, theirs being what the commit
# was made from: when a later change touched the same lines, the default (markers around
# both sides) would leave the undone lines in the base and hide them, while theirs removes
# them, at the cost of counting the later change's lines in that hunk too.
merge_trees() {
  local root="$1" out code=0
  out="$(git -C "$root" merge-tree --write-tree -X theirs --merge-base="$2" \
    "$(tree_commit "$root" "$3")" "$(tree_commit "$root" "$4")")" || code=$?
  ((code <= 1)) || return 1
  head -n 1 <<<"$out"
}

# Tree-ish commit $2 of root $1 was made from: its parent; for a merge, the tree git's own
# merge of its parents gives, so that undoing the merge undoes only what was written by
# hand; the empty tree for a root commit.
made_from() {
  local root="$1" commit="$2" out code=0
  if git -C "$root" rev-parse -q --verify "$commit^2" >/dev/null; then
    out="$(git -C "$root" merge-tree --write-tree "$commit^1" "$commit^2")" || code=$?
    ((code <= 1)) || return 1
    head -n 1 <<<"$out"
  elif git -C "$root" rev-parse -q --verify "$commit^1" >/dev/null; then
    printf '%s' "$commit^1"
  else
    printf '%s' "$EMPTY_TREE"
  fi
}

# HEAD of git root $1 with the commits on stdin (newest first) undone, as a commit; HEAD
# itself when there are none. Undoing commit C is the merge of base C, ours the tree so far,
# and theirs what C was made from. Fails when an undo fails.
undo_commits() {
  local root="$1" base commit from
  base="$(git -C "$root" rev-parse HEAD)"
  while IFS= read -r commit; do
    if [[ -z "$commit" ]]; then
      continue
    fi
    from="$(made_from "$root" "$commit")" || return 1
    base="$(merge_trees "$root" "$commit" "$base" "$from")" || return 1
  done
  if [[ "$base" == "$(git -C "$root" rev-parse HEAD)" ]]; then
    printf '%s' "$base"
  else
    tree_commit "$root" "$base"
  fi
}

# Commit (or empty tree) that git root $1's changes are measured from: HEAD with the
# commits this session made undone (commits_since the baseline). Without a HEAD reflog, or
# when an undo fails: the baseline while it is an ancestor of HEAD; after a rebase or reset
# moved it away, the merge-base of HEAD with the default branch; else HEAD.
diff_base() {
  local root="$1" base branch merge_base head commits cache key log skip
  ensure_baseline "$root"
  head="$(git -C "$root" rev-parse -q --verify HEAD)" || head=""
  if [[ -z "$head" ]]; then
    printf '%s' "$EMPTY_TREE"
    return 0
  fi

  # Three stop hooks ask in turn; the walk changes only when HEAD or the reflog does.
  cache="$(session_file "diff-base-$(printf '%s' "$root" | shasum -a 256 | cut -c 1-32)")"
  log="$(git -C "$root" rev-parse --path-format=absolute --git-path logs/HEAD)"
  key="$head"
  if [[ -f "$log" ]]; then
    key+=" $(wc -c <"$log" | tr -d ' ')"
  fi
  if [[ -f "$cache" && "$(cut -f 1 "$cache")" == "$key" ]]; then
    cut -f 2 "$cache"
    return 0
  fi

  skip="$(awk -F '\t' '{ print (NF >= 4 ? $4 : -1) }' "$(baseline_file "$root")")"
  if commits="$(commits_since "$root" "$skip" "$(baseline_time "$root")")" &&
    base="$(undo_commits "$root" <<<"$commits")"; then
    printf '%s\t%s\n' "$key" "$base" >"$cache"
    printf '%s' "$base"
    return 0
  fi

  base="$(cut -f 1 "$(baseline_file "$root")")"
  if [[ "$base" == "$EMPTY_TREE" ]] ||
    git -C "$root" merge-base --is-ancestor "$base" HEAD 2>/dev/null; then
    printf '%s' "$base"
    return 0
  fi
  branch="$(default_branch "$root")"
  if [[ -n "$branch" ]] && merge_base="$(git -C "$root" merge-base HEAD "$branch")"; then
    printf '%s' "$merge_base"
  else
    printf '%s' "$head"
  fi
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
# files $3.... One per line, sorted.
changed_files() {
  local root="$1" base="$2"
  shift 2
  {
    if is_git_root "$root"; then
      git -C "$root" -c core.quotepath=off diff --name-only "$base" --
      git -C "$root" -c core.quotepath=off ls-files --others --exclude-standard
    fi | awk -v root="$root/" '{ print root $0 }'
    cat /dev/null "$@" 2>/dev/null | awk -v root="$root/" 'index($0, root) == 1' || true
  } | grep -E '(\.rs|/Cargo\.toml)$' | { grep -vE "$SCRATCH_RE" || true; } | sort -u || true
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

# Review state of root $1: the directory of snapshots taken at its last rust-style-reviewer
# run. Its existence means a review happened.
review_dir() {
  printf '%s/review-%s' "$RUST_HOOKS_STATE" "$(printf '%s' "$1" | shasum -a 256 | cut -c 1-32)"
}

# `path<TAB>snapshot` for every path on stdin: its snapshot file in the review state of root
# $1, keyed by a hash of the path. One perl process for all paths: a shasum per path takes
# tens of seconds over thousands of files.
review_snapshots() {
  REVIEW_DIR="$(review_dir "$1")" perl -MDigest::SHA=sha256_hex -ne \
    'chomp; print "$_\t$ENV{REVIEW_DIR}/", substr(sha256_hex($_), 0, 32), "\n"'
}

# Where git root $1's last rust-style-reviewer run left its HEAD reflog:
# `<unix time><TAB><reflog entries>`, written by review-done.sh.
review_position_file() {
  printf '%s/reflog' "$(review_dir "$1")"
}

# Commit git root $1's changes since the last rust-style-reviewer run are measured from:
# HEAD with the commits made after the review undone. Nothing when no review of the repo
# recorded its position, or the walk fails.
review_base() {
  local root="$1" record commits
  record="$(review_position_file "$root")"
  if [[ ! -f "$record" ]]; then
    return 0
  fi
  commits="$(commits_since "$root" "$(cut -f 2 "$record")" "$(cut -f 1 "$record")")" ||
    return 0
  undo_commits "$root" <<<"$commits" || true
}
