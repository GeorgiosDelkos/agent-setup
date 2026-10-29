# Agent setup: Claude Code + Grok

How the shared agent configuration on this machine is laid out, how to reproduce it on
another machine, and how to verify it. One rules file, shared skills, and Rust enforcement
hooks drive both Claude Code and Grok.

## Layers

Rules stick when a machine enforces them, so each rule lives in the strongest layer that
can hold it:

| Layer | Mechanism | Holds |
|---|---|---|
| Machine (repo) | Cargo `[lints]`, `clippy.toml`, `deny.toml`, prek, CI | Lints, supply chain |
| Machine (agent) | Hooks in `~/.claude/settings.json`, read by both tools | Skill and topic gates, format on edit, clippy (house baseline) + house-check + column check on stop, review gate |
| Skill | `~/.claude/skills/*` | Language style, idioms, templates, CI checklist |
| Review | `rust-style-reviewer` agent | Design principles and rules no tool can check |
| Prompt | `~/.config/agents/AGENTS.md` | Design principles, plus short global policy that points at the above |

The design principles at the top of `AGENTS.md` (first principles, simplest design, data
structures from the access pattern, APIs from the call site, readable with partial context)
are the baseline. They outrank every other rule and skill except correctness and safety.
Skills and reviewers point back to them instead of restating them; language skills add only
the idioms that apply them.

Keep `AGENTS.md` short. Language detail goes in a skill, and anything a tool can enforce
goes in a template or a hook.

## Inventory

Everything lives in one folder kept in step across machines by a file-sync service (`$SETUP`
below; any location works).
The usual locations are symlinks into it, created by `$SETUP/install.sh`, so an edit on one
machine reaches every machine.

| Path on the machine | Links to | Purpose |
|---|---|---|
| `~/.config/agents/` | `$SETUP/agents/` | `AGENTS.md` (the canonical rules) and this document. |
| `~/.claude/skills/` | `$SETUP/claude/skills/` | `rust-style` (+ `templates/`), `rfr-*`, `rust-*`, `{python,ts,bash,gh-actions}-style`, others. |
| `~/.claude/agents/` | `$SETUP/claude/agents/` | `rust-style-reviewer.md`. |
| `~/.claude/hooks/` | `$SETUP/claude/hooks/` | `rust/*.sh` enforcement hooks (see below). |
| `~/.claude/commands/` | `$SETUP/claude/commands/` | Slash commands. |
| `~/.claude/statusline.sh` | `$SETUP/claude/statusline.sh` | Status line. |
| `~/.grok/rules/AGENTS.md` | `$SETUP/agents/AGENTS.md` | Grok's global rules. |
| `~/.grok/agents/rust-style-reviewer.md` | `$SETUP/claude/agents/…` | The reviewer, for Grok. |
| `~/.claude/CLAUDE.md` | (file) | `@~/.config/agents/AGENTS.md`, plus `@~/.config/agents/AGENTS.local.md` when the local layer has one. |
| `~/.claude/settings.json` | (file, merged) | Hooks, permissions, plugins. Grok reads its hooks too. |
| `~/Library/Application Support/JetBrains/Air/acp.json` | (file, merged from `$SETUP/air/acp.json`) | Grok and Claude Code as ACP agents in JetBrains Air. |
| `~/Library/Application Support/JetBrains/Air/review/review-prompt.md` | `$SETUP/air/review-prompt.md` | Air's code-review task list, aligned with the review order in `AGENTS.md`. Air sends it as the user turn, so it outranks `AGENTS.md`. If Air replaces the link with a plain file, re-run `install.sh`. |
| `~/Library/Application Support/JetBrains/Air/themes/` | `$SETUP/air/themes/` | `Dark-Blue.json`: Air's Dark theme with loud comments (code comments orange, doc comments green, TODOs yellow), per the Comments section of `AGENTS.md`. Edit it in Air with Edit Color Theme…; the save lands in the synced folder. `install.sh` moves an existing local `themes/` folder to the backup dir; to keep a theme from it, copy the file into `$SETUP/air/themes/`, which shares it with every machine. |
| `~/Library/Application Support/JetBrains/Air/settings.json` | (file, merged from `$SETUP/air/settings.json`) | Selects the `Dark-Blue` theme. Other Air settings stay local. |

