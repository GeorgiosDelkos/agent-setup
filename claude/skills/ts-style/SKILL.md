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
