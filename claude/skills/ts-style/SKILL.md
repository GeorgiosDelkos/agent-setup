---
name: ts-style
description: Use when writing, reviewing, or setting up TypeScript or JavaScript (Node) in any repo. House tooling (oxlint, oxfmt, vitest, tsc), strict tsconfig flags, ESM-only and pinning rules. Load before the first TS/JS edit in a repo.
---

# TypeScript / Node house style

Global rules (design principles, code style, testing, git) live in
`~/.config/agents/AGENTS.md`. This skill adds only TS/Node tooling and idioms. A repo's own
config wins.

## Idioms

- Plain functions over plain data: `type` aliases and discriminated unions for state,
  `readonly` where data does not change. Classes only for real encapsulated state, never
  inheritance chains or DI containers.
- `Map` and `Set` for keyed lookup, never an array scan.
- An options object for optional settings; never a positional `boolean`.
- No decorators, `any`, or type assertions to silence the compiler: fix the type instead.

## Tooling

| purpose | tool | replaces |
|---|---|---|
| lint | `oxlint` with `typescript`, `import`, `unicorn` plugins | eslint |
| format | `oxfmt` | prettier |
| types | `tsc --noEmit` | |
| tests | `vitest`, colocated `*.test.ts` | jest |

- Runtime: the current Node Active LTS. Look it up, never assume.
- ESM only: `"type": "module"`.
- Applications: exact versions in `package.json` (no `^` or `~`) and a committed lockfile.
  Libraries: ranges everywhere, the oldest compatible version only where CI proves it
  (AGENTS.md, Dependencies); the lockfile pins for development.

## Testing

The global rules (AGENTS.md, Testing) apply; this is how in TS.

- `vitest run` (not watch mode) in scripts and CI; tests colocated as `*.test.ts`.
- Each test builds its own state; no order dependence, no shared mutable module state.
- Mock only boundaries (network, clock, file system) with `vi.mock` on the module that does
  the I/O, and `vi.useFakeTimers()` for time. Never mock the module under test.
- `fast-check` for parsers, serialization and algorithms: round trips, and comparison
  against a simple model.
- Coverage (`@vitest/coverage-v8`) shows untested code; it is a floor, not the goal. Before
  calling a change tested, run StrykerJS (`@stryker-mutator/vitest-runner`) with `--mutate` set to
  the changed files, and kill or explain each surviving mutant.
- CRAP scores (CC² × (1 − coverage)³ + CC per function) with crap-typescript, after the last
  edit, over the source files the branch changed:

  ```bash
  npx vitest run --coverage.enabled --coverage.reporter=json --coverage.include='src/**'
  npx --before=2026-10-25 -y @barney-media/crap-typescript@2.0.0 --threshold 8 --agent \
    $(git diff --name-only --diff-filter=d "$(git merge-base origin/main HEAD)" -- '*.ts' '*.tsx')
  ```

  A function the change adds or edits scores 8 or less; one already above 8 is debt: lower
  it when the change makes that cheap, otherwise name it in the PR. Coverage here is the
  lower of statement and branch coverage, so at full coverage the limit is CC 8, the house
  complexity limit. Lower a score with tests over the untested branches, or by splitting the
  function. CRAP says where tests are missing; Stryker says whether they check anything.
  - `--agent` lists only the functions above the threshold, and the exit code is 2 when
    any function in the named files is, existing debt included: judge each row.
  - It reuses `coverage/coverage-final.json` when the file exists, so rerun coverage after
    the last edit. `--coverage.include` names the sources, so a file no test imports reads
    0% instead of N/A, which never fails.
  - Not `--changed`, which reads only `git status`. Test files are skipped by the tool.
    `--diff-filter=d` drops deleted files, which the tool cannot open. When the branch
    changed no `.ts` or `.tsx` file, skip the run: with no paths it scores the whole tree.
  - Run with `npx` at an exact version, and `--before` holds its dependencies to that date;
    move the two together. No package is added to the project.

  The owner chose 8 over the 30 used for Rust and Python, 2026-11-05; the tool recommends 8
  for hard gates and defaults to 6. On hippius-console's tested `.ts` code, 15% of 5443
  functions were above 8 and 2.4% above 30.

## tsconfig.json strictness

Enable all of these:

```jsonc
"strict": true,
"noUncheckedIndexedAccess": true,
"exactOptionalPropertyTypes": true,
"noImplicitOverride": true,
"noPropertyAccessFromIndexSignature": true,
"verbatimModuleSyntax": true,
"isolatedModules": true
```

## New repo setup

Propose (never apply to an existing repo without asking) the tsconfig above and prek
hooks running `oxlint`, `oxfmt --check`, `tsc --noEmit`. `prek install`, then
`prek auto-update --cooldown-days 7`.