`settings.json` is the one file that is not linked: Claude Code rewrites it in place, which
would replace a symlink. `$SETUP/claude/settings.json` is the shared copy; `install.sh`
merges it in (shared keys win, local-only keys stay). To share a setting with every
machine, add only its key to `claude/settings.json` in a clone, through a PR. Copying the
whole local file would also share machine-local keys (an effort level, a model override).

Grok scans `~/.claude/skills/` and `~/.claude/settings.json` by default
(`[compat.claude] skills/hooks = true`), so skills and hooks exist once and serve both
tools.

## Permissions

Every agent runs with full bypass permissions, on every machine:

- `$SETUP/claude/settings.json` sets `permissions.defaultMode = "bypassPermissions"` and
  `skipDangerousModePermissionPrompt`. Claude Code reads it directly, the Air adapter reads it
  through the SDK, and Grok reads `defaultMode` from `~/.claude/settings.json` too.
- `$SETUP/air/acp.json` starts Grok with `--always-approve`, so Air sessions match.

Hooks still run under bypass: `bash-guard.sh` keeps blocking recursive `rm`, `find -delete`,
git commands that discard uncommitted work, pushes that update `main`/`master`, and
`gh pr merge --admin`. These are guardrails, not a sandbox: the deny rules
for `Read(~/.ssh/**)` and the like cover the Read tool only, and any Bash command can still
read those files. Only Claude Code's sandbox settings would close that.

## Hooks

