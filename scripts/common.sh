#!/bin/sh
# common.sh — shared helper library sourced by every hook, validator, and
# Claude gate. One place for config/branch/file-listing/hook-parsing logic
# so callers can't drift from each other.
#
# Contract: caller sets SCRIPT_DIR before sourcing ($0 in a sourced file
# isn't reliably its own path across shells):
#   SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
#   . "$SCRIPT_DIR/common.sh"

: "${SCRIPT_DIR:?common.sh requires SCRIPT_DIR to be set by the caller before sourcing}"

# Security: a top-level hook sets SC_ENTRYPOINT=1 (NOT exported) before sourcing
# this. When set, discard any policy/cache values inherited from the environment
# — otherwise a local user could disable checks without --no-verify, e.g.
#   SC_POLICY_CACHED=1 SC_PROTECTED_BRANCHES= git push origin main
#   SC_STAGED_FILES_CACHED=1 SC_STAGED_FILES_CACHE= git commit -m "feat: leak"
# The hook then recomputes from config below and re-exports for the validator
# subprocesses it forks — those do NOT see SC_ENTRYPOINT, so they keep the cache.
if [ "${SC_ENTRYPOINT:-0}" = "1" ]; then
    unset SC_POLICY_CACHED \
        SC_PROTECTED_BRANCHES SC_MAX_FILE_SIZE_MB SC_ENABLE_GITLEAKS \
        SC_ENABLE_TRUFFLEHOG SC_ENABLE_GIT_SECRETS SC_ENABLE_LINT \
        SC_DOCS_ENFORCEMENT SC_LOCKFILE_ENFORCEMENT SC_MIGRATION_ENFORCEMENT \
        SC_GENERATED_FILES_ENFORCEMENT SC_API_ENFORCEMENT SC_BRANCH_NAME_ENFORCEMENT \
        SC_STAGED_FILES_CACHED SC_STAGED_FILES_CACHE \
        SC_RANGE_FILES_CACHED SC_RANGE_FILES_CACHE SC_RANGE_FILES_RANGE 2>/dev/null || true
fi

# config/ is a child of SCRIPT_DIR when installed (.githooks/config/), a
# sibling when running from the source package (scripts/../config).
if [ -d "$SCRIPT_DIR/config" ]; then
    SC_CONFIG_DIR="$SCRIPT_DIR/config"
elif [ -d "$SCRIPT_DIR/../config" ]; then
    SC_CONFIG_DIR="$SCRIPT_DIR/../config"
else
    SC_CONFIG_DIR=""
fi

if [ -t 2 ]; then
    SC_RED='\033[31m'; SC_YELLOW='\033[33m'; SC_GREEN='\033[32m'; SC_RESET='\033[0m'
else
    SC_RED=''; SC_YELLOW=''; SC_GREEN=''; SC_RESET=''
fi

sc_log_info() { printf '%s\n' "$1" >&2; }
sc_log_warn() { printf "${SC_YELLOW}warning:${SC_RESET} %s\n" "$1" >&2; }
sc_log_fail() { printf "${SC_RED}error:${SC_RESET} %s\n" "$1" >&2; }
sc_log_ok()   { printf "${SC_GREEN}ok:${SC_RESET} %s\n" "$1" >&2; }

