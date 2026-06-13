#!/usr/bin/env bash
# test-bash.sh — discover framework tests for Bash lang config
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"
load_lang bash

FIXTURE="$TESTS_DIR/fixtures/bash.sh"

# ─────────────────────────────────────────────────────────
echo "=== ast_grep_imports ==="

imports="$(ast_grep_imports "$FIXTURE")"

assert_contains "extracts source unquoted" "./lib/utils.sh" "$imports"
assert_contains "extracts source quoted" "./lib/helpers.sh" "$imports"
assert_contains "extracts dot-source unquoted" "./lib/constants.sh" "$imports"
assert_contains "extracts dot-source quoted" "./lib/config.sh" "$imports"
assert_line_count "4 total imports" 4 "$imports"

# ─────────────────────────────────────────────────────────
echo "=== ast_grep_directive_imports (source) ==="

sources="$(ast_grep_directive_imports "$FIXTURE" source)"

assert_contains "source captures unquoted" "./lib/utils.sh" "$sources"
assert_contains "source captures quoted" "./lib/helpers.sh" "$sources"
assert_line_count "2 source directives" 2 "$sources"

# ─────────────────────────────────────────────────────────
echo "=== ast_grep_directive_imports (dot) ==="

dots="$(ast_grep_directive_imports "$FIXTURE" dot)"

assert_contains "dot captures unquoted" "./lib/constants.sh" "$dots"
assert_contains "dot captures quoted" "./lib/config.sh" "$dots"
assert_line_count "2 dot directives" 2 "$dots"

# ─────────────────────────────────────────────────────────
echo "=== ast_grep_entities (names) ==="

entities="$(ast_grep_entities "$FIXTURE" names)"

assert_contains "finds posix-style function" '"name": "my_posix_func"' "$entities"
assert_contains "finds keyword-style function" '"name": "my_keyword_func"' "$entities"
assert_contains "finds both-style function" '"name": "my_both_func"' "$entities"
assert_contains "finds process_file function" '"name": "process_file"' "$entities"

entity_count="$(echo "$entities" | jq 'length')"
assert_eq "4 total entities" "4" "$entity_count"

# ─────────────────────────────────────────────────────────
echo "=== ast_grep_entities (signatures) ==="

sigs="$(ast_grep_entities "$FIXTURE" signatures)"

assert_contains "posix style signature" \
    '"text": "my_posix_func() {"' "$sigs"
assert_contains "keyword style signature" \
    '"text": "function my_keyword_func {"' "$sigs"
assert_contains "both style signature" \
    '"text": "function my_both_func() {"' "$sigs"
assert_contains "process_file signature" \
    '"text": "process_file() {"' "$sigs"

# ─────────────────────────────────────────────────────────
echo "=== all entities are functions ==="

non_func="$(echo "$entities" | jq '[.[] | select(.kind != "function")] | length')"
assert_eq "all entities are kind function" "0" "$non_func"

report
