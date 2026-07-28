#!/bin/sh
# validate-generated-files.sh — co-change heuristic for generated
# protobuf/OpenAPI code: source spec changed but no matching generated
# file did (or vice versa) in the same diff. Not a codegen re-run.
#
# Usage: validate-generated-files.sh [git-range]   # no arg = staged files
# Enforcement level: organization-policy.yml enforce_generated_files_check.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

[ "$SC_GENERATED_FILES_ENFORCEMENT" = "off" ] && exit 0

if [ -n "${1:-}" ]; then
    files=$(sc_changed_files_in_range "$1")
else
    files=$(sc_staged_files)
fi
[ -z "$files" ] && exit 0

EXTENSIONS="$SC_CONFIG_DIR/extensions.conf"
sc_ext_get() {
    key=$1
    [ -f "$EXTENSIONS" ] || { printf ''; return; }
    grep -E "^${key}=" "$EXTENSIONS" 2>/dev/null | head -n 1 | sed "s/^${key}=//"
}

proto_suffixes=$(sc_ext_get GENERATED_PROTO_SUFFIXES)
swagger_suffixes=$(sc_ext_get GENERATED_SWAGGER_SUFFIXES)

any_suffix_matched() {
    # any_suffix_matched <csv-of-suffixes>
    csv=$1
    old_ifs=$IFS
    IFS=,
    for suffix in $csv; do
        IFS=$old_ifs
        if printf '%s\n' "$files" | grep -qF "$suffix"; then
            IFS=$old_ifs
            return 0
        fi
        IFS=,
    done
    IFS=$old_ifs
    return 1
}

warned=0

proto_sources_changed=$(printf '%s\n' "$files" | grep -c '\.proto$')
if [ "$proto_sources_changed" -gt 0 ] && [ -n "$proto_suffixes" ]; then
    if ! any_suffix_matched "$proto_suffixes"; then
        sc_log_warn ".proto file(s) changed but no generated code (suffixes: $proto_suffixes) changed in the same diff — regenerate protobuf bindings?"
        warned=1
    fi
fi

openapi_sources_changed=$(printf '%s\n' "$files" | grep -icE '(openapi|swagger)\.(ya?ml|json)$')
if [ "$openapi_sources_changed" -gt 0 ] && [ -n "$swagger_suffixes" ]; then
    if ! any_suffix_matched "$swagger_suffixes"; then
        sc_log_warn "OpenAPI/Swagger spec changed but no generated client/server code (suffixes: $swagger_suffixes) changed in the same diff — regenerate API bindings?"
        warned=1
    fi
fi

if [ -n "$proto_suffixes" ] && any_suffix_matched "$proto_suffixes" && [ "$proto_sources_changed" -eq 0 ]; then
    sc_log_warn "generated protobuf code changed without a corresponding .proto change in this diff — hand-edited or generated from a stale source?"
    warned=1
fi

[ "$warned" -eq 1 ] && [ "$SC_GENERATED_FILES_ENFORCEMENT" = "block" ] && exit 1
exit 0