| Script | Event and matcher | Effect |
|---|---|---|
| `style-gate.sh` | PreToolUse `Edit\|Write\|MultiEdit\|search_replace\|write\|hashline_edit` | Blocks an agent's first `.rs` edit until it has loaded `rust-style`, and any edit whose new text touches a topic (unsafe, concurrency, async, library API, testing, repo setup) until it has read `rust-style/topics/<topic>.md`. The deny reason (JSON `permissionDecisionReason`, read by both tools) lists exactly what to load. Without jq it fails open with a message rather than block every edit. |
| `style-loaded.sh` | PostToolUse `Skill\|Read\|read_file\|Bash` | Marks `rust-style` as loaded (Claude's Skill tool, reading its `SKILL.md` as Grok does, or a whole-file `cat` of it in Bash), and marks each topic file read the same ways. Partial reads (`head`, `sed -n`, `cat | head`) do not count. |
| `fmt-on-edit.sh` | PostToolUse, edit tools | Formats the edited `.rs` file right away through stdin (so declared child modules are never touched; the repo's rustfmt.toml is honoured), and records it; also records edited `Cargo.toml`. A syntax error is fed back to the agent. |
| `check-on-stop.sh` | Stop and SubagentStop, timeout 600 | Main agent: every repo this session changed (recorded edits plus the branch's git changes since its merge-base with the default branch, so Bash edits and commits count). Subagent: only the paths it recorded; skipped if none. Runs clippy over the changed packages and their workspace dependents with the repo's own lint tables and `clippy.toml` plus `minimal-lints.toml` (default features unless `[workspace.metadata.house-check]` says otherwise, `--cap-lints warn --keep-going`). It never injects the house template, so it checks what `cargo clippy` and CI check. In a repo that opted in (`baseline = true` in that table) it then runs `house-check.pl` and the `max_width` column check, and reports an opted-in repo that has not committed a lint table. Compiler errors block; lint and house-check findings only on changed lines. Last, `.rs` files modified this session after its last test run ask for one. Blocks once per changed state; internal failures exit 1 and never block. |
| `tests-ran.sh` | PostToolUse and PostToolUseFailure `Bash` (a failing run counts) | Records that the session ran Rust tests (`cargo test`/`t`/`nextest`/`mutants`, with toolchain and global flags and through `miri`, `hack`, `llvm-cov`, `insta`; not `--no-run` or `nextest list`), as the modification time of one session file, for check-on-stop. Commands without `cargo` exit before jq starts. |
| `run-clippy.sh` | called by check-on-stop | Clippy scoped to the changed packages plus their workspace dependents (whole workspace for a root-manifest change), per-package runs for members with their own `[lints]`, read as JSON. |
| `house-metadata.pl` | called by the hooks | Reads `[workspace.metadata.house-check]`: the `baseline` opt-in and the feature set. Also decides whether a crate is published (opt-in: `publish = ["crates-io"]`/`true`, or inherited through `publish.workspace = true`). |
| `minimal-lints.toml` | read by run-clippy | The only lints the hook adds to a repo's own config, in every repo: leftover `dbg!`/`todo!`/`unimplemented!`, undocumented `unsafe`. |
| `session-baseline.sh` | UserPromptSubmit, timeout 30 | Records each repo's HEAD and state at the session's first prompt (else at the first edit or stop): the state tells a repo this session changed from one that was already dirty, and HEAD is the base in a repo without a remote. |
| `changes.sh` | sourced by the hooks | The changed set and changed line ranges of the branch: since the merge-base with the default branch (origin's HEAD, else a local `main`/`master`), which is what the PR and CI judge, so a pull or a checkout of merged work counts for nothing. On a local default branch without a remote, since the session baseline. Also the per-repository review snapshots. |
| `house-check.pl` | called by check-on-stop | Line-level rules clippy cannot express (`// SAFETY:` spelling, TODO owners and trackers, branch links and dismissive words in comments, `# Cancel safety` in published libraries, anyhow in library code and library dependencies, `Box<dyn Error>` in public library signatures, ...). Runs only in opted-in repos. Each finding names its rust-style rule ID. `// house-check: allow(ID): reason` silences one line. |
| `baseline-lints.pl` | called by run-clippy | Merges `minimal-lints.toml` with the workspace's own lint tables into clippy flags (the workspace wins). |
| `review-gate.sh` | PreToolUse `Bash`, timeout 60 | Blocks `gh pr ready`, and `gh pr create` without `--draft`, while the pull request (merge-base with its base branch to its head commit) has 20 or more lines of Rust no `rust-style-reviewer` run has seen: per file, the lines that differ from the reviewer's snapshot, or all its changed lines without one. Run the reviewer, fix its blocker and major findings, push, retry. Reads the command with shell quoting (quoted text and heredoc bodies are not commands) and follows `cd`, `VAR=value`/`command`/`env` prefixes, `--base`, `--head`, and for `gh pr ready` the PR's head and base from `gh pr view` (a stacked PR's base is not main); a head commit not in the clone passes with a note. Skips drafts, `--undo`, `--web`, `--dry-run`, and `-R` naming another repository. Other commands exit before any git call. |
| `review-done.sh` | SubagentStop, timeout 120 | When the `rust-style-reviewer` finishes, snapshots every changed `.rs` file of the repos the session works in, once per repository (shared by its worktrees and later sessions). |
| `common.sh` | sourced | Shared helpers: input parsing, path resolution against the hook's `cwd`, per-agent state, edition and `max_width` lookup. |
| `tests/run.sh` | `check.sh`, and CI | Fixture and hook-input tests for all of the above. Run after any hook change. |
| `../guards/bash-guard.sh` | PreToolUse `Bash` | Blocks recursive `rm` and `find -delete` (use `trash`); `git clean -f`, `git reset --hard`, and a checkout or restore of the whole tree (stash first); any push that updates `main`/`master`: an explicit refspec, `--all`/`--mirror`, or a bare `git push`/`git push origin HEAD` while the current branch is `main`/`master`; and `gh pr merge --admin`. Quoted text (a commit message, a grep pattern) and heredoc bodies are data and never match, unless the command hands them to a shell (`bash -c`, `eval`, a pipe or heredoc into a shell). Tested in `rust/tests/run.sh`. |

Claude Code's session scratchpad (`/tmp/claude-<uid>/<project>/<session>/scratchpad/`) is
exempt: the style gate skips it, edits there are formatted but not recorded, and neither the
stop check nor a review snapshot counts them.

State is per agent, kept in `$TMPDIR/claude-rust-hooks/<session>.<agent>.*`:

- A Claude subagent has its own `agent_id`.
- A Grok subagent runs in its own session.

So a subagent must load the skill itself, and is checked on its own recorded edits only (edits made through Bash are attributed to the main agent).

Differences between the two tools that the scripts handle:

| | Claude Code | Grok |
|---|---|---|
| Edit tools | `Edit`, `Write`, `MultiEdit` | `search_replace`, `write` |
| Skill load | `Skill` tool, `tool_input.skill` | `read_file` of `SKILL.md`, `tool_input.target_file` |
| Subagent identity | `agent_id` | separate `session_id` |
| Stop loop guard | `stop_hook_active` | `stopHookActive` |
| Extra Stop | none | `reason: "shutdown"` at session end, skipped |

Grok also sends Claude's snake_case aliases (`tool_input`, `session_id`), so the scripts
read those first.

## Install on a new machine

1. Install the toolchain:

   ```sh
   rustup toolchain install stable nightly
   rustup component add --toolchain nightly miri   # nightly rustfmt is optional
   cargo install --locked prek cargo-deny
   brew install jq shellcheck shfmt   # trash ships with macOS 15+
   ```

   For JetBrains Air, also install Node (nvm), Claude Code, and Grok, and log in to both.

2. Let the file sync bring `$SETUP` to the machine, then run:

   ```sh
   bash "$SETUP/install.sh"
   ```

   Run it through `bash`: file sync can drop the executable bit, which `install.sh` then
   restores on itself, the hooks, and the status line. settings.json also calls every hook and
   the status line through `bash`, so a file that a later sync rewrites without the bit
   still runs.

   This creates every link in the inventory, writes `~/.claude/CLAUDE.md`, merges
   `settings.json`, and makes the hooks executable. Anything it replaces is moved to
   `~/.agent-setup-backup/<timestamp>/`. It is safe to re-run, and it reports missing tools.

3. Done by `install.sh`: it merges the `hooks` section of `$SETUP/claude/settings.json` into
   `~/.claude/settings.json`. That file is the only list of hook registrations; the table
   under Hooks says what each one does.

4. Start new sessions in both tools. The rules, skills, and hooks are read at startup.

## Local layer

This repo is public, so anything company-specific or machine-specific stays out of it but
still lives in `$SETUP`, synced to every machine like the rest. `.gitignore` lists it:

- `agents/AGENTS.local.md`: rules imported after `AGENTS.md`. `install.sh` adds it to
  `~/.claude/CLAUDE.md` and links it into `~/.grok/rules/` when it exists.
- `agents/SETUP.local.md`: setup notes for what the local layer adds (MCP servers, private
  tools).
- `install.local.sh`: extra install steps, run by `install.sh` when it exists.
- Company skills under `claude/skills/`, and skills other tools install there.

The local layer has no history: the sync carries its current state only. Keep anything
that holds a secret out of `$SETUP` entirely, and copy it to each machine over a secure
channel.

## JetBrains Air (ACP agents)

Air runs Grok (`grok agent --always-approve stdio`) and Claude Code as ACP agents.

- Claude Code runs through `@agentclientprotocol/claude-agent-acp`.
- `install.sh` installs that adapter globally at the version pinned in `setup_air`.
- The adapter uses the Claude Code login on the machine. It does not use JetBrains AI credits.

`$SETUP/air/acp.json` is the shared template:

- `@NODE@` and `@CLAUDE_ACP@` are placeholders for this machine's absolute `node` and
  adapter script paths. `install.sh` fills them in, because Air started from the Dock may
  not see nvm's PATH.
- After switching Node versions, re-run `install.sh`.
- Agents added locally in Air are kept.
- To share a new agent with every machine, add it to the template.
- To upgrade the adapter, change `acp_version` in `setup_air` and re-run `install.sh`.

Subscription login through ACP is allowed today, but Anthropic's terms on third-party use of
subscriptions have changed several times. If it stops being allowed, either:

- add `ANTHROPIC_API_KEY` to the agent's `env` (billed per use), or
- run `claude` in Air's terminal tab.

## Verify

- Air: restart it and confirm both Grok and Claude Code appear in the agent picker, and that
  Settings > Themes shows `Dark-Blue` with comments in orange.

- Claude: run `/memory` and confirm the `AGENTS.md` import. Run `/hooks` and confirm the
  seven Rust hooks (style-gate, style-loaded, fmt-on-edit, tests-ran, review-done,
  check-on-stop, and review-gate under PreToolUse `Bash`).
- Grok, from any directory: `grok inspect --json`.
  - `projectInstructions` lists `~/.grok/rules/AGENTS.md`.
  - `skills` has `rust-style`.
  - `agents` has `rust-style-reviewer`.
  - `configWarnings` has nothing new.
- Hooks and scripts: `bash "$SETUP/check.sh"` runs shellcheck, shfmt,
  Perl syntax, the 100-column check and the hook test suite (`--quick` skips the suite).
  Every step must say `ok`.
- End to end: in a scratch crate, ask either tool to add an `unsafe` function.
  - The first `.rs` edit is blocked until the agent loads `rust-style` and reads
    `topics/unsafe.md`.
  - The file comes back formatted.
  - A deliberate clippy violation, or `// Safety:` instead of `// SAFETY:`, blocks the stop
    once, with the finding.
  - Afterwards `$TMPDIR/claude-rust-hooks/<session>.*.edited` is empty.

## Applying the Rust templates to a repo

Per repo, and only with the owner's consent:

The steps are rule REPO-1 in `rust-style/topics/repo.md`. In short:

1. Opt in: `baseline = true` under `[workspace.metadata.house-check]` (or
   `[package.metadata.house-check]` in a single crate). This turns on house-check and the
   column check in the stop hook. A zero-dependency infrastructure crate also sets
   `low-level = true`: the edit hook then requires `topics/low-level.md`, and the crate merges
   `templates/low-level/` (lint additions, `clippy.toml` additions, `rustfmt.toml`, design
   doc skeleton). The low-level topic says what such a crate looks like.
2. Copy `clippy.toml`, `deny.toml`, and `.pre-commit-config.yaml` from
   `~/.claude/skills/rust-style/templates/`. There is no `rustfmt.toml`: default rustfmt.
3. Merge `Cargo.lints.toml` as `[workspace.lints]`, with `[lints] workspace = true` in each
   member; add the crate's custom cfgs to `unexpected_cfgs`.
4. Published libraries: mark them `publish = ["crates-io"]`, and put `lib.rs-header.rs` at the top of `lib.rs`.
5. Copy the workflows from `templates/ci/` that apply (each says when to delete it).
6. Run `prek install`.
7. Run `cargo clippy --all-targets -- -D warnings` once and show the fallout
   before committing.

## Version control

History lives in the repo https://github.com/GeorgiosDelkos/agent-setup; the file sync
only carries the working files between machines. The git directory is outside the synced
folder, at `~/.local/share/agent-setup.git`, because a `.git` directory synced between
machines can be corrupted by concurrent writes. `$SETUP/.git` is a one-line file,
`gitdir: <home>/.local/share/agent-setup.git`, so plain `git` works in the folder. The sync
does not carry that file, so `install.sh` (`setup_git`) writes it on each machine, clones the
git directory where there is none, and leaves the synced files as they are. A run that
stopped after the clone is finished by the next one.

- The synced folder is the deployed copy: it should match `origin/main`. An edit made in it
  is live on every machine at the next sync, before any review or test, which is how
  unreviewed changes piled up there before. So:
  1. Edit in a separate clone (`gh repo clone GeorgiosDelkos/agent-setup`), on a branch.
  2. `bash check.sh`, commit, open a draft PR; review, fix, `gh pr ready`, CI green, merge.
  3. On one machine: `git -C "$SETUP" pull --ff-only`, then `bash "$SETUP/install.sh"` when
     `settings.json` or a hook registration changed. The sync carries the files to the
     other machines.
- `install.sh` warns when the synced folder is off `main`, has changes not in git, or is
  behind the last fetched `origin/main`. Tools that install into `~/.claude/skills/` write
  into the synced folder too; such a skill shows up there as untracked until it is committed
  or removed.
- On every other machine the files arrive through the sync while its git directory still
  points at the old commit, and `git pull` refuses to overwrite them. Sync the git directory
  without touching the files: `git -C "$SETUP" fetch`, then
  `git -C "$SETUP" reset -q origin/main` (a mixed reset: index and
  HEAD only). `install.sh` says when this is needed.

## Maintenance

- `~/.config/agents/AGENTS.md` is the one rules file both tools read, on every machine,
  through the links. Change it like any other file here: in a clone, through a PR (Version
  control), never in place.
- After changing a hook or script, run `check.sh` and one end-to-end check in each tool.
- Heavy plugins stay off globally (`testing-handbook-skills`, `cloudflare`): each adds about
  20 skill descriptions to every session. Turn one on for a project in that project's
  `.claude/settings.json` (`"enabledPlugins": {"cloudflare@cloudflare": true}`).
- Grok re-syncs its bundled docs in `~/.grok/docs/` at startup. Edits there do not survive.
- When Grok or Claude changes hook input fields, capture real inputs with a temporary hook
  that appends stdin to a file. Read the field names from that capture, never from memory.
