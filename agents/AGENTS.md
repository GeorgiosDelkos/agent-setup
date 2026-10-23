# Global agent rules

Shared by Claude Code and Grok. Defaults for every repo; the user's turn
instruction and the repo's own AGENTS.md / CLAUDE.md win (deeper wins). Keep this
file short: repo specifics go in the repo, language tooling goes in skills. How this setup
is wired (skills, hooks, Claude and Grok): `~/.config/agents/SETUP.md`.

## Design principles

The baseline for every change. Agents read, write, and maintain this code, often with only
a slice of it in context, so it must be simple, efficient, and obvious. These outrank every
rule and skill below, except correctness and safety.

1. **First principles.** Start from the problem, not from an existing pattern or an
   ecosystem habit. State in a sentence what must be true when done: inputs, outputs,
   constraints. Each part of the solution traces back to that sentence; drop what does not.
2. **Simplest design that works.** Fewest moving parts: types, layers, files, flags,
   dependencies. Plain functions and plain data first. A trait, generic, macro, builder,
   callback, or extra layer must serve a second real use that exists today. If a design
   takes a paragraph to justify, look for a simpler one. Deleting code is a valid fix.
   Of two designs that work, pick the one that is easier to delete.
3. **Data structures decide the code.** Pick them from the access pattern: what is
   created, looked up, iterated, mutated, and shared, how often, and at what size. Know
   the cost of the hot operations (complexity, allocations, copies, locks) and choose the
   structure that makes the common path cheap and obvious. Make invalid states
   unrepresentable. Tune past that only with a measurement.
4. **APIs designed from the call site.** Write the calling code first. The common case is
   one obvious call with no setup; misuse fails to compile or fails loudly. Few
   parameters, no boolean flags, names and types that say what they mean.
5. **Readable with partial context.** A function's signature and body show what it does:
   no hidden global state, implicit registration, or action at a distance. Explicit
   control flow over clever code. Shallow call chains, related code kept together. One
   unique, greppable name per concept; never build identifiers from strings.

## How I work

- Plan non-trivial or ambiguous work before implementing: the problem, the data
  structures, the API at the call site, then the code. "Just fix it" skips the plan.
- No speculative features, flags, or config. Abstract on the third repetition, not before.
- Replace, don't deprecate: delete the old path entirely, no shims. Flag dead code.
  Exception: a published semver library deprecates (`#[deprecated(since, note)]` or the
  ecosystem's equivalent) and removes the old path at the next major version.
- Finish the job: handle the edges you can see, clean up what you touched, flag adjacent
  breakage. Do not invent new scope.
- Agent-native: anything a user can do, an agent can do. Prefer file-based state.
- Act on anything reversible and state the assumption. Ask before committing to
  interfaces, data models, architecture, or destructive / external writes.
- Missing tool, MCP, or network: say so. Never fake results.

## Code style

- Small, single-purpose functions: <=100 lines, complexity <=8, <=5 params, 100 cols.
  Split by concept, not to hit a number: a single-use helper that only hides a straight
  line of steps makes code harder to follow.
- Readable, not horizontally dense. Blank lines between distinct thoughts, not every statement.
- Absolute imports. Language skills list the exceptions (e.g. Rust `use super::*` in tests).
- Comments say why (intent, invariants, tradeoffs), never what. Document public APIs and
  unsafe/FFI boundaries.
- Fail fast with actionable errors (operation, input, fix). Never swallow errors.
- Zero warnings from any tool. If one truly can't be fixed, ignore it inline with a reason.
- Prefer structure-aware tools (ast-grep, LSP, compiler) over regex for code changes.
- Subagents writing code get the design principles and these style rules in their prompt.
  Parallel ones each work in their own worktree.

## Dependencies

- Prefer stdlib or existing code. Justify every new dependency.
- Before adding or using one: check maintenance and advisories, read current docs, look up
  the current version. Never from memory.
- Commit the lockfile in applications, and in Rust libraries too (CI runs `--locked`).
  Applications add exact specifiers only where the ecosystem expects them (Cargo does not:
  caret requirements plus the lockfile). Libraries declare the oldest compatible version
  only where CI proves it (a minimal-versions job); otherwise the current minor. Never an
  exact pin.

## Testing

- Behavior changes need tests. Test behavior, not implementation.
- Cover edges and errors. Mock only boundaries (slow, external, non-deterministic).
- Break the code once to confirm the test fails.
- Property tests for parsers, serialization, and algorithms.
- Docs, formatting, and pure renames need no new tests.

## Git

- Small commits, one logical change. Imperative subject <=72 chars; body explains why.
- Format, lint, and run relevant tests before committing.
- Work on a feature branch and open a PR. Before a PR, review it adversarially.
- Every PR I open gets its review posted ON the PR (`gh pr comment`: findings, severity,
  file:line) and every finding fixed and pushed, with a "Fixes" comment mapping finding to
  commit. A review only in my report, or a bot comment, does not count. A PR is ready to
  merge only when review, fixes, and green CI are all on GitHub. Subagents follow this too.
- No Co-Authored-By or AI attribution. Use the user's git identity.
- Delete with `trash`, never `rm -rf`.

## Communication

- Terse. Lead with the answer or recommendation, no preamble or recap.
- No emojis in output, code, comments, or commits.
- Plain language in PRs and commits: no "critical", "robust", "comprehensive", "elegant".
- Reviews: the design principles first (could it be simpler, are the data structures right,
  does the call site read well), then correctness, quality, tests, performance. Per issue:
  file:line, options with tradeoffs, a recommendation, then ask before fixing.

## Languages

Before the first edit in a repo, load the matching skill (`~/.claude/skills/`). It holds the
tooling, config templates, and idioms, so they are not repeated here.

- Rust: `rust-style`. Python: `python-style`. TS/Node: `ts-style`. Shell: `bash-style`.
  GitHub Actions: `gh-actions-style`.

## Rust

The bar: code that would pass review in Jon Gjengset's crates, Tokio, or Cranelift. Order of
authority, all under the design principles above:

1. The house decisions in `rust-style`.
2. Where those three codebases agree, together with *Rust for Rustaceans*.
3. Canonical's *Rust best practices*, only where 1 and 2 are silent.

- Load `rust-style` first, and the topic files it names (unsafe, concurrency, async,
  library API, testing, repo setup, the low-level profile) before editing those areas; the
  edit hook blocks until you do. Before non-trivial work, load the matching `rfr-*` chapter skill.
- Use ownership and the type system as safety rails: make invalid states unrepresentable.
- Formatting is not optional: default `cargo fmt`, no `rustfmt.toml` style options (a
  low-level crate may keep the stable-options template, `rust-style` LLV-9). Clean
  `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings` (with the repo's
  feature set) before any commit.
- Before calling Rust work done, review it against the `rust-style` rules: use the
  `rust-style-reviewer` agent where it exists, otherwise self-review. Fix every blocker and
  major finding, and a minor one only when it makes the code smaller or clearer: findings on
  your own uncommitted work are pre-approved, unlike the ask-first rule for
  reviews in Communication. Cite rules by ID (`ERR-5`) in reviews and fix commits.

## Team memory (team-memory)

When the team-memory MCP server is available:

- Recall before the first edit on a task, and again when the task shifts.
- Remember only durable decisions, gotchas, conventions, and references. One fact per note,
  keyword-rich summary. Nothing derivable from code or git.
- Subagent prompts include: recall before changes, remember durable findings.
