#!/bin/sh
# verify-hooks-installed.sh — confirms core.hooksPath points at .githooks
# in THIS checkout. A local dev convenience, not a CI gate — core.hooksPath
# is untracked, so CI's own commitlint job is the real fresh-clone backstop.

set -eu

expected=".githooks"
actual=$(git config --get core.hooksPath || printf '')

if [ "$actual" != "$expected" ]; then
    echo "core.hooksPath is '$actual', expected '$expected'." >&2
    echo "Run scripts/install-git-hooks.sh to enable local commit enforcement." >&2
    exit 1
fi

echo "core.hooksPath correctly set to $expected"
