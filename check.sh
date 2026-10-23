#!/usr/bin/env bash
# Check this setup after any change: shell lint and format, Perl syntax, the 100-column limit
# on the hooks, and the hook test suite (fixtures plus real cargo clippy runs, a few minutes).
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

shell_files=("$SETUP_DIR/install.sh" "$SETUP_DIR/check.sh" "$SETUP_DIR/claude/statusline.sh"
  "$HOOKS"/*/*.sh "$HOOKS/rust/tests/run.sh")

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
if [[ "${1:-}" != --quick ]]; then
  step "hook tests" bash "$HOOKS/rust/tests/run.sh"
fi

exit "$failed"
