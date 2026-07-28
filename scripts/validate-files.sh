#!/bin/sh
# validate-files.sh — filename/path denylist check (secret CONTENT
# scanning is validate-secrets.sh's job). Reads config/denylist.conf,
# allowlist.conf, extensions.conf.
#
# Usage: validate-files.sh [git-range]   # no arg = staged files
# Exit 0 = no hard blocks. Exit 1 = a hard block was found.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

DENYLIST="$SC_CONFIG_DIR/denylist.conf"
ALLOWLIST="$SC_CONFIG_DIR/allowlist.conf"
EXTENSIONS="$SC_CONFIG_DIR/extensions.conf"

if [ -n "${1:-}" ]; then
    files=$(sc_changed_files_in_range "$1")
else
    files=$(sc_staged_files)
fi

[ -z "$files" ] && exit 0

# sc_pattern_match <path> <patterns-file> — echoes the matched raw config
# line (including a "WARN " prefix if present) and returns 0 on match.
sc_pattern_match() {
    path=$1
    pfile=$2
    [ -f "$pfile" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        trimmed=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        case "$trimmed" in
            ''|'#'*) continue ;;
        esac
        pattern=$trimmed
        case "$trimmed" in
            "WARN "*) pattern=${trimmed#WARN } ;;
        esac
        case "$path" in
            $pattern) printf '%s' "$trimmed"; return 0 ;;
        esac
    done < "$pfile"
    return 1
}

# sc_ext_list_match <path> <comma-separated-list> — matches either a path
# segment (directory-style entries like .idea) or a suffix (extension-style
# entries like .zip); echoes the matched item and returns 0 on match.
sc_ext_list_match() {
    path=$1
    csv=$2
    old_ifs=$IFS
    IFS=,
    for item in $csv; do
        IFS=$old_ifs
        case "$path" in
            */"$item"/*|"$item"/*|*"$item")
                printf '%s' "$item"
                return 0
                ;;
        esac
        IFS=,
    done
    IFS=$old_ifs
    return 1
}

sc_ext_get() {
    key=$1
    [ -f "$EXTENSIONS" ] || { printf ''; return; }
    grep -E "^${key}=" "$EXTENSIONS" 2>/dev/null | head -n 1 | sed "s/^${key}=//"
}

BINARY_EXTENSIONS=$(sc_ext_get BINARY_EXTENSIONS)
IDE_FILES=$(sc_ext_get IDE_FILES)
OS_FILES=$(sc_ext_get OS_FILES)
# Defensive: guard the arithmetic sink even when common.sh's sanitize was
# skipped (e.g. a directly-invoked validator with a poisoned SC_* cache env).
case "${SC_MAX_FILE_SIZE_MB:-}" in ''|*[!0-9]*) SC_MAX_FILE_SIZE_MB=5 ;; esac
max_bytes=$((SC_MAX_FILE_SIZE_MB * 1024 * 1024))

# Only "BLOCK" markers land on stdout (captured below); sc_log_* writes
# straight to stderr so warnings/errors are visible immediately regardless
# of the command-substitution subshell this loop runs in.
result=$(printf '%s\n' "$files" | while IFS= read -r f; do
    [ -z "$f" ] && continue

    if matched=$(sc_pattern_match "$f" "$DENYLIST"); then
        if sc_pattern_match "$f" "$ALLOWLIST" >/dev/null; then
            : # explicitly allowlisted — skip both warn and block
        else
            case "$matched" in
                "WARN "*)
                    sc_log_warn "$f matches '${matched#WARN }' — verify this is intentional (config/denylist.conf)"
                    ;;
                *)
                    sc_log_fail "$f matches denylisted pattern '$matched' — must not be committed"
                    printf 'BLOCK\n'
                    ;;
            esac
        fi
    fi

    if [ -f "$f" ]; then
        size=$(sc_file_size_bytes "$f")
        if [ -n "$size" ] && [ "$size" -gt "$max_bytes" ]; then
            sc_log_fail "$f is $size bytes, exceeds the ${SC_MAX_FILE_SIZE_MB}MB limit (config/organization-policy.yml: max_file_size_mb)"
            printf 'BLOCK\n'
        fi
    fi

    if [ -n "$BINARY_EXTENSIONS" ] && match=$(sc_ext_list_match "$f" "$BINARY_EXTENSIONS"); then
        sc_log_warn "$f looks like a binary/archive artifact ('$match') — confirm this belongs in source control"
    fi
    if [ -n "$IDE_FILES" ] && match=$(sc_ext_list_match "$f" "$IDE_FILES"); then
        sc_log_warn "$f looks like an IDE project file ('$match') — usually belongs in .gitignore"
    fi
    if [ -n "$OS_FILES" ] && match=$(sc_ext_list_match "$f" "$OS_FILES"); then
        sc_log_fail "$f is an OS-generated file ('$match') — must not be committed"
        printf 'BLOCK\n'
    fi
done)

block_count=$(printf '%s\n' "$result" | grep -c '^BLOCK$')
[ "$block_count" -gt 0 ] && exit 1
exit 0
