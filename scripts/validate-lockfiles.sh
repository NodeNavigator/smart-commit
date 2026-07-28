#!/bin/sh
# validate-lockfiles.sh — flags a manifest changed without its lockfile
# ("forgot to run install"). Repo-root manifests only (monorepo: extend).
#
# Usage: validate-lockfiles.sh [git-range]   # no arg = staged files
# Enforcement level: organization-policy.yml enforce_lockfile_check.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

[ "$SC_LOCKFILE_ENFORCEMENT" = "off" ] && exit 0

if [ -n "${1:-}" ]; then
    files=$(sc_changed_files_in_range "$1")
else
    files=$(sc_staged_files)
fi
[ -z "$files" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
flagged=0

# check_pair <manifest-name> <lockfile-candidate...> — returns 1 (and
# warns) only when the manifest changed, at least one candidate lockfile
# exists on disk, and none of the candidates changed alongside it.
check_pair() {
    manifest=$1
    shift
    printf '%s\n' "$files" | grep -qF "$manifest" || return 0

    for lockfile in "$@"; do
        if [ -f "$REPO_ROOT/$lockfile" ] && printf '%s\n' "$files" | grep -qxF "$lockfile"; then
            return 0  # in sync
        fi
    done

    for lockfile in "$@"; do
        if [ -f "$REPO_ROOT/$lockfile" ]; then
            sc_log_warn "$manifest changed but $lockfile did not — run the install/update command and commit the lockfile"
            return 1
        fi
    done
    return 0  # no lockfile exists for this ecosystem — nothing to compare
}

check_pair "package.json" "package-lock.json" "pnpm-lock.yaml" "yarn.lock" || flagged=1
check_pair "go.mod" "go.sum" || flagged=1
check_pair "Cargo.toml" "Cargo.lock" || flagged=1
check_pair "pyproject.toml" "poetry.lock" || flagged=1
check_pair "composer.json" "composer.lock" || flagged=1

[ "$flagged" -eq 1 ] && [ "$SC_LOCKFILE_ENFORCEMENT" = "block" ] && exit 1
exit 0
