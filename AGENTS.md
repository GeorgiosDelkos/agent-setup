# agent-setup: rules for work in this repo

These add to the global rules. `agents/AGENTS.md` is that global file (every machine reads
it through `~/.config/agents/`); this file covers only changes to this repo. Layout, hooks
and install: `agents/SETUP.md`.

- **The deployed copy is live.** On a machine where `install.sh` ran, `~/.claude/hooks`,
  `skills`, `agents`, `commands`, `scripts` and `~/.config/agents` are symlinks into one
  checkout: `readlink ~/.claude/hooks` prints `<that checkout>/claude/hooks`. Every session
  on the machine runs its hooks and reads its rules from that checkout's working files.
  Never edit a file, switch a branch, or check out a commit there: a branch switch swaps
  the hooks under running sessions. The only writes there are the update steps of
  `agents/SETUP.md`, Version control, after a merge: the pull or the fetch and mixed reset
  it names for that machine, then `install.sh` when it says to.
- **Work in a separate clone**, on a branch. When the current directory is the deployed
  copy, clone the repo beside it first. The global rule on commits still decides when:
  asked only to change something here, make the change in the clone and say where it is.
  The commit, draft PR and review steps of Version control follow once the user asks for
  the PR.
- **`bash check.sh` before every commit**: it runs the linters and every test suite, and
  takes about four minutes. `--quick` skips the suites, for a prose-only change.
- **A hook change comes with its test and its doc**: a case in `check.sh`'s suite for it
  (`claude/hooks/memory/tests/run.sh` for the memory hooks,
  `claude/hooks/rust/tests/run.sh` for every other hook, `guards/bash-guard.sh` included),
  and its row in the Hooks table of `agents/SETUP.md` in the same commit. A new suite file
  runs only once `check.sh` calls it.
- **Review tiers here** (global rules, Git): code that runs in every session or on every
  machine is tier 2, which here is the hooks, `install.sh`, and `claude/settings.json`
  (it registers the hooks). Text that agents follow is tier 1: rules, skills, commands,
  `agents/SETUP.md`, and also `check.sh`. `README.md` alone is tier 0.
