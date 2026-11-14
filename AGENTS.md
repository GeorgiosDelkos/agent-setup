# agent-setup: rules for work in this repo

These add to the global rules. `agents/AGENTS.md` is that global file (every machine reads
it through `~/.config/agents/`); this file covers only changes to this repo. Layout, hooks
and install: `agents/SETUP.md`.

- **The deployed copy is live.** On a machine where `install.sh` ran, `~/.claude/hooks`,
  `skills`, `agents`, `commands`, `scripts` and `~/.config/agents` are symlinks into one
  checkout (`readlink ~/.claude/hooks` names it). Every session on the machine runs its
  hooks and reads its rules from that checkout's working files. Never edit a file, switch a
  branch, or check out a commit there: a branch switch swaps the hooks under running
  sessions. The one write allowed there is `git pull --ff-only` after a merge.
- **Work in a separate clone**, on a branch (`agents/SETUP.md`, Version control). When the
  current directory is the deployed copy, clone the repo beside it first.
- **`bash check.sh` before every commit**: it runs the linters and every test suite, and
  takes about four minutes. `--quick` skips the suites, for a prose-only change.
- **A hook change comes with its test and its doc**: a case in the suite beside it
  (`claude/hooks/rust/tests/run.sh`, `claude/hooks/memory/tests/run.sh`), and its row in
  the Hooks table of `agents/SETUP.md` in the same commit.
- **Review tiers here** (global rules, Git): hooks, `install.sh`, and `claude/settings.json`
  are tier 2, because they run in every session or on every machine. Rules, skills,
  commands, and `check.sh` are tier 1. `README.md` alone is tier 0.
