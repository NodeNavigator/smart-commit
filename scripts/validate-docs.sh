#!/bin/sh
# validate-docs.sh — docs-drift heuristic: public surface (API/proto/
# schema/config/CLI) changed but nothing doc-like did. Co-change check
# only — can't tell if a doc update is correct, just whether one happened.
#
# Usage: validate-docs.sh [git-range]   # no arg = staged files
# Enforcement level: organization-policy.yml enforce_docs_warning.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

[ "$SC_DOCS_ENFORCEMENT" = "off" ] && exit 0

if [ -n "${1:-}" ]; then
    files=$(sc_changed_files_in_range "$1")
else
    files=$(sc_staged_files)
fi
[ -z "$files" ] && exit 0

matches_any() {
    # matches_any <newline-list> <pattern1> <pattern2> ...
    list=$1
    shift
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        for pattern in "$@"; do
            case "$f" in
                $pattern) return 0 ;;
            esac
        done
    done <<EOF
$list
EOF
    return 1
}

surface_touched=0
reason=""

if matches_any "$files" '*.proto'; then
    surface_touched=1; reason="${reason}proto definitions, "
fi
if matches_any "$files" '*openapi*.yml' '*openapi*.yaml' '*openapi*.json' '*swagger*.yml' '*swagger*.yaml' '*swagger*.json'; then
    surface_touched=1; reason="${reason}API spec, "
fi
if matches_any "$files" '*/migrations/*' 'migrations/*' '*schema.sql' '*schema.rb' '*.prisma'; then
    surface_touched=1; reason="${reason}database schema, "
fi
if matches_any "$files" '*/config/*.yml' '*/config/*.yaml' '*application.yml' '*application.properties' '*.env.example'; then
    surface_touched=1; reason="${reason}configuration, "
fi
if matches_any "$files" '*/cmd/*/main.go' '*cli.py' '*_cli.go' '*/bin/cli*'; then
    surface_touched=1; reason="${reason}CLI entry point, "
fi

[ "$surface_touched" -eq 0 ] && exit 0

if matches_any "$files" '*.md' '*/docs/*' 'docs/*' 'CHANGELOG*' 'README*'; then
    exit 0  # docs were touched alongside the surface change — nothing to flag
fi

sc_log_warn "this change touches ${reason%, } but no README/docs/CHANGELOG file changed alongside it — is documentation up to date?"
[ "$SC_DOCS_ENFORCEMENT" = "block" ] && exit 1
exit 0
