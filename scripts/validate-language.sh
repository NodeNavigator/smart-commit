#!/bin/sh
# validate-language.sh — per-language LINT + FORMAT dispatch only, no
# build/test (`cargo clippy` excluded — needs a compile; `cargo fmt
# --check` included — doesn't). Detects language by manifest at the repo
# root only (monorepos: extend this or use per-package CI). Every tool
# graceful-skips with a warning if not installed — CI is authoritative.
# Set `enable_lint: false` in organization-policy.yml to disable.
#
# SECURITY: this runs as a machine-wide hook in EVERY repo, including ones a
# developer just cloned. It therefore never executes repo-shipped wrapper
# scripts (./mvnw, ./gradlew) — those are trivially trojaned. Linters are still
# resolved from PATH / node_modules (established by an npm install you ran), and
# note that linters read repo config (eslint.config.js, pom.xml, …) which is
# itself repo-controlled — so a fleet that reviews untrusted repos should set
# `enable_lint: false` and rely on CI's sandboxed run. Filenames are ./-prefixed
# before being handed to tools so a crafted name like `--config=…` can't be read
# as an option (argument injection).
#
# Usage: validate-language.sh [git-range]   # no arg = staged files
# Exit 0 = clean/skipped. Exit 1 = a tool reported real issues.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

[ "$SC_ENABLE_LINT" = "true" ] || exit 0

# Prefix every path with ./ so a filename beginning with '-' is passed to a tool
# as a path, never as an option. Paths from git are always repo-relative.
sc_safe_paths() { sed 's#^#./#'; }

if [ -n "${1:-}" ]; then
    files=$(sc_changed_files_in_range "$1")
else
    files=$(sc_staged_files)
