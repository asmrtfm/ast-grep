---
name: add-discover-lang
description: Add discover framework support for a new programming language. Covers both ast-grep-supported languages (lang config + init) and unsupported languages (custom tree-sitter + Rust impl).
---

## When to use this

When the user says anything like:
- "add support for <lang>"
- "add <lang> to discover"
- "make discover work with <lang>"

## Prerequisites

- ast-grep and jq installed
- This repo checked out at `src/discover/`

## Process overview

There are two paths depending on whether ast-grep already supports the language.

### Step 0: Check ast-grep support

```bash
echo 'puts "hello"' > tmp/test_lang_check.<ext>
ast-grep run -l <lang> -p '$X' tmp/test_lang_check.<ext> --json
```

If it returns results (even empty `[]` without errors), the language is supported. If it errors with an unknown language message, it's unsupported.

---

## Path A: Language is supported by ast-grep

### Step 1: Discover the AST node kinds

Create a test file at `tmp/test_<lang>.<ext>` with representative code covering:
- Import/require statements (all forms the language uses)
- Module/namespace declarations
- Class definitions
- Method/function definitions (instance, class/static, top-level)
- Any other top-level constructs unique to the language

Then probe for the correct AST node kinds:

```bash
# Test import pattern extraction
ast-grep run -l <lang> -p 'require "$URI"' tmp/test_<lang>.<ext> --json | jq '.'

# Test each entity kind — try likely names until you find the ones that work
for kind in module class method function def method_definition class_definition; do
    echo "=== $kind ==="
    ast-grep run -l <lang> --kind "$kind" tmp/test_<lang>.<ext> --json 2>/dev/null \
        | jq '[.[] | {kind: .kind, text: (.text | split("\n")[0]), line: .range.start.line}]'
done
```

**Do NOT guess node kind names.** Tree-sitter grammars vary wildly between languages. `method` vs `method_definition` vs `method_def` vs `function_declaration` — only testing reveals the truth.

### Step 2: Create the lang config

Copy the template and fill it in based on what you discovered in step 1:

```bash
cp src/discover/lang-template.sh src/discover/langs/<lang>.sh
```

Required variables — see existing configs for examples:
- `LANG_ID` — ast-grep `-l` identifier
- `FILE_EXT` — with dot (`.rb`, `.py`, etc.)
- `FILE_EXCLUDE_GLOBS` — space-separated globs to skip (e.g. `"*.g.dart"`)
- `SRC_DIR_REL` — typical source directory (`lib`, `src`, `.`, etc.)
- `ENTRY_POINT_REL` — leave empty, set per-project
- `PACKAGE_NAME` — leave empty, set per-project

Required functions — **must use verified AST node kinds from step 1**:
- `resolve_import` — resolve an import specifier to repo-relative path(s)
- `ast_grep_imports` — extract import specifiers via ast-grep
- `ast_grep_entities` — extract top-level entities as JSON

Optional overrides (only if needed):
- `import_directives` — if the language has multiple linking keywords (e.g. Dart's `import export part`, Ruby's `require require_relative`)
- `ast_grep_directive_imports` — if different directives need different ast-grep patterns
- `inspect_sections` — if there are extra inspect sections beyond `imports entities`

Skill metadata — used by `discover init` to render SKILL.md:
- `SKILL_LANG_NAME`, `SKILL_IMPORT_VERB`, `SKILL_MOTIVATION`
- `SKILL_RESOLVE_EXAMPLE_*`, `SKILL_EXAMPLE_FILE`, `SKILL_EXAMPLE_SYMBOL`
- `SKILL_USAGE_EXAMPLE_1`, `SKILL_USAGE_EXAMPLE_2`

### Step 3: Add auto-detection to init.sh

Add a `detect_<lang>()` function to `src/discover/init.sh` that reads the project's manifest file to auto-detect entry point and package name. Pattern:

```bash
detect_<lang>() {
    local root="$1"
    # Read manifest (Gemfile, setup.py, Package.swift, shard.yml, etc.)
    # Set DETECTED_ENTRY and DETECTED_PACKAGE
}
```

See existing `detect_dart`, `detect_crystal`, `detect_ruby`, `detect_swift` for examples.

### Step 4: Write the test suite

Create a test file at `src/discover/tests/test-<lang>.sh` and a fixture at `src/discover/tests/fixtures/<lang>.<ext>`.

The fixture is the representative code from step 1 — **it is committed, not a tmp file.**

The test file sources `harness.sh` and uses `load_lang <lang>` to load the config, then asserts against the fixture:

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_lang <lang>
FIXTURE="$TESTS_DIR/fixtures/<lang>.<ext>"

echo "=== ast_grep_imports ==="
imports="$(ast_grep_imports "$FIXTURE")"
assert_contains "extracts <expected import>" "<value>" "$imports"
assert_line_count "<N> total imports" <N> "$imports"

echo "=== ast_grep_entities (names) ==="
entities="$(ast_grep_entities "$FIXTURE" names)"
assert_contains "finds <Entity>" '"name": "<Entity>"' "$entities"

echo "=== ast_grep_entities (signatures) ==="
sigs="$(ast_grep_entities "$FIXTURE" signatures)"
assert_contains "<description>" '"text": "<first line>"' "$sigs"

