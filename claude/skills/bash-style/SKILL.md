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
- Delete with `trash`, never `rm -rf`.
- If a script grows past roughly 100 lines or needs real data structures, propose
  rewriting it in Python (uv script) or Rust.
