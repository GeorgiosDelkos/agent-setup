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

Everything lives in the synced folder `~/Synced-Storage/AgentSetup/` (`$SETUP` below).
The usual locations are symlinks into it, created by `$SETUP/install.sh`, so an edit on one
machine reaches every machine.

| Path on the machine | Links to | Purpose |
|---|---|---|
| `~/.config/agents/` | `$SETUP/agents/` | `AGENTS.md` (canonical rules; edit only this) and this document. |
| `~/.claude/skills/` | `$SETUP/claude/skills/` | `rust-style` (+ `templates/`), `rfr-*`, `rust-*`, `{python,ts,bash,gh-actions}-style`, others. |
| `~/.claude/agents/` | `$SETUP/claude/agents/` | `rust-style-reviewer.md`. |
| `~/.claude/hooks/` | `$SETUP/claude/hooks/` | `rust/*.sh` enforcement hooks (see below). |
| `~/.claude/commands/` | `$SETUP/claude/commands/` | Slash commands. |
| `~/.claude/statusline.sh` | `$SETUP/claude/statusline.sh` | Status line. |
| `~/.grok/rules/AGENTS.md` | `$SETUP/agents/AGENTS.md` | Grok's global rules. |
| `~/.grok/agents/rust-style-reviewer.md` | `$SETUP/claude/agents/…` | The reviewer, for Grok. |
| `~/.claude/CLAUDE.md` | (file) | One line, `@~/.config/agents/AGENTS.md`. |
| `~/.claude/settings.json` | (file, merged) | Hooks, permissions, plugins. Grok reads its hooks too. |
| `~/Library/Application Support/JetBrains/Air/acp.json` | (file, merged from `$SETUP/air/acp.json`) | Grok and Claude Code as ACP agents in JetBrains Air. |
| `~/Library/Application Support/JetBrains/Air/review/review-prompt.md` | `$SETUP/air/review-prompt.md` | Air's code-review task list, aligned with the review order in `AGENTS.md`. Air sends it as the user turn, so it outranks `AGENTS.md`. If Air replaces the link with a plain file, re-run `install.sh`. |
| `~/Library/Application Support/JetBrains/Air/themes/` | `$SETUP/air/themes/` | `Dark-Blue.json`: Air's Dark theme with loud comments (code comments orange, doc comments green, TODOs yellow), per the Comments section of `AGENTS.md`. Edit it in Air with Edit Color Theme…; the save lands in the synced folder. |
| `~/Library/Application Support/JetBrains/Air/settings.json` | (file, merged from `$SETUP/air/settings.json`) | Selects the `Dark-Blue` theme. Other Air settings stay local. |

`settings.json` is the one file that is not linked: Claude Code rewrites it in place, which
would replace a symlink. `$SETUP/claude/settings.json` is the shared copy; `install.sh`
merges it in (shared keys win, local-only keys stay). After changing settings you want on
every machine, copy `~/.claude/settings.json` to `$SETUP/claude/settings.json`.

Grok scans `~/.claude/skills/` and `~/.claude/settings.json` by default
(`[compat.claude] skills/hooks = true`), so skills and hooks exist once and serve both
tools.

## Permissions

Every agent runs with full bypass permissions, on every machine:

- `$SETUP/claude/settings.json` sets `permissions.defaultMode = "bypassPermissions"` and
  `skipDangerousModePermissionPrompt`. Claude Code reads it directly, the Air adapter reads it
  through the SDK, and Grok reads `defaultMode` from `~/.claude/settings.json` too.
- `$SETUP/air/acp.json` starts Grok with `--always-approve`, so Air sessions match.

Hooks still run under bypass: `bash-guard.sh` keeps blocking recursive `rm`, `find -delete`
and pushes that update `main`/`master`. These are guardrails, not a sandbox: the deny rules
for `Read(~/.ssh/**)` and the like cover the Read tool only, and any Bash command can still
read those files. Only Claude Code's sandbox settings would close that.

## Hooks

