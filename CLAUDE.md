# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is a fork of [ast-grep](https://github.com/ast-grep/ast-grep) — a Rust CLI for structural code search/lint/rewrite via tree-sitter. The fork exists to add language support that upstream lacks (Dart, Crystal) and to house the **discover** framework, which generates per-project structural navigation tooling for any supported language.

The end goal is always production software in the malsi-app org. Everything here serves that.

## Commands

```bash
# Rust (ast-grep core)
cargo build --release                   # binary → target/release/ast-grep
cargo test                              # ~94 tests, ~48s — never cancel
cargo test -p ast-grep-language -- dart  # single language
cargo fmt --all -- --check
cargo clippy --all-targets --all-features --workspace --release --locked -- -D clippy::all

# discover framework tests
bash src/discover/tests/run.sh           # all 6 languages, 172 assertions
bash src/discover/tests/run.sh dart bash # specific languages

# generate a standalone discover.sh
bash src/discover/generate.sh src/discover/langs/<lang>.sh --output examples/discover-<lang>.sh

# install discover into a project (from project root)
discover init <lang> [--entry <file>] [--package <name>]
```

Set timeouts to 120s+ for cargo commands. They are slow and must not be cancelled.

## Adding a language to ast-grep (Rust)

All language support is in `crates/language/src/`. Three macro patterns:

- **`impl_lang!`** — `$VAR` is valid in the grammar (Bash, Java, JS, JSON, Lua, Scala, TS, TSX, YAML)
- **`impl_lang_expando!`** — `$` is not a valid identifier char; substitutes an expando char (C, C++, C#, CSS, Elixir, Go, Haskell, HCL, Kotlin, Nix, PHP, Python, Ruby, Rust, Swift)
- **Custom impl** — grammar rejects expression-level patterns at top level, requiring a wrapping strategy. See `dart.rs` and `crystal.rs`. Handoff docs in `.claude/handoffs/` cover the wrapping heuristic design.

New languages also need: `SupportLang` enum entry, `all_langs()`, alias, and file-type mapping — all in `lib.rs`.

## discover framework

`src/discover/` generates standalone `discover.sh` scripts that give any project structural navigation (resolve imports, inspect entities, find definitions, trace reachability, search usages). It is the complete pipeline: lang config → tests → standalone script + project-level test + Claude skill.

**Three layers:**
- `langs/<lang>.sh` — 6 variables + 3 functions encoding the language's import system, AST node kinds, and entity extraction
- `core.sh` — shared engine (BFS reachability, caching, definition lookup, importers, usages, CLI dispatch)
- `generate.sh` — concatenates lang config + core into a self-contained script

**`discover init <lang>`** produces three files in a project:
- `scripts/discover.sh` — the standalone script
- `scripts/test-discover.sh` — project-level smoke tests
- `.claude/skills/discover/SKILL.md` — teaches Claude how to use discover in that project

**Test suite** (`src/discover/tests/`):
- `harness.sh` — assert helpers (`assert_eq`, `assert_contains`, `assert_not_contains`, `assert_exit`, `assert_json_eq`, `assert_line_count`)
- `tests/fixtures/<lang>.<ext>` — committed representative source files
- `tests/test-<lang>.sh` — per-language regression tests against fixtures
- `tests/run.sh` — runner for all or selected languages

**Current languages:** bash, crystal, dart, ruby, swift, typescript

The skill at `.claude/skills/discover/SKILL.md` documents the full procedure for adding a new language, including the test requirements. Use it.

## Context7 for language research

When adding a new language to ast-grep or discover, use Context7 to verify language semantics before implementing. Do not rely on training data or copy another language's import resolution logic without confirming it applies.

```bash
npx ctx7@latest library "<lang>" "import module resolution"
npx ctx7@latest docs "<library-id>" "how does import resolution work"
```

Verify via Context7 before writing `resolve_import`:
- How the language resolves import paths (relative? absolute? package-qualified?)
- Whether multiple linking directives exist (e.g. `import` vs `export` vs `part`)
- Extension handling in import specifiers (required, optional, forbidden)
- Package manager conventions (manifest file name, dependency resolution)

This also applies when reviewing existing lang configs — if a previous session's `resolve_import` looks suspiciously similar to another language's, check the actual semantics before trusting it.
