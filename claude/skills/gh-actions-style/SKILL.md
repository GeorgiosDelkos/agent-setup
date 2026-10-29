---
name: gh-actions-style
description: Use when writing, reviewing, or editing GitHub Actions workflows (.github/workflows/*.yml) or Dependabot config. SHA pinning, credential hygiene, actionlint and zizmor checks.
---

# GitHub Actions house style

Global rules live in `~/.config/agents/AGENTS.md`. This skill adds only CI rules.

- Pin every action to a full commit SHA with a version comment:
  `actions/checkout@<full-sha>  # vX.Y.Z`. Look up the current release and its SHA,
  never from memory.
- `actions/checkout` uses `persist-credentials: false`.
- Least-privilege `permissions:`, set at the workflow level and widened per job only
  when needed.
- Never interpolate untrusted input (`${{ github.event.* }}`) directly into `run:`.
  Pass it through `env:`.
- Before committing: `actionlint .github/workflows/` and `zizmor .github/workflows/`.
  Fix everything.
- Security gates (e.g. `cargo audit`) block. Never `continue-on-error`.
- Draft PRs get no CI: PRs open as drafts for their review (`AGENTS.md`, Git), and a run
  before the review's fixes is wasted. `pull_request` lists
  `types: [opened, synchronize, reopened, ready_for_review]`, and every job it starts carries
  `if: ${{ !github.event.pull_request.draft }}` (false on push and schedule, so those run).
  A skipped job reports success, which is safe for a required check only when the job has no
  `needs:`: its check run is replaced as soon as the ready run queues. A required job behind
  `needs:` (an aggregator) would show that stale green until its needs finish, so in such a
  workflow fail the first job on a draft instead of skipping. Templates: `rust-style/templates/ci/`.
- Dependabot: a 7-day cooldown and grouped updates for every ecosystem, including
  `github-actions`.
