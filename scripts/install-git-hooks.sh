#!/bin/sh
# install-git-hooks.sh — one-command rollout into a target repo. Idempotent.
#
# Usage: install-git-hooks.sh [path-to-target-repo]   (defaults to cwd)
#
# githooks/* and scripts/*.sh always overwrite (org-vendored). config/*
# copies only if missing — seeded once, then repo-owned; re-running this
# must never wipe a team's policy customization.

set -eu

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd)
TARGET_REPO=${1:-$(pwd)}

if [ ! -d "$TARGET_REPO/.git" ]; then
    echo "error: $TARGET_REPO is not a git repository root" >&2
    exit 1
fi

HOOKS_DEST="$TARGET_REPO/.githooks"
mkdir -p "$HOOKS_DEST/config"

for f in "$SKILL_DIR"/githooks/*; do
    cp "$f" "$HOOKS_DEST/$(basename "$f")"
done
for f in "$SKILL_DIR"/scripts/*.sh; do
    base=$(basename "$f")
    case "$base" in
        install-git-hooks.sh|verify-hooks-installed.sh) continue ;;
    esac
    cp "$f" "$HOOKS_DEST/$base"
done
find "$HOOKS_DEST" -maxdepth 1 -type f -exec chmod +x {} +

for f in "$SKILL_DIR"/config/*; do
    base=$(basename "$f")
    if [ ! -f "$HOOKS_DEST/config/$base" ]; then
        cp "$f" "$HOOKS_DEST/config/$base"
    fi
done

git -C "$TARGET_REPO" config core.hooksPath .githooks

echo "Installed git hooks into $HOOKS_DEST (core.hooksPath set)."
echo "Commit .githooks/ including config/. See references/enforcement.md"
echo "for the fresh-clone bootstrap step and CI wiring."