fi
[ -z "$files" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
existing_files=$(printf '%s\n' "$files" | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done)
[ -z "$existing_files" ] && exit 0

fail=0

# --- Go ---------------------------------------------------------------
go_files=$(printf '%s\n' "$existing_files" | grep '\.go$' || true)
if [ -n "$go_files" ] && [ -f "$REPO_ROOT/go.mod" ]; then
    if command -v gofmt >/dev/null 2>&1; then
        unformatted=$(printf '%s\n' "$go_files" | sc_safe_paths | xargs gofmt -l 2>/dev/null)
        if [ -n "$unformatted" ]; then
            sc_log_fail "gofmt: the following files need formatting (run: gofmt -w):
$unformatted"
            fail=1
        fi
    else
        sc_log_warn "gofmt not found — Go formatting check skipped locally"
    fi

    if command -v golangci-lint >/dev/null 2>&1; then
        go_dirs=$(printf '%s\n' "$go_files" | sc_safe_paths | xargs -n1 dirname 2>/dev/null | sort -u)
        if ! printf '%s\n' "$go_dirs" | xargs golangci-lint run --timeout=2m 2>&1 | sed 's/^/golangci-lint: /' >&2; then
            fail=1
        fi
    else
        sc_log_warn "golangci-lint not found — Go lint skipped locally"
    fi
fi

# --- Node / TypeScript / JavaScript ------------------------------------
js_files=$(printf '%s\n' "$existing_files" | grep -E '\.(js|jsx|ts|tsx)$' || true)
if [ -n "$js_files" ] && [ -f "$REPO_ROOT/package.json" ]; then
    eslint_bin=""
    if [ -x "$REPO_ROOT/node_modules/.bin/eslint" ]; then
        eslint_bin="$REPO_ROOT/node_modules/.bin/eslint"
    elif command -v eslint >/dev/null 2>&1; then
        eslint_bin="eslint"
    fi
    if [ -n "$eslint_bin" ]; then
        if ! printf '%s\n' "$js_files" | sc_safe_paths | xargs "$eslint_bin" --max-warnings=0 2>&1 | sed 's/^/eslint: /' >&2; then
            fail=1
        fi
    else
        sc_log_warn "eslint not found — JS/TS lint skipped locally"
    fi

    prettier_bin=""
    if [ -x "$REPO_ROOT/node_modules/.bin/prettier" ]; then
        prettier_bin="$REPO_ROOT/node_modules/.bin/prettier"
    elif command -v prettier >/dev/null 2>&1; then
        prettier_bin="prettier"
    fi
    if [ -n "$prettier_bin" ]; then
        unformatted=$(printf '%s\n' "$js_files" | sc_safe_paths | xargs "$prettier_bin" --list-different 2>/dev/null)
        if [ -n "$unformatted" ]; then
            sc_log_fail "prettier: the following files need formatting:
$unformatted"
            fail=1
        fi
    else
        sc_log_warn "prettier not found — JS/TS format check skipped locally"
    fi

    ts_files=$(printf '%s\n' "$js_files" | grep -E '\.tsx?$' || true)
    if [ -n "$ts_files" ] && [ -f "$REPO_ROOT/tsconfig.json" ]; then
        tsc_bin=""
        if [ -x "$REPO_ROOT/node_modules/.bin/tsc" ]; then
            tsc_bin="$REPO_ROOT/node_modules/.bin/tsc"
        elif command -v tsc >/dev/null 2>&1; then
            tsc_bin="tsc"
        fi
        if [ -n "$tsc_bin" ]; then
            if ! (cd "$REPO_ROOT" && "$tsc_bin" --noEmit) 2>&1 | sed 's/^/tsc: /' >&2; then
                fail=1
            fi
        else
            sc_log_warn "tsc not found — TypeScript type check skipped locally"
        fi
    fi
fi

# --- Python --------------------------------------------------------------
py_files=$(printf '%s\n' "$existing_files" | grep '\.py$' || true)
if [ -n "$py_files" ] && { [ -f "$REPO_ROOT/pyproject.toml" ] || [ -f "$REPO_ROOT/setup.py" ] || [ -f "$REPO_ROOT/requirements.txt" ]; }; then
    if command -v black >/dev/null 2>&1; then
        if ! printf '%s\n' "$py_files" | sc_safe_paths | xargs black --check --diff 2>&1 | sed 's/^/black: /' >&2; then
            fail=1
        fi
    else
        sc_log_warn "black not found — Python format check skipped locally"
    fi

    if command -v ruff >/dev/null 2>&1; then
        if ! printf '%s\n' "$py_files" | sc_safe_paths | xargs ruff check 2>&1 | sed 's/^/ruff: /' >&2; then
            fail=1
        fi
    else
        sc_log_warn "ruff not found — Python lint skipped locally"
    fi
fi

# --- Rust (format only — clippy needs a compile, out of scope) -----------
rs_files=$(printf '%s\n' "$existing_files" | grep '\.rs$' || true)
if [ -n "$rs_files" ] && [ -f "$REPO_ROOT/Cargo.toml" ]; then
    if command -v cargo >/dev/null 2>&1; then
        if ! (cd "$REPO_ROOT" && cargo fmt --check) 2>&1 | sed 's/^/cargo fmt: /' >&2; then
            fail=1
        fi
    else
        sc_log_warn "cargo not found — Rust format check skipped locally"
    fi
fi

# --- Java (Spotless format check only) -----------------------------------
# PATH-resolved mvn/gradle ONLY — never the repo's ./mvnw or ./gradlew wrapper
# scripts, which are repo-controlled and would execute attacker code in a cloned
# repo. If the tool isn't on PATH, skip (CI is authoritative).
if [ -n "$(printf '%s\n' "$existing_files" | grep '\.java$' || true)" ]; then
    if [ -f "$REPO_ROOT/pom.xml" ]; then
        if command -v mvn >/dev/null 2>&1; then
            if ! (cd "$REPO_ROOT" && mvn -q spotless:check) 2>&1 | sed 's/^/spotless: /' >&2; then
                fail=1
            fi
        else
            sc_log_warn "mvn not on PATH — Java format check skipped (repo ./mvnw is not run, for safety; CI is authoritative)"
        fi
    elif ls "$REPO_ROOT"/build.gradle* >/dev/null 2>&1; then
        if command -v gradle >/dev/null 2>&1; then
            if ! (cd "$REPO_ROOT" && gradle -q spotlessCheck) 2>&1 | sed 's/^/spotless: /' >&2; then
                fail=1
            fi
        else
            sc_log_warn "gradle not on PATH — Java format check skipped (repo ./gradlew is not run, for safety; CI is authoritative)"
        fi
    fi
fi

# --- PHP (best-effort — not detailed in the org spec, wired for parity) --
php_files=$(printf '%s\n' "$existing_files" | grep '\.php$' || true)
if [ -n "$php_files" ] && [ -f "$REPO_ROOT/composer.json" ]; then
    if command -v phpcs >/dev/null 2>&1; then
        if ! printf '%s\n' "$php_files" | sc_safe_paths | xargs phpcs 2>&1 | sed 's/^/phpcs: /' >&2; then
            fail=1
        fi
    else
        sc_log_warn "phpcs not found — PHP lint skipped locally"
    fi
fi

exit "$fail"
