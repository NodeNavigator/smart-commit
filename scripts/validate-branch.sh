#!/bin/sh
# validate-branch.sh — protected-branch push check + branch naming
# convention. Shared by githooks/pre-push and claude-push-gate.sh so
# neither rule can drift.
#
# Naming is only checked for a NEW branch (second arg "new") — enforcing
# it on every push of an already-existing branch would retroactively
# break a team's pre-existing branch names the day this ships.
#
# Usage: validate-branch.sh [remote-ref] [new]   e.g. refs/heads/main; no ref = current branch
# Exit 0 = ok. Exit 1 = protected, or (enforce_branch_naming=block) a non-compliant new branch name.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

ref=${1:-}
is_new=${2:-}
if [ -n "$ref" ]; then
    branch=${ref#refs/heads/}
else
    branch=$(sc_current_branch)
fi

if sc_is_protected_branch "$branch"; then
    sc_log_fail "direct push to '$branch' is blocked by this repo's policy (config/organization-policy.yml: protected_branches). Open a pull request instead."
    exit 1
fi

if [ "$is_new" = "new" ] && [ "$SC_BRANCH_NAME_ENFORCEMENT" != "off" ]; then
    reason=$(sc_branch_name_violation "$branch")
    if [ -n "$reason" ]; then
        if [ "$SC_BRANCH_NAME_ENFORCEMENT" = "block" ]; then
            sc_log_fail "$reason"
            exit 1
        fi
        sc_log_warn "$reason"
    fi
fi

exit 0
