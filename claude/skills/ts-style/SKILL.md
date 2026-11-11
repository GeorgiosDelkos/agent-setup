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
  edit, over the `.ts` and `.tsx` files the branch changed, committed or not, from the
  directory that holds the Vitest config:

  ```bash
  (
    set -euo pipefail
    base="$(git merge-base origin/main HEAD)"
    files=()
    while IFS= read -r file; do files+=("$file"); done < <(
      {
        git diff --name-only --relative --diff-filter=d "$base" -- '*.ts' '*.tsx'
        git ls-files --others --exclude-standard -- '*.ts' '*.tsx'
      } | sort -u
    )
    if ((${#files[@]} == 0)); then
      echo "no changed .ts or .tsx files"
      exit 0
    fi
    includes=()
    for file in "${files[@]}"; do includes+=("--coverage.include=$file"); done
    npx --no vitest run --coverage.enabled --coverage.reporter=json \
      --coverage.reportsDirectory=coverage "${includes[@]}"
    npx --before=2026-10-25 -y @barney-media/crap-typescript@2.0.0 --threshold 8 \
      --agent --failures-only=false "${files[@]}"
  )
  ```

  A function the change adds scores 8 or less, and one it edits scores no higher than
  before; one already above 8 is debt: lower it when the change makes that cheap, otherwise
  name it in the PR. When unsure whether an edit raised a score, run the same commands in a
  temporary worktree of the merge base
  (`git worktree add --detach <dir> "$(git merge-base origin/main HEAD)"`). Coverage here is the
  lower of statement and branch coverage, so at full coverage the limit is CC 8, the house
  complexity limit. Lower a score with tests over the untested branches, or by splitting the
  function. CRAP says where tests are missing; Stryker says whether they check anything.
  - Every row of the named files is listed (`--failures-only=false`). A `failed` row is
    above the threshold and a `skipped` row has no coverage (N/A): both count against a
    function the change touches. The exit code is 2 when any row is above the threshold,
    existing debt included: judge each row.
  - Coverage is measured over exactly the changed files (`--coverage.include`), so a file
    no test imports reads 0% instead of N/A. It is written to `coverage/`, where the tool
    looks first, whatever the repo's own `reportsDirectory`; a stale report there would be
    reused, so the commands always run together.
  - The file list: `git diff` holds committed and staged work, `git ls-files --others` the
    new files not yet added, `--diff-filter=d` drops deletions the tool cannot open, and
    `--relative` makes paths match the current directory. Not the tool's `--changed`,
    which reads only `git status`. Test files are skipped by the tool.
  - `npx --no vitest` uses the project's own Vitest and fails instead of downloading one.
    In a Jest repo, replace that line with `npx --no jest --coverage
    --coverageReporters=json` plus one `--collectCoverageFrom=<file>` per changed file.
  - The tool runs with `npx` at an exact version, and `--before` holds its dependencies to
    that date; move the two together. No package is added to the project.

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
