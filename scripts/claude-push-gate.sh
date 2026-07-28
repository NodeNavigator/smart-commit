#!/bin/sh
# claude-push-gate.sh — Layer 2 equivalent of claude-commit-gate.sh, for
# `git push`. Same limits: best-effort parsing, not the enforcement
# boundary (githooks/pre-push and host branch protection are). Hard-blocks
# hook bypass flags and protected-branch pushes — both determinable from
# the command string alone. Force-push is different: this script cannot
# tell whether the user actually asked for it, so it always blocks and
# tells Claude to confirm first rather than silently retry.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SC_ENTRYPOINT=1   # scrub inherited SC_* cache/policy env before sourcing (see common.sh)
. "$SCRIPT_DIR/common.sh"

command_str=$(sc_extract_hook_command)
[ -z "${command_str:-}" ] && exit 0

case "$command_str" in
    *--no-verify*)
        sc_deny "hook bypass (--no-verify) is not permitted; fix the underlying issue instead of skipping validation."
        ;;
esac
case "$command_str" in
    *' -n '*|*' -n')
        sc_deny "hook bypass (-n) is not permitted; fix the underlying issue instead of skipping validation."
        ;;
esac
case "$command_str" in
    *'core.hooksPath='*)
        sc_deny "disabling hooks via core.hooksPath is not permitted; fix the underlying issue instead of skipping validation."
        ;;
esac

segment=$(sc_find_git_subcommand_segment "$command_str" push)
[ -z "$segment" ] && exit 0

# git push [<remote>] [<refspec>]; refspec is `branch`, `src:dst`,
# `+src:dst`, or absent (current branch). Flags are skipped, not parsed
# (e.g. `-o value`) — pre-push is the real boundary for anything missed.
positional=""
after_push=0
for tok in $segment; do
    if [ "$after_push" -eq 0 ]; then
        [ "$tok" = "push" ] && after_push=1
        continue
    fi
    case "$tok" in
        -*) continue ;;
        *) positional="$positional $tok" ;;
    esac
done
set -- $positional
refspec_arg=${2:-}

if [ -n "$refspec_arg" ]; then
    dst=${refspec_arg#*:}   # "src:dst" -> "dst"; no colon -> unchanged
    dst=${dst#+}
    target_branch=${dst#refs/heads/}
else
    target_branch=$(sc_current_branch)
fi

if [ -n "$target_branch" ] && sc_is_protected_branch "$target_branch"; then
    sc_deny "direct push to '$target_branch' is blocked by this repo's policy (config/organization-policy.yml: protected_branches). Open a pull request instead — do not retry this push."
fi

# Warn-only, never sc_deny here: this script has no reliable, network-free
# way to know if $target_branch already exists on the remote, so it can't
# tell "new branch, naming applies" from "existing branch, don't relitigate
# its name" the way pre-push (which sees remote_sha) can. Best-effort local
# check — a remote-tracking ref already existing is a reasonable signal
# this isn't a brand-new branch.
if [ -n "$target_branch" ] && [ "$SC_BRANCH_NAME_ENFORCEMENT" != "off" ] \
   && ! git rev-parse --verify -q "refs/remotes/origin/$target_branch" >/dev/null 2>&1; then
    reason=$(sc_branch_name_violation "$target_branch")
    [ -n "$reason" ] && sc_log_warn "$reason (pre-push enforces this per config/organization-policy.yml: enforce_branch_naming)"
fi

case "$segment" in
    *--force-with-lease*|*--force*|*' -f '*|*' -f')
        sc_deny \
            "force-pushing was attempted." \
            "Do NOT retry with --force or --force-with-lease automatically. Only proceed if the user's own message in this conversation explicitly asked for a force push to this exact branch — if they did, you may retry; if you inferred it yourself, STOP and ask the user to confirm first."
        ;;
esac

exit 0
