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

## Supply chain

- Applications: commit `uv.lock` and pin exact versions (`==`). Libraries: declare the oldest
  compatible version (`>=`), and let the lockfile pin for development.
- `pip-audit` before deploying.

## New repo setup

Propose (never apply to an existing repo without asking): `pyproject.toml` with ruff + ty
config, `uv.lock`, and prek hooks running `ruff check`, `ruff format --check`, `ty check`.
`prek install`, then `prek auto-update --cooldown-days 7`.
