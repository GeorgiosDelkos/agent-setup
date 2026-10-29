#!/usr/bin/env bash
# Check this setup after any change: shell lint and format, Perl syntax, the 100-column limit
# on the hooks, workflow lint (this repo's CI and the Rust CI templates), and the hook test
# suite (fixtures plus real cargo clippy runs, a few minutes). CI runs the same script.
#
# Usage: bash check.sh            everything
#        bash check.sh --quick    skip the test suite
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SETUP_DIR/claude/hooks"
failed=0

# Runs one named step and records a failure without stopping the others.
step() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok      $name"
  else
    echo "FAILED  $name"
    failed=1
  fi
}

# Every tracked shell script. git, not a glob: the synced folder also holds ignored local files
# (the local layer), which are not this repo's to lint, and a glob that matches nothing in CI
# would pass its own pattern to shellcheck as a file name.
if ! tracked="$(git -C "$SETUP_DIR" ls-files '*.sh')"; then
  echo "check.sh needs a git work tree (in the synced folder, install.sh sets one up)" >&2
  exit 1
fi
shell_files=()
while IFS= read -r file; do
  shell_files+=("$SETUP_DIR/$file")
done <<<"$tracked"

# Workflows: this repo's own, and the Rust templates (every file there with a `jobs:` key;
# codecov.yml and dependabot.yml are not workflows).
workflow_files=("$SETUP_DIR"/.github/workflows/*.yml)
while IFS= read -r file; do
  workflow_files+=("$file")
done < <(grep -l '^jobs:' "$SETUP_DIR"/claude/skills/rust-style/templates/ci/*.yml)

# shellcheck disable=SC2329 # invoked indirectly, through step
long_lines() {
  ! awk 'length > 100 { print FILENAME ":" FNR ": " length " columns"; found = 1 }
    END { exit !found }' "$HOOKS"/*/*.sh "$HOOKS"/rust/*.pl "$HOOKS/rust/tests/run.sh"
}

# shellcheck disable=SC2329 # invoked indirectly, through step
perl_syntax() {
  local file
  for file in "$HOOKS"/rust/*.pl; do
    perl -c "$file" 2>&1 | grep -v 'syntax OK$' || true
    perl -c "$file" >/dev/null 2>&1 || return 1
  done
}

step shellcheck shellcheck -x "${shell_files[@]}"
step shfmt shfmt -d -i 2 "${shell_files[@]}"
step "perl syntax" perl_syntax
step "100 columns" long_lines
step actionlint actionlint "${workflow_files[@]}"
step zizmor zizmor --offline --quiet "${workflow_files[@]}" "$SETUP_DIR/.github/dependabot.yml"
if [[ "${1:-}" != --quick ]]; then
  step "hook tests" bash "$HOOKS/rust/tests/run.sh"
fi

exit "$failed"
