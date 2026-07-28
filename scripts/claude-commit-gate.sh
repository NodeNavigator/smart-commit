#!/bin/sh
# claude-commit-gate.sh — Layer 2: fast feedback before Claude runs
# `git commit`. Best-effort command-string parsing, NOT the enforcement
# boundary — commit-msg (Layer 3) validates the message git actually
# constructs. Fails open (exit 0) when it can't confidently parse.
#
# Exit 2 (not the JSON permissionDecision) works around two live Claude
# Code bugs — see enforcement.md #18312 and #24327. Reads hook JSON on
# stdin. Sibling: claude-push-gate.sh, same pattern for `git push`.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SC_ENTRYPOINT=1   # scrub inherited SC_* cache/policy env before sourcing (see common.sh)
. "$SCRIPT_DIR/common.sh"
VALIDATOR="$SCRIPT_DIR/validate-commit-msg.sh"

deny() { sc_deny "$1"; }

command_str=$(sc_extract_hook_command)

[ -z "${command_str:-}" ] && exit 0

case "$command_str" in
    *--no-verify*)
        deny "hook bypass (--no-verify) is not permitted; fix the underlying issue instead of skipping validation."
        ;;
esac
case "$command_str" in
    *' -n '*|*' -n')
        deny "hook bypass (-n) is not permitted; fix the underlying issue instead of skipping validation."
        ;;
esac
case "$command_str" in
    *'core.hooksPath='*)
        deny "disabling hooks via core.hooksPath is not permitted; fix the underlying issue instead of skipping validation."
        ;;
esac

segment=$(sc_find_git_subcommand_segment "$command_str" commit)

[ -z "$segment" ] && exit 0

# --amend --no-edit keeps the existing message — nothing new to validate.
case "$segment" in
    *--no-edit*) exit 0 ;;
esac

if ! printf '%s' "$segment" | grep -Eq -- '(^|[[:space:]])(-m[= ]|--message[= ])'; then
    deny "use -m with a single conventional-commit message instead of an editor or -F file."
fi

# First -m/--message value only (git uses it as the subject when repeated).
raw=$(printf '%s' "$segment" | grep -oE -- '(-m|--message)[= ]"[^"]*"' | head -n 1)
quote='"'
if [ -z "$raw" ]; then
    raw=$(printf '%s' "$segment" | grep -oE -- "(-m|--message)[= ]'[^']*'" | head -n 1)
    quote="'"
fi

message=""
if [ -n "$raw" ]; then
    tmp=${raw#-m}
    tmp=${tmp#--message}
    tmp=${tmp# }
    tmp=${tmp#=}
    tmp=${tmp#"$quote"}
    message=${tmp%"$quote"}
fi
subject=$(printf '%s\n' "$message" | head -n 1)

[ -z "$subject" ] && exit 0  # could not confidently extract — defer to Layer 3

reasons=$(printf '%s' "$subject" | "$VALIDATOR" 2>&1)
status=$?
if [ "$status" -ne 0 ]; then
    deny "Fix the commit message:
$reasons"
fi

exit 0
