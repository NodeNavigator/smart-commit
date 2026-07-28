#!/bin/sh
# validate-migrations.sh — two convention-based heuristics, no DB/tool
# integration: (1) a new `NNN.up.sql` should ship with `NNN.down.sql` and
# vice versa; (2) don't edit a migration already on the protected branch —
# add a new one instead.
#
# Usage: validate-migrations.sh [git-range]   # no arg = staged files
# Enforcement level: organization-policy.yml enforce_migration_check.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

[ "$SC_MIGRATION_ENFORCEMENT" = "off" ] && exit 0

MIGRATION_GLOBS='*/migrations/* migrations/* */migrate/* db/migrate/* prisma/migrations/*'

sc_determine_base_ref() {
    old_ifs=$IFS
    IFS=,
    for b in $SC_PROTECTED_BRANCHES; do
        IFS=$old_ifs
        b=$(printf '%s' "$b" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if git rev-parse --verify -q "origin/$b" >/dev/null 2>&1; then
            printf 'origin/%s' "$b"
            return 0
        fi
        IFS=,
    done
    IFS=$old_ifs
    printf 'HEAD'
}

flagged=0

# --- Check 1: paired up/down migration files -----------------------------
if [ -n "${1:-}" ]; then
    added=$(git diff "$1" --name-only --diff-filter=A -- $MIGRATION_GLOBS 2>/dev/null)
    all_changed=$(sc_changed_files_in_range "$1")
else
    added=$(git diff --cached --name-only --diff-filter=A -- $MIGRATION_GLOBS 2>/dev/null)
    all_changed=$(sc_staged_files)
fi

if [ -n "$added" ]; then
    pair_result=$(printf '%s\n' "$added" | while IFS= read -r f; do
        [ -z "$f" ] && continue
        counterpart=""
        case "$f" in
            *.up.sql) counterpart=$(printf '%s' "$f" | sed 's/\.up\.sql$/.down.sql/') ;;
            *.down.sql) counterpart=$(printf '%s' "$f" | sed 's/\.down\.sql$/.up.sql/') ;;
        esac
        [ -z "$counterpart" ] && continue
        if ! printf '%s\n' "$all_changed" | grep -qxF "$counterpart" && [ ! -f "$counterpart" ]; then
            sc_log_warn "$f was added without its counterpart ($counterpart) — migration may be unpaired"
            printf 'FLAG\n'
        fi
    done)
    [ "$(printf '%s\n' "$pair_result" | grep -c '^FLAG$')" -gt 0 ] && flagged=1
fi

# --- Check 2: don't edit an already-merged migration ----------------------
base_ref=$(sc_determine_base_ref)
if [ -n "${1:-}" ]; then
    modified=$(git diff "$1" --name-only --diff-filter=M -- $MIGRATION_GLOBS 2>/dev/null)
else
    modified=$(git diff --cached "$base_ref" --name-only --diff-filter=M -- $MIGRATION_GLOBS 2>/dev/null)
fi

if [ -n "$modified" ]; then
    sc_log_warn "migration file(s) already present on '$base_ref' are being modified in place — add a new migration instead of editing history:
$modified"
    flagged=1
fi

[ "$flagged" -eq 1 ] && [ "$SC_MIGRATION_ENFORCEMENT" = "block" ] && exit 1
exit 0
