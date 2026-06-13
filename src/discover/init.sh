#!/usr/bin/env bash
# init.sh — generate a complete discover skill package in the nearest .claude dir.
#
# Called by the `discover` CLI:
#   discover init <lang> [--entry <file>] [--package <name>] [--src-dir <dir>]
#
# Produces:
#   <nearest-.claude>/skills/discover/discover.sh   — standalone script
#   <nearest-.claude>/skills/discover/SKILL.md      — Claude Code skill description
#
# Auto-detects project-specific settings (entry point, package name) from
# manifest files when flags are not explicitly provided.

DISCOVER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────
# Find script install directory (scripts/ or bin/ in project root)
# ─────────────────────────────────────────────────────────
find_script_dir() {
    local root="$1"
    if [ -d "$root/scripts" ]; then
        echo "$root/scripts"
    elif [ -d "$root/bin" ]; then
        echo "$root/bin"
    else
        mkdir -p "$root/scripts"
        echo "$root/scripts"
    fi
}

# ─────────────────────────────────────────────────────────
# Auto-detect project settings from manifest files
# ─────────────────────────────────────────────────────────
detect_dart() {
    local root="$1"
    local pubspec="$root/pubspec.yaml"
    if [ -f "$pubspec" ]; then
        DETECTED_PACKAGE="$(grep -oP '^name:\s*\K\S+' "$pubspec" 2>/dev/null || true)"
    fi
    if [ -f "$root/lib/main.dart" ]; then
        DETECTED_ENTRY="lib/main.dart"
    fi
}

detect_crystal() {
    local root="$1"
    local shard="$root/shard.yml"
    if [ -f "$shard" ]; then
        local name
        name="$(grep -oP '^name:\s*\K\S+' "$shard" 2>/dev/null || true)"
        if [ -n "$name" ] && [ -f "$root/src/$name.cr" ]; then
            DETECTED_ENTRY="src/$name.cr"
            DETECTED_PACKAGE="$name"
        fi
    fi
}

detect_ruby() {
    local root="$1"
    # Try gemspec first
    local gemspec
    gemspec="$(find "$root" -maxdepth 1 -name "*.gemspec" -print -quit 2>/dev/null)"
    if [ -n "$gemspec" ]; then
        local name
        name="$(basename "$gemspec" .gemspec)"
        DETECTED_PACKAGE="$name"
        if [ -f "$root/lib/$name.rb" ]; then
            DETECTED_ENTRY="lib/$name.rb"
        fi
    fi
    # Fall back to Gemfile/directory name
    if [ -z "$DETECTED_ENTRY" ]; then
        local dir_name
        dir_name="$(basename "$root")"
        if [ -f "$root/lib/$dir_name.rb" ]; then
            DETECTED_ENTRY="lib/$dir_name.rb"
        fi
    fi
}

detect_typescript() {
    local root="$1"
    local pkg="$root/package.json"
    if [ -f "$pkg" ]; then
        DETECTED_PACKAGE="$(jq -r '.name // empty' "$pkg" 2>/dev/null || true)"
        # Look for common entry points
        local main
        main="$(jq -r '.main // empty' "$pkg" 2>/dev/null || true)"
        if [ -n "$main" ]; then
            # Convert .js entry to .ts equivalent
            local ts_main="${main%.js}.ts"
            [ -f "$root/$ts_main" ] && DETECTED_ENTRY="$ts_main"
        fi
        if [ -z "$DETECTED_ENTRY" ]; then
            for candidate in src/index.ts src/main.ts index.ts; do
                if [ -f "$root/$candidate" ]; then
                    DETECTED_ENTRY="$candidate"
                    break
                fi
            done
        fi
    fi
}

detect_bash() {
    local root="$1"
    # Look for a main script or common entry points
    for candidate in main.sh app.sh run.sh entrypoint.sh; do
        if [ -f "$root/$candidate" ]; then
            DETECTED_ENTRY="$candidate"
            break
        fi
    done
    # Also check bin/ and scripts/
    if [ -z "$DETECTED_ENTRY" ]; then
        for dir in bin scripts; do
            if [ -d "$root/$dir" ]; then
                local main_script
                main_script="$(find "$root/$dir" -maxdepth 1 -name "*.sh" -print -quit 2>/dev/null)"
                if [ -n "$main_script" ]; then
                    DETECTED_ENTRY="$(realpath --relative-to="$root" "$main_script" 2>/dev/null)"
                    break
                fi
            fi
        done
    fi
    # Package name from directory name
    DETECTED_PACKAGE="$(basename "$root")"
}