# organization-policy.yml is flat `key: value` only (no nesting/lists) so
# it parses without a YAML library — see the file's own header before
# adding nested YAML, the fallback parser below will mis-parse it.
sc_policy_get() {
    key=$1
    default=$2
    file="$SC_CONFIG_DIR/organization-policy.yml"
    if [ -z "$SC_CONFIG_DIR" ] || [ ! -f "$file" ]; then
        printf '%s' "$default"
        return
    fi

    if command -v yq >/dev/null 2>&1; then
        val=$(yq -r ".${key} // \"\"" "$file" 2>/dev/null)
    else
        val=$(grep -E "^${key}[[:space:]]*:" "$file" 2>/dev/null | head -n 1 \
            | sed -e "s/^${key}[[:space:]]*:[[:space:]]*//" -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//')
    fi

    if [ -z "$val" ]; then
        printf '%s' "$default"
    else
        printf '%s' "$val"
    fi
}

# Cache guard: pre-commit/pre-push source this once and export the
# result, so the 8 validator subprocesses each fork inherit it instead of
# re-parsing organization-policy.yml (11 grep+sed forks) for themselves —
# a standalone validator run (no cache in the environment) still computes
# it fresh here, same as before.
if [ "${SC_POLICY_CACHED:-0}" != "1" ]; then
    SC_PROTECTED_BRANCHES=$(sc_policy_get protected_branches "main,master,production,release,dev,qa,testnet")
    SC_MAX_FILE_SIZE_MB=$(sc_policy_get max_file_size_mb "5")
    # Must be a plain integer: it feeds shell arithmetic in validate-files.sh,
    # and a non-numeric value (from a repo-committed config in the per-repo
    # fallback) could inject a command under bash-as-/bin/sh or silently break
    # the size check. Fall back to the default on anything non-numeric.
    case "$SC_MAX_FILE_SIZE_MB" in ''|*[!0-9]*) SC_MAX_FILE_SIZE_MB=5 ;; esac
    SC_ENABLE_GITLEAKS=$(sc_policy_get enable_gitleaks "true")
    SC_ENABLE_TRUFFLEHOG=$(sc_policy_get enable_trufflehog "false")
    SC_ENABLE_GIT_SECRETS=$(sc_policy_get enable_git_secrets "false")
    SC_ENABLE_LINT=$(sc_policy_get enable_lint "true")
    SC_DOCS_ENFORCEMENT=$(sc_policy_get enforce_docs_warning "warn")
    SC_LOCKFILE_ENFORCEMENT=$(sc_policy_get enforce_lockfile_check "block")
    SC_MIGRATION_ENFORCEMENT=$(sc_policy_get enforce_migration_check "block")
    SC_GENERATED_FILES_ENFORCEMENT=$(sc_policy_get enforce_generated_files_check "warn")
    SC_API_ENFORCEMENT=$(sc_policy_get enforce_api_check "warn")
    SC_BRANCH_NAME_ENFORCEMENT=$(sc_policy_get enforce_branch_naming "block")
    SC_POLICY_CACHED=1
    export SC_PROTECTED_BRANCHES SC_MAX_FILE_SIZE_MB SC_ENABLE_GITLEAKS \
        SC_ENABLE_TRUFFLEHOG SC_ENABLE_GIT_SECRETS SC_ENABLE_LINT \
        SC_DOCS_ENFORCEMENT SC_LOCKFILE_ENFORCEMENT SC_MIGRATION_ENFORCEMENT \
        SC_GENERATED_FILES_ENFORCEMENT SC_API_ENFORCEMENT SC_BRANCH_NAME_ENFORCEMENT \
        SC_POLICY_CACHED
fi

sc_current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null
}

sc_is_protected_branch() {
    branch=$1
    old_ifs=$IFS
    IFS=,
    matched=1
    for b in $SC_PROTECTED_BRANCHES; do
        b=$(printf '%s' "$b" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ "$branch" = "$b" ] && matched=0
    done
    IFS=$old_ifs
    return $matched
}

