---
description: Plan, implement, test, and open a reviewed PR for a GitHub issue, then comment on the issue.
argument-hint: <issue-number>
---

# Fix issue #$ARGUMENTS

With no issue number given, stop and ask for one.

Read issue #$ARGUMENTS with `gh issue view $ARGUMENTS --comments`: the problem,
acceptance criteria, linked PRs, and the discussion. Follow linked issues, referenced PRs,
and external docs until you understand it.

Run the steps below in order without stopping between them. The rules in
`~/.config/agents/AGENTS.md` still hold: stop and ask when the issue is ambiguous, or when
the fix needs an interface, data model, or architecture decision the issue does not settle.

## 1. Branch and plan

Branch prefix from the issue type: `fix/` for bugs, `feat/` for features, `refactor/` for
refactors, `docs/` for documentation (`fix/` when unclear). Create the branch
`{prefix}issue-$ARGUMENTS` from the up-to-date default branch before changing anything.

Write the plan to `plan-issue-$ARGUMENTS.md` in the repo root:

- the issue's requirements, as what must be true when it is fixed;
- every file to create or change, with `file:line` references to the code involved;
- the approach and its key design decisions;
- risks and open questions.

## 2. Test first

Write the tests the acceptance criteria call for, and run them to see each fail for the
reason the issue describes. A test that passes before the fix tests nothing.

## 3. Implement

Implement the plan. Keep the change to what the issue needs: no speculative features.

## 4. Verify

Run the project's quality pipeline: build, the full test suite (iterate until green), then
lint, format, and type checks. The commands are in the repo's `AGENTS.md`, `CLAUDE.md`,
`Makefile`, `package.json`, or CI workflows.

## 5. Commit and push

- Delete `plan-issue-$ARGUMENTS.md` with `trash`: a working file, not part of the change.
- Commit with an imperative subject of at most 72 characters and a body that says why,
  ending with `Refs #$ARGUMENTS`.
- Push the branch.

## 6. Open a draft PR

`gh pr create --draft`, so CI waits for the review's fixes, with:

- a title under 70 characters;
- a description that maps the changes to the issue's requirements;
- "Closes #$ARGUMENTS" (or "Refs #$ARGUMENTS" if it does not close it fully).

## 7. Review, fix, and mark ready

Run the `review-pr` command (through the Skill tool) on the new PR number: it reviews
with fresh-context agents, posts the review on the PR, fixes the findings, pushes, and
marks the PR ready.

## 8. Comment on the issue

Comment on issue #$ARGUMENTS with a link to the PR, what was implemented (one to three
points), and the key design decisions.
