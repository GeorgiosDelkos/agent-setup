I'll review the diff for gate deadlocks, accidental bypasses, Grok misfires, Stop-hook loops, and install/token issues. Reading the diff and the files it changes.The diff is in. Next I’ll check the hook helpers, settings wiring, and install path those scripts depend on.The gate can deadlock a session that cannot recall, and `install.sh` can abort or skip the Grok migration it exists to do. The Stop hook does not loop on its own: it writes the asked marker before `exit 2`, and a continuation with `stop_hook_active` / `stopHookActive` passes.

## High

**1. One agent's registration closes the gate for both.** `claude/hooks/memory/recall-gate.sh:75-80`

Fail-open runs only when Claude's top-level `~/.claude.json` entry and Grok's `~/.grok/config.toml` header are both absent. The HTTP probe runs only when Claude's entry starts with `http`. These sessions stay denied:

- Claude has a URL or a stdio `command`, and Grok has no server. `install.sh:358-360` takes that branch when `mcp-token` is missing (`skip`, then `return 0`). Grok has no `recall` tool, and every git edit stays denied.
- Only Grok is registered, including a dead URL. The probe is skipped. `claude/hooks/memory/tests/run.sh:126-128` registers `http://127.0.0.1:1/mcp` and expects a deny, so the suite locks the deadlock in.
- Claude's entry is a stdio `command`. `recall-gate.sh:11-12` and `:78` count that as up and never connect. A crashed or unauthorized stdio server cannot be recalled, and the deny text tells the model to wait for `HIPPIUS_MEM_HOOKS_BYPASS=1`, which the hook process will not inherit from a shell the agent starts.

`curl` has no `-f` and no `--noproxy '*'`. Any HTTP status, including 401 or 500, counts as up, and `http_proxy` can make loopback look up or down for the wrong reason. A failed `recall` is `PostToolUseFailure` (`recall-seen.sh:5`), so it writes no stamp. The same deny repeats.

Probe the server for the agent that is editing, and fail open with the stderr line when that server is missing or the call cannot succeed. A stdio entry that cannot be probed belongs on the fail-open path.

**2. The deny text names Claude's tool.** `recall-gate.sh:82-86`

Grok's catalog key is `hippius-mem__recall`. The reason tells the model to call `mcp__hippius-mem__recall`. A call under that name fails to dispatch, `recall-seen.sh:13-16` does not match, and the gate stays shut. `tests/run.sh:104-105` requires that string for a Grok edit.

`recall-seen.sh` also matches only the event's tool name. A `use_tool` call whose argument is `hippius-mem__recall` matches neither the `settings.json:128` matcher nor the `case`. The tests feed the bare catalog name only.

Name `hippius-mem__recall` in the Grok reason, and stamp a `use_tool` whose `tool_input.tool_name` is `hippius-mem__recall` or `hippius-mem__remember`.

**3. `setup_memory` aborts install on the migration it is there to perform.** `install.sh:354-369`

`install.sh:9` is `set -euo pipefail`, and the `grok mcp add` status is unchecked. Add is not an update: a user-scope add of a name a project `.grok/config.toml` already defines is refused, and a project table replaces the user table entirely, so a session can keep a stdio `hippius-mem` after this prints `ok`. The stdio entry this function is supposed to replace is the name `add` will see again on the next run.

`grep -qxF "url = \"$url\""` (`install.sh:354`) is any exact line in the file. Another server's `url` line, or a hippius-mem table with that URL and no Authorization header, prints `ok` and leaves Grok on stdio. A rotated `mcp-token` is never read again.

`install.sh:344-347` returns before the Grok step when Claude has a stdio `command` and no `url`. The gate still treats that `command` as a live server (`recall-gate.sh:61-62`).

Remove the old server, or write the table only when the name is absent, and check the status. Treat "ok" as hippius-mem's own `url` plus a usable auth. Keep going when `grok mcp add` fails.

## Medium

**4. The bearer token is placed on the command line and then into a backup.** `install.sh:367-368`

`--header "Authorization: Bearer $(cat "$token_file")"` puts the secret in `grok`'s argv. stdout is discarded; stderr is not, so a refusal can echo it. Grok stores header values verbatim in `~/.grok/config.toml`. The next run whose `url` line does not match copies that file, token included, to `~/.agent-setup-backup/` (`install.sh:362-365`). The success line claims that backup even when `config.toml` did not exist (`install.sh:369`).

Point Grok at `bearer_token_file` (Grok reads it per request and trims whitespace) so the token stays in `mcp-token`.

**5. Shell writes never hit the gate.** `claude/settings.json:82`

The matcher is `Edit|Write|MultiEdit|search_replace|write|hashline_edit`. A heredoc, `apply` via Bash, or Claude `NotebookEdit` is outside it. `AGENTS.md:59-60` says the hook denies file edits in a git repo. One `recall` of any query also opens every repo for 30 minutes (`recall-gate.sh:49-54`); the rule's "when the task shifts" is not what the stamp records.

**6. The remember marker can be spent before anyone remembers.** `remember-checkpoint.sh:17-34`

`check-on-stop.sh` is the Stop hook ahead of this one (`settings.json:107-123`). The asked file is touched before `exit 2`, and it is session-scoped. If this hook runs in the same Stop that clippy already blocked, the question is consumed while the agent is still fixing that other block. The next Stop passes. `is_subagent` (`remember-checkpoint.sh:17`) skips Claude events that carry `agent_id` and Grok events that carry `subagentType`, and `SubagentStop` is not wired, so a Grok subagent session that edited is never asked. `AGENTS.md:64` says that session is asked once.

Set the marker only on a Stop that is otherwise allowed to end, and say in `AGENTS.md` that subagents are not asked.

## Low

**7. `remember-checkpoint.sh:22` will fail `shfmt -d -i 2`.** The continuation `-f "$asked"` starts at column 0. `check.sh` runs that check on every tracked shell script.

**8. `tests/run.sh:60-62` treats any stdout that contains `"permissionDecision"` as exit 2.** An allow decision would pass a deny test. There are no tests for `use_tool`, a 401 from a live port, `HIPPIUS_MEM_HOOKS_BYPASS` on the Stop hook, a subagent Stop, a relative path with no `cwd`, or `install.sh`.

## Wording (`agents/AGENTS.md:57-70`)

- The hook sentence says a recall in the last 30 minutes is enough. The previous sentence also requires another recall when the task shifts, and a `get` of the relevant notes. The stamp is only "a `recall` succeeded."
- "The gate lets edits through when the daemon does not answer" covers the curl failure and the neither-registered case. It does not cover stdio, Grok-only config, or an HTTP error from a process that is listening.
- "A Stop hook asks once per session that edited files" leaves out subagents, the bypass switch, and edits that never went through the edit tools.
- Subagents are told to recall and remember. Claude subagents share the parent's stamp (`recall-gate.sh:18-19`), so the child's recall is not what opens the gate. Grok subagents recall for themselves and are not asked to remember.
