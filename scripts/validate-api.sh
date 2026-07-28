#!/bin/sh
# validate-api.sh — breaking-change heuristics: line-diff pattern matching
# only, not a real schema tool (`buf breaking`/`openapi-diff`). Flags a
# removed proto field/message without a `reserved` guard, and a removed
# OpenAPI/Swagger path.
#
# Usage: validate-api.sh [git-range]   # no arg = staged changes
# Enforcement level: organization-policy.yml enforce_api_check.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

[ "$SC_API_ENFORCEMENT" = "off" ] && exit 0

if [ -n "${1:-}" ]; then
    diff_args="$1"
else
    diff_args="--cached"
fi

proto_files=$(git diff $diff_args --name-only --diff-filter=M -- '*.proto' 2>/dev/null)
api_files=$(git diff $diff_args --name-only --diff-filter=M -- '*openapi*.yml' '*openapi*.yaml' '*openapi*.json' '*swagger*.yml' '*swagger*.yaml' '*swagger*.json' 2>/dev/null)

[ -z "$proto_files" ] && [ -z "$api_files" ] && exit 0

flagged=0

if [ -n "$proto_files" ]; then
    proto_result=$(printf '%s\n' "$proto_files" | while IFS= read -r f; do
        [ -z "$f" ] && continue
        d=$(git diff -U0 $diff_args -- "$f" 2>/dev/null)
        removed_field=$(printf '%s\n' "$d" | grep -E '^-[[:space:]]*(repeated|optional|required)?[[:space:]]*[A-Za-z0-9_.]+[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*;')
        removed_message=$(printf '%s\n' "$d" | grep -E '^-[[:space:]]*message[[:space:]]+[A-Za-z_]')
        has_reserved=$(printf '%s\n' "$d" | grep -E '^\+.*reserved[[:space:]]')
        if [ -n "$removed_field$removed_message" ] && [ -z "$has_reserved" ]; then
            sc_log_warn "$f: a proto field or message appears to have been removed without adding a 'reserved' guard — this can break wire compatibility for clients still using that field/message number"
            printf 'FLAG\n'
        fi
    done)
    proto_flags=$(printf '%s\n' "$proto_result" | grep -c '^FLAG$')
    [ "$proto_flags" -gt 0 ] && flagged=1
fi

if [ -n "$api_files" ]; then
    api_result=$(printf '%s\n' "$api_files" | while IFS= read -r f; do
        [ -z "$f" ] && continue
        d=$(git diff -U0 $diff_args -- "$f" 2>/dev/null)
        removed_path=$(printf '%s\n' "$d" | grep -E '^-[[:space:]]*/[A-Za-z0-9_{}/.-]*:[[:space:]]*$')
        if [ -n "$removed_path" ]; then
            sc_log_warn "$f: an API path appears to have been removed — verify this is an intentional breaking change"
            printf 'FLAG\n'
        fi
    done)
    api_flags=$(printf '%s\n' "$api_result" | grep -c '^FLAG$')
    [ "$api_flags" -gt 0 ] && flagged=1
fi

[ "$flagged" -eq 1 ] && [ "$SC_API_ENFORCEMENT" = "block" ] && exit 1
exit 0