| Script | Event and matcher | Effect |
|---|---|---|
| `style-gate.sh` | PreToolUse `Edit\|Write\|MultiEdit\|search_replace\|write\|hashline_edit` | Blocks an agent's first `.rs` edit until it has loaded `rust-style`, and any edit whose new text touches a topic (unsafe, concurrency, async, library API, testing, repo setup) until it has read `rust-style/topics/<topic>.md`. The deny reason (JSON `permissionDecisionReason`, read by both tools) lists exactly what to load. Without jq it fails open with a message rather than block every edit. |
| `style-loaded.sh` | PostToolUse `Skill\|Read\|read_file\|Bash` | Marks `rust-style` as loaded (Claude's Skill tool, reading its `SKILL.md` as Grok does, or a whole-file `cat` of it in Bash), and marks each topic file read the same ways. Partial reads (`head`, `sed -n`, `cat | head`) do not count. |
| `fmt-on-edit.sh` | PostToolUse, edit tools | Formats the edited `.rs` file right away through stdin (so declared child modules are never touched; the repo's rustfmt.toml is honoured), and records it; also records edited `Cargo.toml`. A syntax error is fed back to the agent. |
| `check-on-stop.sh` | Stop and SubagentStop, timeout 600 | Main agent: every repo this session changed (recorded edits plus git changes since the session baseline, so Bash edits and commits count). Subagent: only the paths it recorded; skipped if none. Runs clippy over the changed packages and their workspace dependents with the repo's own lint tables and `clippy.toml` plus `minimal-lints.toml` (default features unless `[workspace.metadata.house-check]` says otherwise, `--cap-lints warn --keep-going`). It never injects the house template, so it checks what `cargo clippy` and CI check. In a repo that opted in (`baseline = true` in that table) it then runs `house-check.pl` and the `max_width` column check, and reports an opted-in repo that has not committed a lint table. Compiler errors block; lint and house-check findings only on changed lines. Blocks once per changed state; internal failures exit 1 and never block. |
| `run-clippy.sh` | called by check-on-stop | Clippy scoped to the changed packages plus their workspace dependents (whole workspace for a root-manifest change), per-package runs for members with their own `[lints]`, read as JSON. |
| `house-metadata.pl` | called by the hooks | Reads `[workspace.metadata.house-check]`: the `baseline` opt-in and the feature set. Also decides whether a crate is published (opt-in: `publish = ["crates-io"]`/`true`, or inherited through `publish.workspace = true`). |
| `minimal-lints.toml` | read by run-clippy | The only lints the hook adds to a repo's own config, in every repo: leftover `dbg!`/`todo!`/`unimplemented!`, undocumented `unsafe`. |
| `session-baseline.sh` | UserPromptSubmit, timeout 30 | Records each repo's HEAD and state at the session's first prompt (else at the first edit or stop), the baseline for every change count. |
| `changes.sh` | sourced by the stop-time hooks | The changed set and changed line ranges against the session baseline (merge-base fallback after a rebase or reset), and per-repo review state. |
| `house-check.pl` | called by check-on-stop | Line-level rules clippy cannot express (`// SAFETY:` spelling, TODO owners and trackers, branch links and dismissive words in comments, `# Cancel safety` in published libraries, anyhow in library code and library dependencies, `Box<dyn Error>` in public library signatures, ...). Runs only in opted-in repos. Each finding names its rust-style rule ID. `// house-check: allow(ID): reason` silences one line. |
| `baseline-lints.pl` | called by run-clippy | Merges `minimal-lints.toml` with the workspace's own lint tables into clippy flags (the workspace wins). |
| `review-gate.sh` | Stop (main agent only), timeout 120 | When this session's Rust changes in a repo reach 20 lines (the smaller of: since the session baseline, since the last review), blocks once per state of the changed files (a later turn with no new Rust change passes): run `rust-style-reviewer`, fix its blocker and major findings. Each file counts once, under its deepest root; recorded files deleted outside git do not count. |
| `review-done.sh` | SubagentStop, matcher `rust-style-reviewer`, timeout 120 | When the reviewer finishes, snapshots the reviewed files per repo for review-gate. |
| `common.sh` | sourced | Shared helpers: input parsing, path resolution against the hook's `cwd`, per-agent state, edition and `max_width` lookup. |
| `tests/run.sh` | manual | Fixture and hook-input tests for all of the above. Run after any hook change. |
| `../guards/bash-guard.sh` | PreToolUse `Bash` | Blocks recursive `rm` and `find -delete` (use `trash`), and any push that updates `main`/`master`: an explicit refspec, `--all`/`--mirror`, or a bare `git push`/`git push origin HEAD` while the current branch is `main`/`master`. Tested in `rust/tests/run.sh`. |

Claude Code's session scratchpad (`/tmp/claude-<uid>/<project>/<session>/scratchpad/`) is
exempt: the style gate skips it, edits there are formatted but not recorded, and no stop
check or review gate counts them.

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

2. Let Sync sync `~/Synced-Storage/AgentSetup/`, then run:

   ```sh
   bash ~/Synced-Storage/AgentSetup/install.sh
   ```

   Run it through `bash`: Sync sync drops the executable bit, which `install.sh` then
   restores on itself, the hooks, and the status line. settings.json also calls every hook and
   the status line through `bash`, so a file that a later sync rewrites without the bit
   still runs.

   This creates every link in the inventory, writes `~/.claude/CLAUDE.md`, merges
   `settings.json`, and makes the hooks executable. Anything it replaces is moved to
   `~/.agent-setup-backup/<timestamp>/`. It is safe to re-run, and it reports missing tools.

3. Done by `install.sh`; listed for reference. The Rust hook registration it merges into
   `~/.claude/settings.json` (the `Bash` guard is registered alongside, under `PreToolUse`):

   ```json
   {
     "hooks": {
       "PostToolUse": [
         {
           "matcher": "Skill|Read|read_file|Bash",
           "hooks": [
             {
               "type": "command",
               "command": "bash ~/.claude/hooks/rust/style-loaded.sh"
             }
           ]
         },
         {
           "matcher": "Edit|Write|MultiEdit|search_replace|write|hashline_edit",
           "hooks": [
             {
               "type": "command",
               "command": "bash ~/.claude/hooks/rust/fmt-on-edit.sh",
               "timeout": 60
             }
           ]
         }
       ],
       "PreToolUse": [
         {
           "matcher": "Edit|Write|MultiEdit|search_replace|write|hashline_edit",
           "hooks": [
             {
               "type": "command",
               "command": "bash ~/.claude/hooks/rust/style-gate.sh"
             }
           ]
         }
       ],
       "Stop": [
         {
           "matcher": "",
           "hooks": [
             {
               "type": "command",
               "command": "bash ~/.claude/hooks/rust/check-on-stop.sh",
               "timeout": 600
             },
             {
               "type": "command",
               "command": "bash ~/.claude/hooks/rust/review-gate.sh",
               "timeout": 120
             }
           ]
         }
       ],
       "SubagentStop": [
         {
           "matcher": "",
           "hooks": [
             {
               "type": "command",
               "command": "bash ~/.claude/hooks/rust/check-on-stop.sh",
               "timeout": 600
             }
           ]
         },
         {
           "matcher": "rust-style-reviewer",
           "hooks": [
             {
               "type": "command",
               "command": "bash ~/.claude/hooks/rust/review-done.sh",
               "timeout": 120
             }
           ]
         }
       ],
       "UserPromptSubmit": [
         {
           "matcher": "",
           "hooks": [
             {
               "type": "command",
               "command": "bash ~/.claude/hooks/rust/session-baseline.sh",
               "timeout": 30
             }
           ]
         }
       ]
     }
   }
   ```

4. Start new sessions in both tools. The rules, skills, and hooks are read at startup.

## Team memory (team-memory)

The memories live in Sync buckets, so every machine with the same config sees the same
notes. Only the server binary and its config live on the machine. `install.sh` registers the
server with Claude and Grok (user scope) once both exist, and leaves existing registrations
alone.

1. Build the binary from a checkout of the team-memory repository, with semantic recall:

   ```sh
   cargo install --locked --path team-memory --features dashboard,embeddings,http-mcp
   ```

   Without `embeddings`, recall falls back to keyword matching.

2. Copy `~/.config/team-memory/team-memory.toml` from an existing machine over a secure
   channel (for example `scp`), then `chmod 600` it. It holds bucket credentials and team
   encryption keys, so it never goes in this synced folder.

3. Re-run `install.sh`. It reports `added team-memory` for each tool. Check with
   `claude mcp get team-memory` (expect `Connected`) and `grok mcp list`.

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
  six Rust hooks (style-gate, style-loaded, fmt-on-edit, review-done, check-on-stop,
  review-gate).
- Grok, from any directory: `grok inspect --json`.
  - `projectInstructions` lists `~/.grok/rules/AGENTS.md`.
  - `skills` has `rust-style`.
  - `agents` has `rust-style-reviewer`.
  - `configWarnings` has nothing new.
- Hooks and scripts: `bash ~/Synced-Storage/AgentSetup/check.sh` runs shellcheck, shfmt,
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
   doc skeleton). Reference: `example/reference-crate`.
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

History lives in the private repo https://github.com/GeorgiosDelkos/agent-setup; Sync
only carries the working files between machines. The git directory is outside the synced
folder, at `~/.local/share/agent-setup.git`, because a `.git` directory synced between
machines can be corrupted by concurrent writes. `AgentSetup/.git` is a one-line file,
`gitdir: ../../.local/share/agent-setup.git`, so plain `git` works in the folder.
`install.sh` clones the git directory on a machine that has none (`setup_git`) and leaves
the synced files as they are.

- Change the setup on one machine at a time: `git pull`, edit, `bash check.sh`, commit, push.
  Changes go through a branch and a PR like any repo (the Bash guard blocks pushes to
  `main`).
- On a machine where the synced files arrived before its git directory saw the commits,
  `git fetch && git status` shows them as matching once `git pull` runs; the content is
  already there.

## Maintenance

- Edit the rules only in `~/.config/agents/AGENTS.md` (the synced copy). Both tools, on every
  machine, follow the links. Sync sync carries the changes, so let an edit sync before
  editing the same file on another machine.
- After changing a hook or script, run `check.sh` and one end-to-end check in each tool.
- Heavy plugins stay off globally (`testing-handbook-skills`, `cloudflare`): each adds about
  20 skill descriptions to every session. Turn one on for a project in that project's
  `.claude/settings.json` (`"enabledPlugins": {"cloudflare@cloudflare": true}`).
- Grok re-syncs its bundled docs in `~/.grok/docs/` at startup. Edits there do not survive.
- When Grok or Claude changes hook input fields, capture real inputs with a temporary hook
  that appends stdin to a file. Read the field names from that capture, never from memory.
