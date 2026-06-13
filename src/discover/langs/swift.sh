#!/usr/bin/env bash
# Language config: Swift
#
# Swift's import system is module-based, not file-based. `import Foundation`
# pulls in an entire compiled module, not a source file. This means:
#   - resolve_import returns nothing for external modules (Foundation, UIKit, etc.)
#   - For intra-project files, Swift doesn't require explicit imports between
#     files in the same module/target — all files in a target see each other.
#   - live-files is less meaningful: in a single-target project, all files are live.
#     For multi-target projects (SPM), live-files BFS starts from the target's
#     directory and includes all .swift files in it.
#
# The most useful subcommands for Swift are: inspect, definition, usages, importers.

LANG_ID="swift"
FILE_EXT=".swift"
FILE_EXCLUDE_GLOBS=""
SRC_DIR_REL="Sources"
ENTRY_POINT_REL=""  # Swift packages don't have a single entry point; set per-project
PACKAGE_NAME=""

# ─────────────────────────────────────────────────────────
# Skill metadata — used by `discover init` to fill SKILL.md.template
# ─────────────────────────────────────────────────────────
SKILL_LANG_NAME="Swift"
SKILL_IMPORT_VERB="import"
SKILL_MOTIVATION="Swift's module-based imports mean all files in a target see each other — grep can't tell you which target owns a file or whether an \`import MyModule\` resolves locally. discover.sh maps the module graph and extracts entities structurally."
SKILL_RESOLVE_EXAMPLE_1="MyModule"
SKILL_RESOLVE_RESULT_1="Sources/MyModule/MyModule.swift"
SKILL_RESOLVE_EXAMPLE_2="NetworkKit"
SKILL_RESOLVE_FROM_2="Sources/App/AppDelegate.swift"
SKILL_RESOLVE_RESULT_2="Sources/NetworkKit/Client.swift"
SKILL_EXAMPLE_FILE="Sources/App/AppDelegate.swift"
SKILL_EXAMPLE_SYMBOL="AppDelegate"
SKILL_USAGE_EXAMPLE_1='URLSession.shared.$METHOD($$$ARGS)'
SKILL_USAGE_EXAMPLE_2='guard let $VAR = $EXPR else { $$$BODY }'

# ─────────────────────────────────────────────────────────
# Swift import resolution
#
# `import Foundation`   → external module, unresolvable
# `import MyModule`     → local module if Sources/MyModule/ exists
# `@testable import X`  → same as above
#
# Within a module/target, all .swift files see each other — no per-file imports.
# ─────────────────────────────────────────────────────────
resolve_import() {
    local specifier="$1" from_file="$2"

    # Strip @testable prefix
    specifier="${specifier#@testable }"

    # Check if it's a local module (directory under Sources/)
    local module_dir="$REPO_ROOT/Sources/$specifier"
    if [ -d "$module_dir" ]; then
        # Return all .swift files in that module
        find "$module_dir" -name "*.swift" -print0 2>/dev/null | sort -z | while IFS= read -r -d '' f; do
            realpath --relative-to="$REPO_ROOT" "$f" 2>/dev/null
        done
        return
    fi

    # External module — no resolution
}

# ─────────────────────────────────────────────────────────
# ast-grep pattern for Swift imports
# ─────────────────────────────────────────────────────────
ast_grep_imports() {
    local file="$1"
    ast-grep run -l swift -p 'import $MODULE' "$file" --json 2>/dev/null \
        | jq -r '.[].metaVariables.single.MODULE.text' 2>/dev/null
}

# ─────────────────────────────────────────────────────────
# Entity extraction
# ─────────────────────────────────────────────────────────
ast_grep_entities() {
    local file="$1" depth="${2:-names}"

    # Swift AST node kinds and their keyword prefixes
    local kinds="class_declaration struct_declaration enum_declaration protocol_declaration actor_declaration"
    local keyword_map="class_declaration:class struct_declaration:struct enum_declaration:enum protocol_declaration:protocol actor_declaration:actor"

    local all_json="[]"

    for kind in $kinds; do
        local keyword=""
        for pair in $keyword_map; do
            [ "${pair%%:*}" = "$kind" ] && { keyword="${pair#*:}"; break; }
        done

        local raw
        raw="$(ast-grep run -l swift --kind "$kind" "$file" --json 2>/dev/null)"
        [ -n "$raw" ] && [ "$raw" != "[]" ] || continue

        local extracted
        extracted="$(echo "$raw" | jq --arg kw "$keyword" --arg depth "$depth" '
            [.[] | {
                kind: $kw,
                name: (.text | split("\n")[0] | capture("(?:^|\\s)" + $kw + "\\s+(?<n>\\w+)") | .n // "?"),
                line: (.range.start.line + 1),
                text: (
                    if $depth == "full" then .text
                    elif $depth == "signatures" then (.text | split("\n")[0])
                    else null
                    end
                )
            }]
        ' 2>/dev/null)"

        [ -n "$extracted" ] && [ "$extracted" != "[]" ] || continue
        all_json="$(echo "$all_json" "$extracted" | jq -s '.[0] + .[1]')"
    done

    # Top-level functions
    local fn_raw
    fn_raw="$(ast-grep run -l swift --kind function_declaration "$file" --json 2>/dev/null)"
    if [ -n "$fn_raw" ] && [ "$fn_raw" != "[]" ]; then
        local fn_extracted
        fn_extracted="$(echo "$fn_raw" | jq --arg depth "$depth" '
            [.[] | select(.range.start.column == 0) | {
                kind: "func",
                name: (.text | split("\n")[0] | capture("func\\s+(?<n>\\w+)") | .n // "?"),
                line: (.range.start.line + 1),
                text: (
                    if $depth == "full" then .text
                    elif $depth == "signatures" then (.text | split("\n")[0])
                    else null
                    end
                )
            }]
        ' 2>/dev/null)"

        if [ -n "$fn_extracted" ] && [ "$fn_extracted" != "[]" ]; then
            all_json="$(echo "$all_json" "$fn_extracted" | jq -s '.[0] + .[1]')"
        fi
    fi

    # Extensions
    local ext_raw
    ext_raw="$(ast-grep run -l swift --kind extension_declaration "$file" --json 2>/dev/null)"
    if [ -n "$ext_raw" ] && [ "$ext_raw" != "[]" ]; then
        local ext_extracted
        ext_extracted="$(echo "$ext_raw" | jq --arg depth "$depth" '
            [.[] | {
                kind: "extension",
                name: (.text | split("\n")[0] | capture("extension\\s+(?<n>\\w+)") | .n // "?"),
                line: (.range.start.line + 1),
                text: (
                    if $depth == "full" then .text
                    elif $depth == "signatures" then (.text | split("\n")[0])
                    else null
                    end
                )
            }]
        ' 2>/dev/null)"

        if [ -n "$ext_extracted" ] && [ "$ext_extracted" != "[]" ]; then
            all_json="$(echo "$all_json" "$ext_extracted" | jq -s '.[0] + .[1]')"
        fi
    fi

    echo "$all_json" | jq 'sort_by(.line) | if .[0].text == null then [.[] | del(.text)] else . end'
}
