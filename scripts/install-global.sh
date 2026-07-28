#!/bin/sh
# install-global.sh — ONE-TIME, machine-wide rollout. Every git repo on
# this machine uses these hooks with zero per-repo action, via
# `git config --system core.hooksPath`. Requires root — run once per
# machine (via MDM/provisioning), not per repo.
#
# This does NOT start a background service — git invokes hooks on demand,
# same as always, just from one shared root-owned location instead of a
# per-repo copy. There is nothing to keep running.
#
# Real limitation, stated once: a repo's own LOCAL git config (or
# `--no-verify`) always overrides this default — that's how git works,
# not a bug here. `init.templateDir` below is a second, redundant layer
# for that case; the actual backstop past both is CI (see
# references/enforcement.md). This script raises the bar for a developer
# who isn't deliberately working around it; it cannot stop one who is,
# if that developer has root on this machine.
#
# Usage: sudo sh install-global.sh [target-dir]   (default: /opt/smart-commit)

set -eu

# SC_ASSUME_ROOT=1 escape hatch: `id -u` is reliable on macOS/Linux but
# not guaranteed under Git Bash on Windows even when run as SYSTEM via a
# Scheduled Task. Used by deploy/linux/local-test.sh for non-root test
# runs; if a Windows deploy is added later, verify it on a real Windows
# machine before relying on it — don't set it anywhere else.
if [ "${SC_ASSUME_ROOT:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo "error: run as root — this writes system git config and a root-owned directory." >&2
    exit 1
fi

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)
TARGET=${1:-/opt/smart-commit}

mkdir -p "$TARGET/githooks" "$TARGET/config" "$TARGET/git-template/hooks"

for f in "$SKILL_DIR"/githooks/*; do
    cp "$f" "$TARGET/githooks/$(basename "$f")"
done
for f in "$SKILL_DIR"/scripts/*.sh; do
    base=$(basename "$f")
    case "$base" in
        install-git-hooks.sh|install-global.sh|verify-hooks-installed.sh) continue ;;
    esac
    cp "$f" "$TARGET/githooks/$base"
done
find "$TARGET/githooks" -type f -exec chmod 755 {} +

# config/ is seeded once, then owned by whoever administers this machine —
# re-running this script never overwrites a customized policy.
for f in "$SKILL_DIR"/config/*; do
    base=$(basename "$f")
    [ -f "$TARGET/config/$base" ] || cp "$f" "$TARGET/config/$base"
done
chmod 644 "$TARGET"/config/*

# Redundant fallback: if a specific repo's local config unsets
# core.hooksPath, `git init`/`git clone` still pre-populate .git/hooks/
# from this template. (Runs with default policy values in that case —
# it can't find $TARGET/config from inside .git/hooks/ — better than
# nothing, not equivalent to the primary path.)
cp "$TARGET"/githooks/* "$TARGET/git-template/hooks/"

chown -R root:root "$TARGET" 2>/dev/null || chown -R root:wheel "$TARGET" 2>/dev/null || true
chmod -R go-w "$TARGET"

git config --system core.hooksPath "$TARGET/githooks"
git config --system init.templateDir "$TARGET/git-template"

echo "Installed machine-wide git guardrails at $TARGET (root-owned)."
echo "core.hooksPath (system) -> $TARGET/githooks"
echo "init.templateDir (system) -> $TARGET/git-template"
echo "Every repo on this machine is now protected without a per-repo step."
echo "Edit $TARGET/config/organization-policy.yml to tune policy for this machine."