detect_swift() {
    local root="$1"
    local package_swift="$root/Package.swift"
    if [ -f "$package_swift" ]; then
        # Look for an executable target with a main.swift
        local target
        for dir in "$root"/Sources/*/; do
            [ -d "$dir" ] || continue
            if [ -f "$dir/main.swift" ] || [ -f "$dir/App.swift" ]; then
                target="$(basename "$dir")"
                DETECTED_ENTRY="Sources/$target/main.swift"
                [ -f "$dir/main.swift" ] || DETECTED_ENTRY="Sources/$target/App.swift"
                DETECTED_PACKAGE="$target"
                break
            fi
        done
    fi
}

# ─────────────────────────────────────────────────────────
# Build inspect flags string from inspect_sections()
# ─────────────────────────────────────────────────────────
build_inspect_flags() {
    local flags=""
    for section in $(inspect_sections); do
        flags+=" --${section}"
    done
    echo "${flags# }"
}

# ─────────────────────────────────────────────────────────
# Build Context7 lookup commands from CTX7_LIBRARIES
# ─────────────────────────────────────────────────────────
build_ctx7_commands() {
    if [ -z "${CTX7_LIBRARIES:-}" ]; then
        echo "# No Context7 libraries configured for this language."
        return
    fi
    local cmds=""
    for lib in $CTX7_LIBRARIES; do
        cmds+="npx ctx7@latest library \"${lib}\" \"<your question>\""$'\n'
        cmds+="npx ctx7@latest docs \"<library-id>\" \"<your question>\""$'\n'
    done
    printf '%s' "${cmds%$'\n'}"
}

# ─────────────────────────────────────────────────────────
# Render SKILL.md from template + lang metadata
# ─────────────────────────────────────────────────────────
render_skill_md() {
    local template="$1" script_path="$2" test_script_path="$3"
    local inspect_flags
    inspect_flags="$(build_inspect_flags)"
    local import_section
    import_section="$(inspect_sections | awk '{print $1}')"
    local ctx7_commands
    ctx7_commands="$(build_ctx7_commands)"

    # Simple substitutions via sed
    local result
    result="$(sed \
        -e "s|{{LANG_NAME}}|${SKILL_LANG_NAME}|g" \
        -e "s|{{IMPORT_VERB}}|${SKILL_IMPORT_VERB}|g" \
        -e "s|{{MOTIVATION}}|${SKILL_MOTIVATION}|g" \
        -e "s|{{SCRIPT_PATH}}|${script_path}|g" \
        -e "s|{{TEST_SCRIPT_PATH}}|${test_script_path}|g" \
        -e "s|{{INSPECT_FLAGS}}|${inspect_flags}|g" \
        -e "s|{{IMPORT_SECTION}}|${import_section}|g" \
        -e "s|{{EXAMPLE_FILE}}|${SKILL_EXAMPLE_FILE}|g" \
        -e "s|{{EXAMPLE_SYMBOL}}|${SKILL_EXAMPLE_SYMBOL}|g" \
        -e "s|{{RESOLVE_EXAMPLE_1}}|${SKILL_RESOLVE_EXAMPLE_1}|g" \
        -e "s|{{RESOLVE_RESULT_1}}|${SKILL_RESOLVE_RESULT_1}|g" \
        -e "s|{{RESOLVE_EXAMPLE_2}}|${SKILL_RESOLVE_EXAMPLE_2}|g" \
        -e "s|{{RESOLVE_FROM_2}}|${SKILL_RESOLVE_FROM_2}|g" \
        -e "s|{{RESOLVE_RESULT_2}}|${SKILL_RESOLVE_RESULT_2}|g" \
        -e "s|{{USAGE_EXAMPLE_1}}|${SKILL_USAGE_EXAMPLE_1}|g" \
        -e "s|{{USAGE_EXAMPLE_2}}|${SKILL_USAGE_EXAMPLE_2}|g" \
        "$template")"

    # Multi-line substitution for CTX7_COMMANDS (sed can't do this cleanly)
    local ctx7_escaped
    ctx7_escaped="$(printf '%s' "$ctx7_commands" | sed 's/[&/\]/\\&/g')"
    echo "$result" | awk -v replacement="$ctx7_commands" '{
        if (index($0, "{{CTX7_COMMANDS}}")) {
            sub(/{{CTX7_COMMANDS}}/, replacement)
        }
        print
    }'
}

# ─────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────
init_main() {
    local lang="" override_entry="" override_package="" override_src_dir=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --entry)   shift; override_entry="$1" ;;
            --package) shift; override_package="$1" ;;
            --src-dir) shift; override_src_dir="$1" ;;
            *) lang="$1" ;;
        esac
        shift
    done

    [ -n "$lang" ] || die "usage: discover init <lang> [--entry <file>] [--package <name>] [--src-dir <dir>]"

    # Validate lang config exists
    local lang_config="$DISCOVER_ROOT/langs/${lang}.sh"
    [ -f "$lang_config" ] || die "no lang config for '${lang}' — available: $(ls "$DISCOVER_ROOT/langs/" | sed 's/\.sh$//' | tr '\n' ' ')"

    # Source lang config to get metadata and function definitions
    source "$lang_config"

    # Find nearest .claude via the global find-claude-dir utility
    local claude_dir
    claude_dir="$(find-claude-dir)" || die "no .claude directory found"

    local project_root
    project_root="$(dirname "$claude_dir")"

    # Auto-detect project settings from manifests
    DETECTED_ENTRY=""
    DETECTED_PACKAGE=""

    if declare -f "detect_${lang}" >/dev/null 2>&1; then
        "detect_${lang}" "$project_root"
    fi

    # Explicit flags override auto-detection; auto-detection overrides lang defaults
    local entry="${override_entry:-${DETECTED_ENTRY:-$ENTRY_POINT_REL}}"
    local package="${override_package:-${DETECTED_PACKAGE:-$PACKAGE_NAME}}"
    local src_dir="${override_src_dir:-$SRC_DIR_REL}"

    # Script goes in project's scripts/ or bin/; SKILL.md goes in .claude/skills/discover/
    local script_dir
    script_dir="$(find_script_dir "$project_root")"
    local script_rel
    script_rel="$(realpath --relative-to="$project_root" "$script_dir")"
    local script_path="$script_rel/discover.sh"
    local test_script_path="$script_rel/test-discover.sh"

    local skill_dir="$claude_dir/skills/discover"
    mkdir -p "$skill_dir"

    # Generate standalone discover.sh into the project's script directory
    local gen_args=("$lang_config" --output "$script_dir/discover.sh")
    [ -n "$entry" ]   && gen_args+=(--entry "$entry")
    [ -n "$package" ] && gen_args+=(--package "$package")
    [ -n "$src_dir" ] && [ "$src_dir" != "$SRC_DIR_REL" ] && gen_args+=(--src-dir "$src_dir")

    bash "$DISCOVER_ROOT/generate.sh" "${gen_args[@]}"

    # Generate test-discover.sh into the project's script directory
    local test_template="$DISCOVER_ROOT/test-discover.sh.template"
    if [ -f "$test_template" ]; then
        sed \
            -e "s|{{SCRIPT_DIR}}|${script_rel}|g" \
            -e "s|{{ENTRY_POINT}}|${entry}|g" \
            -e "s|{{SRC_DIR}}|${src_dir}|g" \
            -e "s|{{FILE_EXT}}|${FILE_EXT}|g" \
            "$test_template" > "$script_dir/test-discover.sh"
        chmod +x "$script_dir/test-discover.sh"
    fi

    # Render SKILL.md into .claude/skills/discover/
    local template="$DISCOVER_ROOT/SKILL.md.template"
    [ -f "$template" ] || die "SKILL.md.template not found at $DISCOVER_ROOT"

    render_skill_md "$template" "$script_path" "$test_script_path" > "$skill_dir/SKILL.md"

    # Configure LSP if plugin info is available
    if [ -n "${LSP_PLUGIN:-}" ]; then
        local settings_file="$claude_dir/settings.json"
        if [ -f "$settings_file" ]; then
            if ! jq -e ".enabledPlugins[\"${LSP_PLUGIN}\"]" "$settings_file" >/dev/null 2>&1; then
                jq ".enabledPlugins[\"${LSP_PLUGIN}\"] = true" "$settings_file" > "${settings_file}.tmp" \
                    && mv "${settings_file}.tmp" "$settings_file"
                echo "  lsp    → enabled ${LSP_PLUGIN}" >&2
            else
                echo "  lsp    → ${LSP_PLUGIN} (already enabled)" >&2
            fi
        else
            echo '{}' | jq "{enabledPlugins: {\"${LSP_PLUGIN}\": true}}" > "$settings_file"
            echo "  lsp    → enabled ${LSP_PLUGIN} (created settings.json)" >&2
        fi
    elif [ -n "${LSP_BINARY:-}" ]; then
        echo "  lsp    → no Claude Code plugin; ensure '${LSP_BINARY}' is installed" >&2
    fi

    echo "discover: ${SKILL_LANG_NAME}" >&2
    echo "  script → $script_dir/discover.sh" >&2
    echo "  tests  → $script_dir/test-discover.sh" >&2
    echo "  skill  → $skill_dir/SKILL.md" >&2
}

init_main "$@"
