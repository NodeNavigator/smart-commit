#!/bin/sh
# validate-secrets.sh — content-based secret scan. Wraps gitleaks/
# trufflehog/git-secrets when enabled+installed, plus an always-on regex
# fallback for classes those scanners may miss (blockchain private keys,
# Tendermint/CometBFT key armor, and common SaaS API key formats —
# Google/GitHub/Stripe/Razorpay/Slack/Discord/OpenAI, per
# added on top of what was already here — AWS and generic PEM private
# keys were already covered below, so only the genuinely new patterns
# from that article were added). Filename-based blockchain detection
# (keystores, *.mnemonic) lives in validate-files.sh instead.
#
# Usage: validate-secrets.sh [git-range]   # no arg = staged files
# Exit 0 = clean. Exit 1 = a secret was found.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

if [ -n "${1:-}" ]; then
    range="$1"
    files=$(sc_changed_files_in_range "$range")
else
    range=""
    files=$(sc_staged_files)
fi

fail=0

# Graceful-skip if a scanner isn't installed — CI runs gitleaks
# unconditionally, so a missing local binary only delays the catch.
if [ "$SC_ENABLE_GITLEAKS" = "true" ]; then
    if command -v gitleaks >/dev/null 2>&1; then
        if [ -n "$range" ]; then
            gitleaks detect --source . --log-opts="$range" -v || fail=1
        else
            gitleaks protect --staged -v || fail=1
        fi
    else
        sc_log_warn "gitleaks not installed — secret scan skipped locally (CI will still catch this)"
    fi
fi

if [ "$SC_ENABLE_TRUFFLEHOG" = "true" ]; then
    if command -v trufflehog >/dev/null 2>&1; then
        trufflehog filesystem --directory . --fail --no-update || fail=1
    else
        sc_log_warn "trufflehog enabled in policy but not installed — skipped locally"
    fi
fi

if [ "$SC_ENABLE_GIT_SECRETS" = "true" ]; then
    if command -v git-secrets >/dev/null 2>&1; then
        git secrets --scan || fail=1
    else
        sc_log_warn "git-secrets enabled in policy but not installed — skipped locally"
    fi
fi

if [ -n "$files" ]; then
    scan_pattern() {
        # scan_pattern <label> <extended-regex> <file>
        label=$1; pattern=$2; f=$3
        [ -f "$f" ] || return 0
        grep -Iq -- . "$f" 2>/dev/null || return 0  # skip binaries/empty files
        # Honor an inline allow marker so pattern-definition lines (this
        # script scans itself when staged) and legit test fixtures/docs
        # can opt out — same idea as gitleaks' `# gitleaks:allow`.
        line=$(grep -nE -- "$pattern" "$f" 2>/dev/null | grep -v 'sc-secrets:allow' | head -n 1 | cut -d: -f1)
        if [ -n "$line" ]; then
            sc_log_fail "$f:$line looks like a $label"
            return 1
        fi
        return 0
    }

    result=$(printf '%s\n' "$files" | while IFS= read -r f; do
        [ -z "$f" ] && continue
        scan_pattern "AWS access key ID" 'AKIA[0-9A-Z]{16}' "$f" || printf 'BLOCK\n'
        scan_pattern "PEM-format private key" '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$f" || printf 'BLOCK\n'
        scan_pattern "Tendermint/CometBFT validator key" '-----BEGIN TENDERMINT PRIVATE KEY-----' "$f" || printf 'BLOCK\n'  # sc-secrets:allow
        scan_pattern "JWT" 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' "$f" || printf 'BLOCK\n'
        scan_pattern "database URL with embedded credentials" '(postgres|postgresql|mysql|mongodb(\+srv)?)://[^:/ ]+:[^@/ ]+@' "$f" || printf 'BLOCK\n'
        scan_pattern "raw hex private key (Ethereum-style)" '(^|[^0-9a-fA-F])0x[0-9a-fA-F]{64}([^0-9a-fA-F]|$)' "$f" || printf 'BLOCK\n'
        scan_pattern "GCP service account private key" '"private_key"[[:space:]]*:[[:space:]]*"-----BEGIN' "$f" || printf 'BLOCK\n'
        scan_pattern "Azure storage connection string" 'DefaultEndpointsProtocol=https?;AccountName=' "$f" || printf 'BLOCK\n'
        scan_pattern "Google API key" 'AIza[0-9A-Za-z_-]{35}' "$f" || printf 'BLOCK\n'
        scan_pattern "GitHub personal access token" 'ghp_[0-9A-Za-z]{36}' "$f" || printf 'BLOCK\n'
        scan_pattern "Stripe live secret key" 'sk_live_[0-9a-zA-Z]{24,}' "$f" || printf 'BLOCK\n'
        scan_pattern "Stripe test secret key" 'sk_test_[0-9a-zA-Z]{24,}' "$f" || printf 'BLOCK\n'
        scan_pattern "Razorpay live key" 'rzp_live_[0-9A-Za-z]{14}' "$f" || printf 'BLOCK\n'
        scan_pattern "Razorpay test key" 'rzp_test_[0-9A-Za-z]{14}' "$f" || printf 'BLOCK\n'
        scan_pattern "Slack bot token" 'xoxb-[0-9]{10,13}-[0-9]{10,13}-[0-9A-Za-z]{24}' "$f" || printf 'BLOCK\n'
        scan_pattern "Discord bot token" '[MN][A-Za-z0-9]{23,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27}' "$f" || printf 'BLOCK\n'
        scan_pattern "OpenAI API key" 'sk-[0-9A-Za-z]{48}' "$f" || printf 'BLOCK\n'
    done)

    count=$(printf '%s\n' "$result" | grep -c '^BLOCK$')
    [ "$count" -gt 0 ] && fail=1
fi

[ "$fail" -eq 1 ] && exit 1
exit 0