report
```

Available assertions: `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_exit`, `assert_json_eq`, `assert_line_count`.

See existing tests for the pattern. Every lang config must have a passing test suite before generating.

### Step 5: Run the test suite

```bash
bash src/discover/tests/run.sh <lang>     # single language
bash src/discover/tests/run.sh            # all languages
```

All tests must pass.

### Step 6: Generate the standalone script

```bash
cd src/discover
bash generate.sh langs/<lang>.sh --output examples/discover-<lang>.sh
```

### Step 7: Verify end-to-end with `discover init`

```bash
# From a project directory that uses <lang>
discover init <lang>
```

This produces three files in the project:
- `scripts/discover.sh` — standalone navigation script
- `scripts/test-discover.sh` — project-level smoke tests
- `.claude/skills/discover/SKILL.md` — Claude Code skill description

---

## Path B: Language is NOT supported by ast-grep

This requires adding tree-sitter support to the ast-grep Rust codebase. Past sessions have done this for Dart and Crystal.

### Architecture

The ast-grep language support lives in:
```
crates/language/src/
├── lib.rs          ← language registry, impl_lang! macro
├── parsers.rs      ← tree-sitter parser bindings
├── <lang>.rs       ← per-language customization (optional for simple langs)
└── ...
```

### Simple languages (no wrapping needed)

Most languages work with the `impl_lang!` macro in `lib.rs`:

```rust
impl_lang!(MyLang, language_mylang);
```

This generates a struct with default `Language` + `LanguageExt` implementations. It works when the tree-sitter grammar accepts patterns at the top level without wrapping.

### Complex languages (wrapping needed)

Some grammars only accept declarations at the top level. Expression patterns like `print($A)` get misinterpreted as function signatures or variable declarations. These languages need a custom `Language` + `LanguageExt` impl with a wrapping strategy.

Dart is the reference example: `crates/language/src/dart.rs`

The wrapping strategy:
1. Parse the pattern as-is
2. Check the parse tree for ERROR/MISSING nodes via a heuristic
3. If errors found, wrap in a function body: `void _() {\n<pattern>;\n}`
4. Try with and without trailing semicolon (expressions need `;`, statements like `if`/`for` don't)
5. Extract the inner node from the wrapper's block
6. If the inner node is `expression_statement`, unwrap one more level

Key challenge: distinguishing "the grammar misinterpreted this pattern" (needs wrapping) from "metavariable placeholders created benign ERROR nodes" (use direct parse). The heuristic checks ERROR nodes that are direct children of `source_file`.

### Handoff documents

These contain detailed context from past sessions implementing custom language support:
- `.claude/handoffs/20260602_ast-grep-dart-fix.md` — initial Dart impl, wrapping strategy design
- `.claude/handoffs/20260602_123053_ast-grep-dart-wrapping-heuristic.md` — heuristic refinement
- `.claude/20260605_ast-grep-field-declaration-pattern-matching.md` — class field matching (unresolved)

### Build and test

```bash
cargo test -p ast-grep-language -- <lang>    # run language-specific tests
cargo test                                    # full suite (~80 tests)
cargo build --release                         # binary at target/release/ast-grep
```

After the Rust side works, follow Path A steps 1-6 to create the discover lang config.

---

## Reference files

| File | Purpose |
|------|---------|
| `src/discover/lang-template.sh` | Blank lang config with full documentation |
| `src/discover/langs/dart.sh` | Complex: 3 directives, package imports, codegen exclusions |
| `src/discover/langs/crystal.sh` | Complex: glob requires, shard resolution, macros |
| `src/discover/langs/ruby.sh` | Medium: require + require_relative, singleton methods |
| `src/discover/langs/swift.sh` | Module-based imports, universal class_declaration kind |
| `src/discover/langs/bash.sh` | source/dot directives, three function forms |
| `src/discover/langs/typescript.sh` | import/export, extensionless resolution, namespace/const/let |
| `src/discover/core.sh` | Shared engine — do not modify for language-specific logic |
| `src/discover/init.sh` | Init command — add `detect_<lang>()` here |
| `src/discover/generate.sh` | Concatenates lang config + core into standalone script |
| `src/discover/tests/harness.sh` | Shared test helpers (assert_eq, assert_contains, etc.) |
| `src/discover/tests/run.sh` | Test runner — runs all or selected language tests |
| `src/discover/tests/test-<lang>.sh` | Per-language test suites |
| `src/discover/tests/fixtures/<lang>.<ext>` | Committed test fixtures with representative code |
| `src/discover/SKILL.md.template` | Template for project-level SKILL.md |
| `src/discover/test-discover.sh.template` | Template for project-level smoke tests |
| `crates/language/src/dart.rs` | Reference custom Language impl (Rust, for Path B) |

## Rules

- **Never guess AST node kinds.** Test every kind against real code before using it.
- **Fixtures are committed, not tmp files.** Create `tests/fixtures/<lang>.<ext>` with representative code.
- **Every lang config must have a passing test suite** in `tests/test-<lang>.sh` before generating.
- **Run the full test suite** (`bash src/discover/tests/run.sh`) before committing.
- **Always add `detect_<lang>()`** to init.sh so `discover init` works without flags.
- **Always generate the standalone script** in `examples/discover-<lang>.sh`.
