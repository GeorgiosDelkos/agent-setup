---
name: bash-style
description: Use when writing or reviewing Bash/sh scripts or shell snippets committed to a repo. Strict-mode header, shellcheck and shfmt rules.
---

# Bash house style

Global rules live in `~/.config/agents/AGENTS.md`. This skill adds only shell rules.

- Every script starts with a shebang, then `set -euo pipefail`.
- Lint and format check: `shellcheck script.sh && shfmt -d -i 2 script.sh`.
  Fix with `shfmt -w -i 2 script.sh`.
- Quote every expansion. Use `"$@"`, never `$*`.
- Fix every shellcheck finding. If one can't be fixed, use an inline
  `# shellcheck disable=SCxxxx` with the reason on the same line.
- `[[ ]]` over `[ ]`, `local` for every function variable, `"$(...)"` over backticks.
- Temporary files in `mktemp -d`, removed by a `trap '...' EXIT` set right after it, so an
  early exit still cleans up.
- Delete with `trash`, never `rm -rf`.
- A script with logic beyond a straight line of commands gets tests that run it against
  fixtures in a temporary directory and assert on exit code, stdout, and the files it
  leaves: `bats-core` cases, or the repo's own harness where it has one (a `tests/run.sh`
  of fixture cases). Lint and format checks are not tests.
- When writing a new script that will pass roughly 100 lines or needs real data
  structures, propose Python (uv script) or Rust instead. Not a review finding on an
  existing script that must stay bash: hooks and installers that run before any toolchain
  exists, such as `agent-setup`'s, which depend only on bash, jq and perl.