# sc_branch_name_violation <branch> — echoes a reason and returns 1 if
# the name doesn't meet the industry-standard <type>/kebab-case-description
# convention (git-flow-derived types, same taxonomy as commit types);
# returns 0 silently if compliant or exempt (protected branches, detached
# HEAD). Hardcoded here, not config-driven, same reasoning as
# validate-commit-msg.sh's type list — one shared shape, not a per-repo
# regex to keep in sync.
sc_branch_name_violation() {
    branch=$1
    case "$branch" in
        ''|HEAD) return 0 ;;
    esac
    sc_is_protected_branch "$branch" && return 0

    lower=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]')
    if [ "$branch" != "$lower" ]; then
        printf 'branch name "%s" has uppercase letters — use lowercase kebab-case, e.g. feat/add-oauth-login' "$branch"
        return 1
    fi

    if ! printf '%s' "$branch" | grep -Eq '^(feature|feat|fix|bugfix|hotfix|release|chore|docs|refactor|test|perf|ci|build|style)/[a-z0-9]+(-[a-z0-9]+)*$'; then
        printf 'branch name "%s" must match <type>/<kebab-case-description> (types: feature/feat fix/bugfix hotfix release chore docs refactor test perf ci build style), e.g. feat/add-oauth-login or fix/proj-123-null-pointer' "$branch"
        return 1
    fi

    description=${branch#*/}
    case "$description" in
        fix|wip|test|temp|tmp|update|changes|misc|stuff|new|old|backup|foo|asdf)
            printf 'branch name "%s" — "%s" is not descriptive, say what it does' "$branch" "$description"
            return 1
            ;;
    esac
    return 0
}

# Same cache pattern as the policy vars above: the hook computes the
# diff once and exports it so the 8 validator subprocesses forked from it
# don't each re-run `git diff` for the same result. A standalone
# validator run (no cache exported) falls through to a real git call.
sc_staged_files() {
    if [ "${SC_STAGED_FILES_CACHED:-0}" = "1" ]; then
        printf '%s' "$SC_STAGED_FILES_CACHE"
        return
    fi
    git diff --cached --name-only --diff-filter=ACMR
}

# sc_changed_files_in_range <range>   e.g. "$remote_sha..$local_sha"
sc_changed_files_in_range() {
    if [ "${SC_RANGE_FILES_CACHED:-0}" = "1" ] && [ "${SC_RANGE_FILES_RANGE:-}" = "$1" ]; then
        printf '%s' "$SC_RANGE_FILES_CACHE"
        return
    fi
    git diff --name-only --diff-filter=ACMR "$1" 2>/dev/null
}

sc_file_size_bytes() {
    wc -c < "$1" 2>/dev/null | tr -d ' '
}

SC_ZERO_SHA='0000000000000000000000000000000000000000'

# Reads a PreToolUse hook's JSON stdin, extracts tool_input.command.
sc_extract_hook_command() {
    hook_input=$(cat)
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$hook_input" | jq -r '.tool_input.command // empty' 2>/dev/null
    else
        printf '%s' "$hook_input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*[,}].*/\1/p' | sed 's/\\"/"/g'
    fi
}

# sc_deny <reason> [directive] — blocks via exit 2 (not the JSON
# permissionDecision — see enforcement.md #18312 for why). [directive]
# defaults to "fix and retry silently"; override it when the right move
# is the opposite, e.g. claude-push-gate.sh's force-push check needs
# Claude to stop and confirm with the user instead.
sc_deny() {
    reason=$1
    directive=${2:-"Fix the issue and retry the SAME command. Do NOT stop or ask the user."}
    printf 'AUTOMATED QUALITY GATE — not a user denial.\n' >&2
    printf '%s\n' "$reason" >&2
    printf '%s\n' "$directive" >&2
    exit 2
}

# sc_find_git_subcommand_segment <command-string> <subcommand> — heuristic
# split on shell control operators; finds the LAST segment invoking
# `git ... <subcommand>` among compound commands, so a bypass like
# `git -c core.hooksPath=/dev/null commit ...` can't dodge a narrow
# matcher. Echoes the matched segment, or nothing. Shared by both Claude
# gates so the parsing can't drift between them.
sc_find_git_subcommand_segment() {
    command_str=$1
    subcommand=$2
    segment=""
    while IFS= read -r line; do
        trimmed=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if printf '%s' "$trimmed" | grep -Eq "^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*git([[:space:]]+[^[:space:]]+)*[[:space:]]+${subcommand}([[:space:]]|\$)"; then
            segment=$trimmed
        fi
    done <<EOF
$(printf '%s\n' "$command_str" | tr ';|' '\n\n' | sed 's/&&/\n/g')
EOF
    printf '%s' "$segment"
}
