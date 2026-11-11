#!/usr/bin/env bash
# UserPromptSubmit: record this session's baseline for the repo it works in (the first
# prompt only; later prompts find it recorded). The baseline is HEAD plus a hash of the
# repo's state before the agent acts, so the stop hooks can measure the session's changes
# even after a commit, and can tell a repo this session changed from one that was already
# dirty (changes.sh). Never blocks a prompt.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
read_hook_input
need_tools fail-open jq git shasum
# shellcheck source-path=SCRIPTDIR source=changes.sh
source "$(dirname "${BASH_SOURCE[0]}")/changes.sh"

# Hook state does not shrink on its own: macOS does not clear $TMPDIR on a schedule (176 MB in
# 1,550 files, some 12 days old on an 11-day uptime, 2026-11-11). Once a day, delete the
# files of every session none of whose files changed for 7 days, and review snapshots
# untouched for 30. A session is judged whole, never file by file: `started` and a repo's
# baseline are written once, and losing them in a live session makes the stop check diff
# against a fresh baseline. `seen`, touched on every prompt, keeps a session that only talks
# alive. The session is a file name up to its first dot; an id with a dot in it is judged in
# parts, which only means part of it can go early. Both limits are arbitrary: a session
# resumed after a week loads its skills again, and a pruned snapshot only means the review
# gate asks for a new review. Deleted, not trashed: these are the hooks' own scratch files,
# and hundreds of them would fill the Trash.
touch "$(session_file seen)"
pruned="$RUST_HOOKS_STATE/pruned"
if [[ -z "$(find "$pruned" -mtime -1 2>/dev/null)" ]]; then
  touch "$pruned"
  perl -e 'my ($dir, $cutoff) = @ARGV;
    opendir(my $d, $dir) or exit 0;
    my (%newest, %files);
    for my $name (readdir $d) {
      my $path = "$dir/$name";
      next unless -f $path && $name =~ /^([^.]+)\./;
      my $mtime = (stat _)[9];
      push @{ $files{$1} }, $path;
      $newest{$1} = $mtime if !defined $newest{$1} || $mtime > $newest{$1};
    }
    for my $session (keys %files) {
      unlink @{ $files{$session} } if $newest{$session} < $cutoff;
    }' "$RUST_HOOKS_STATE" "$(($(date +%s) - 7 * 86400))" 2>/dev/null || true
  find "$RUST_HOOKS_STATE" -mindepth 2 -maxdepth 2 -path '*/review-*/*' -type f -mtime +30 \
    -delete 2>/dev/null || true
fi

# When the session started, for the stop check's "changed after the last test run": one stamp
# for the session, since a repo's own baseline is written only when the session first touches
# it, after the edit that touched it.
started="$(session_file started)"
if [[ ! -f "$started" ]]; then
  touch "$started"
fi
cwd="$(hook_field '.cwd')"
if [[ -n "$cwd" && -d "$cwd" ]]; then
  root="$(git_root "$cwd")"
  if [[ -n "$root" ]]; then
    ensure_baseline "$root"
  fi
fi
