---
name: python-style
description: Use when writing, reviewing, or setting up Python in any repo. House tooling (uv, ruff, ty, pytest), pyproject strictness, and supply-chain rules. Load before the first Python edit in a repo.
---

# Python house style

Global rules (design principles, code style, testing, git) live in
`~/.config/agents/AGENTS.md`. This skill adds only Python tooling and idioms. A repo's own
config wins.

## Idioms

- Plain functions over plain data: `@dataclass(frozen=True, slots=True)` for records,
  `Enum` or `Literal` for states. No class hierarchies, mixins, or manager classes without
  a second real implementation.
- `dict` and `set` for keyed lookup, never a list scan; generators for single-pass
  streams.
- No metaclasses, `__getattr__` tricks, monkey-patching, or decorator registries: behavior
  must be visible where it is called.
- Keyword-only arguments (`*`) for options; never a positional `bool`.

## Tooling

| purpose | tool | replaces |
|---|---|---|
| runtime, venv, deps | `uv` (`uv venv`, `uv add`, `uv run`) | pip, poetry, pyenv |
| lint + format | `ruff check --fix` and `ruff format` | black, flake8, pylint, isort |
| types | `ty check` | mypy, pyright |
| tests | `uv run pytest -q` | unittest runners |
| property tests | `hypothesis` | |

- Runtime: the latest stable CPython that the deps support. Look it up, never assume.
- Standalone scripts: PEP 723 inline metadata, run with `uv run script.py`.
- Configure `ty` strictness under `[tool.ty.rules]` in `pyproject.toml`.
- Type-annotate every public function. Docstrings on public APIs, in the format the repo
  already uses.

## Testing

The global rules (AGENTS.md, Testing) apply; this is how in Python.

- pytest, tests under `tests/`, `uv run pytest -q`. Strict settings in `pyproject.toml`, so
  a typo in a marker or a new warning fails instead of passing quietly:

  ```toml
  [tool.pytest.ini_options]
  addopts = ["-ra", "--strict-markers", "--strict-config"]
  xfail_strict = true
  filterwarnings = ["error"]
  ```

- Each test builds its own state with fixtures (`tmp_path`, `monkeypatch`); none depends on
  another having run first.
- Mock only boundaries (network, clock, subprocess, the file system when `tmp_path` will not
  do), at the call into them. Never mock the module under test.
- `hypothesis` for parsers, serialization and algorithms: round trips, and comparison
  against a simple model.
- Coverage (`pytest-cov` with `--cov-branch`) shows untested code; it is a floor, not the
  goal. Before calling a change tested, run `mutmut`, restricted to the changed modules, and kill or
  explain each surviving mutant.
- CRAP scores (CC² × (1 − coverage)³ + CC per function) with Uncle Bob's crapper, after the
  last edit, so the coverage is current:

  ```bash
  uv run pytest --cov=<import_name> --cov-branch \
    --cov-report=lcov:target/coverage/python/lcov.info
  uvx --exclude-newer 2026-10-25 \
    --from git+https://github.com/unclebob/crapper@6fd92c4c9bcc56efb64a2f8743d5a2993bcfd42d \
    crapper --use-existing-coverage <source_dir>...
  ```

  `<import_name>` is what the code imports (`my_app`, not the distribution name `my-app`).
  `<source_dir>` is each directory that holds it, as a path (`src/my_app` in a src layout):
  a name that is not an existing path is a substring filter over every source file in the
  repo, any language, and one that matches nothing prints `No source files to analyze.`
  and exits 0. That message is a failed run, not a pass.

  A function the change adds scores 30 or less, and one it edits scores no higher than
  before; one already above 30 is debt: lower it when the change makes that cheap, otherwise
  name it in the PR. When unsure whether an edit raised a score, run the same commands in a
  temporary worktree of the merge base (`git worktree add --detach <dir> "$(git merge-base
  origin/main HEAD)"`), then remove it (`git worktree remove <dir>`). Lower a score with
  tests over the untested branches, or by splitting the function. CRAP says where tests are
  missing; mutmut says whether they check anything.
  - Always `--use-existing-coverage`: without it crapper deletes the report, reruns the
    tests, and installs pytest and coverage into the project's interpreter when missing.
    It reads `target/coverage/**/lcov.info`, hence the report path.
  - No `--changed`, which reads only `git status` and misses work already committed on the
    branch, and no `--threshold`, which exits 2 on the worst score in every file read,
    existing debt included.
  - Every run writes `.metrics/crap.edn` (for Uncle Bob's uml-viewer), and the coverage
    command writes `target/coverage/`: add both to `.gitignore`.
  - crapper has no releases, so the pin is a commit, and `--exclude-newer` holds its
    tree-sitter dependencies to that date; move the two together.

  The owner chose crapper over crap4py (no dependencies, but unmaintained since June 2026),
  2026-11-05. On hippius-hub it put 10 of 270 functions above 30, all untested CLI code.

## Supply chain

- Applications: commit `uv.lock`, which pins every version. `pyproject.toml` keeps the lower
  bounds `uv add` writes (`>=`); no `==` there (AGENTS.md, Dependencies). Libraries:
  `>=` the oldest compatible version only where CI proves it (a minimal-versions job), else
  the current minor; the lockfile pins for development.
- `pip-audit` before deploying.

## New repo setup

Propose (never apply to an existing repo without asking): `pyproject.toml` with ruff + ty
config, `uv.lock`, and prek hooks running `ruff check`, `ruff format --check`, `ty check`.
`prek install`, then `prek auto-update --cooldown-days 7`.
