#!/bin/sh
# validate-commit-msg.sh — the single source of truth for commit message rules.
# Every enforcement layer (Claude gate, git commit-msg hook, CI parity check,
# and the Enterprise Server pre-receive hook if used) calls this script.
# Do not re-implement these rules anywhere else — that is how layers drift.
#
# Usage:
#   validate-commit-msg.sh <file>   # reads the subject from the first line of <file>
#   validate-commit-msg.sh          # reads the subject from stdin
#
# Exit 0 = valid, no output.
# Exit 1 = invalid, one human-readable reason per line on stdout.

set -eu

if [ "${1:-}" != "" ]; then
    subject=$(head -n 1 -- "$1")
else
    subject=$(head -n 1)
fi

# Pass-throughs that must never be rejected: merge/revert/rebase workflows
# produce these automatically and are not authored commit messages.
case "$subject" in
    "Merge "*|'Revert "'*|"fixup! "*|"squash! "*)
        exit 0
        ;;
esac

reasons=""
fail=0

add_reason() {
    reasons="${reasons}${1}
"
    fail=1
}

format_ok=1
if ! printf '%s\n' "$subject" | grep -Eq '^(feat|fix|refactor|perf|docs|test|style|chore|build|ci|revert)(\([a-z0-9/_-]+\))?!?: .+$'; then
    format_ok=0
    add_reason "subject must match 'type(scope): description' (types: feat, fix, refactor, perf, docs, test, style, chore, build, ci, revert)"
fi

len=${#subject}
if [ "$len" -gt 72 ]; then
    add_reason "subject is $len chars, must be <= 72"
fi
if [ "$len" -lt 10 ]; then
    add_reason "subject is $len chars, must be >= 10 (too short to be meaningful)"
fi

case "$subject" in
    *.) add_reason "subject must not end with a period" ;;
esac

# Only checked when the format matched — otherwise there's no reliable colon
# to split on, and the format reason above already covers it.
if [ "$format_ok" -eq 1 ]; then
    after_colon="${subject#*: }"
    first_char=$(printf '%s' "$after_colon" | cut -c1)
    case "$first_char" in
        [A-Z]) add_reason "description after the colon must not start with an uppercase letter" ;;
    esac
fi

if [ "$format_ok" -eq 1 ]; then
    lower_description=$(printf '%s' "$after_colon" | tr '[:upper:]' '[:lower:]')
    case "$lower_description" in
        fix|update|wip|changes|misc|stuff|done|temp|patch|hotfix)
            add_reason "'$after_colon' is not a valid description — say what changed and why"
            ;;
    esac
else
    lower_subject=$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]')
    case "$lower_subject" in
        fix|update|wip|changes|misc|stuff|done|temp|patch|hotfix)
            add_reason "'$subject' is not a description — say what changed and why"
            ;;
    esac
fi

if [ "$fail" -eq 1 ]; then
    printf '%s' "$reasons"
    exit 1
fi

exit 0
