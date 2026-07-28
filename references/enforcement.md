# Git Guardrail Enforcement — Org Rollout Guide

## Why this exists

A skill is probabilistic — nothing forces compliance, and a bare-terminal
`git commit -m "wip"` never touches Claude at all. Enforcement outside the
model is required. This is defense in depth: the skill makes the good
path easy, each layer below makes the bad path harder until it's blocked.
Covers both commit time and push time (Layer 3.5) — a bad message or
secret is caught the same way either way; push-only concerns (protected
branches, force-push, lockfile/migration/docs drift, lint) are caught
before code leaves the machine.

## The layers

| # | Layer | Scope | Guarantees | Bypassable by |
|---|-------|-------|---------------------|----------------|
| 1 | `smart-commit` skill | Claude only | Clean, atomic commits; never force-pushes/bypasses on its own initiative | Not loading; a human in a terminal |
| 2 | `claude-commit-gate.sh` / `claude-push-gate.sh` | Claude only | Fast self-correction before a bad commit/push runs | See below — not a hard block |
| 3 | `commit-msg` + `pre-commit` (`core.hooksPath`) | Every commit, any tool | Blocks bad message / secrets / denylisted / oversized files | `--no-verify`, `-n`, `-c core.hooksPath=`, fresh clone before setup |
| 3.5 | `pre-push` | Every push, any tool | Re-runs Layer 3 over the full push range + branch protection + drift/lint checks | Same as Layer 3 |
| 4 | CI (commitlint + gitleaks) | Every PR | No bad commit reaches `main` — catches Layer 3/3.5 bypasses | Nothing that merges normally |
| 5 | Host branch protection / pre-receive | Repo/server-wide | Varies by host | Varies by host |

Layers 1–2 make the good path easy; 3–5 make the bad path hard, then
impossible. Layer 3 is the only layer that's local, tool-agnostic, and
host-agnostic — it fires before a commit object even exists, identically
on GitHub Cloud or Enterprise Server. Layer 5 is a separate question:
whether a commit that got past Layer 3 (e.g. via `--no-verify`) can still
be pushed or merged.

## The anti-drift core

All message rules live in one place, [`scripts/validate-commit-msg.sh`](../scripts/validate-commit-msg.sh):

```
        scripts/validate-commit-msg.sh   ← THE ONLY RULES. Everything calls this.
         /              |
claude-commit-gate.sh   githooks/commit-msg
```

CI's `commitlint` config is the one place rules are necessarily
re-expressed (JS, not shell). **Re-check both by hand after editing
either** — a past drift bug (`subject-min-length` vs `header-min-length`,
see the comment atop `ci-templates/commitlint.config.js`) came from
exactly this. Everything beyond message rules — denylisting, secrets,
branch protection, drift checks, lint — has its own single source:
[`scripts/common.sh`](../scripts/common.sh), sourced by every
`validate-*.sh` and both Claude gates (config loading, branch checks,
file listing, `sc_deny()`).

## The config layer

Tunable from [`config/organization-policy.yml`](../config/organization-policy.yml)
(protected branches, size limit, scanners/lint, block/warn/off per
check), plus `denylist.conf`/`allowlist.conf`/`extensions.conf` for path
patterns. Format is deliberately restrictive (flat YAML, POSIX globs) —
see each file's header before adding anything nested.

**Idempotency:** `install-git-hooks.sh` always overwrites `githooks/*`
and `scripts/*.sh` (org-vendored) but only seeds `config/*` if missing —
re-running it never wipes a team's policy customization.

## Layer 3.5 — pre-push: what runs and why

Re-runs Layer 3's content checks over the full push range, plus:

| Script | Checks | Enforcement |
|---|---|---|
| `validate-branch.sh` | Protected-branch rejection; `<type>/kebab-case-description` naming for a brand-new branch's first push only | Protection always blocks; naming per `enforce_branch_naming` |
| `validate-generated-files.sh` | Stale proto/OpenAPI codegen | `organization-policy.yml` |
| `validate-language.sh` | Lint/format only, graceful-skip if missing | `enable_lint` |
| `validate-docs.sh` | Surface change without a docs touch | `organization-policy.yml` |
| `validate-api.sh` | Removed proto field/message, removed API path | `organization-policy.yml` |
| `validate-migrations.sh` | Unpaired up/down, editing a merged migration | `organization-policy.yml` |
| `validate-lockfiles.sh` | Manifest changed, lockfile didn't | `organization-policy.yml` |

**Branch naming only applies once, at first push, never retroactively** —
enforcing it on every push of an already-existing branch would break a
team's pre-existing names the day this ships. `githooks/post-checkout`
gives the same warning earlier and non-blocking, right when the branch
is created (before it has an upstream) — never a gate, since git has no
pre-branch-creation hook to gate at.

**No build, test, or coverage anywhere in this system** — a scope
decision: it would make every push toolchain-dependent and slow enough
that developers route around it. CI runs the authoritative build/test;
this system catches cheap, universal mistakes before code leaves the
machine. A repo wanting a local build/test gate should add it as an
explicit opt-in, not inherit it by default. Same reasoning excludes
`cargo clippy` (needs a compile) while keeping `cargo fmt --check`
(doesn't).

**Blockchain checks are always-on, not a mode.** Validator/wallet key
filenames are hard-blocked in `denylist.conf` for every repo; node-home
config (`genesis.json`, `config.toml`, `app.toml`) is warn-tier. They
never fire in a non-blockchain repo — no toggle to remember.

## Layer 2 — wiring the Claude hook, and its known limits

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "if": "Bash(git *)", "command": "${CLAUDE_PROJECT_DIR}/.githooks/claude-commit-gate.sh" },
        { "type": "command", "if": "Bash(git *)", "command": "${CLAUDE_PROJECT_DIR}/.githooks/claude-push-gate.sh" }
      ]}
    ]
  }
}
```

Also at [`examples/settings.json.snippet`](../examples/settings.json.snippet).
Both scripts are copied automatically by whichever installer ran (global
or per-repo — see Layer 3). Matched on `Bash(git *)`, not `Bash(git commit *)` — a narrower pattern
misses a bypass like `git -c core.hooksPath=/dev/null commit ...`, where
`-c ...` sits between `git` and the subcommand. Each script exits 0 if
the command isn't its subcommand, so this costs one extra fast
invocation per `git` call, not per relevant one.

**Two confirmed Claude Code bugs are why Layer 2 is fast feedback, never
the guarantee:**

1. **[#18312](https://github.com/anthropics/claude-code/issues/18312)** —
   when `Bash` is in `permissions.allow`, a hook's JSON `"deny"` is
   silently ignored. Mitigation: block via **exit code 2** instead, which
   isn't affected by this bug.
2. **[#24327](https://github.com/anthropics/claude-code/issues/24327)** —
   Claude sometimes misreads an exit-2 block as a user denial and stops
   instead of retrying. Mitigation: explicit stderr directive ("not a
   user denial... do NOT stop"). The bug reporter who originated this
   text called it "sometimes works, but unreliably" — it helps, it isn't
   guaranteed. If Claude stops anyway, tell it to retry; the block held.

Both mitigations live in `sc_deny()` in `common.sh`, called by both
gates — one fix point, not two. The one exception:
`claude-push-gate.sh`'s force-push check passes the *opposite* directive
("stop and ask the user") — the one case in this system where retrying
without confirmation is the wrong outcome.

## Layer 3 — installing local git hooks

**Machine-wide is the default (primary path):**

```bash
sudo sh scripts/install-global.sh   # once per machine, via MDM/provisioning
```

Sets `git config --system core.hooksPath` to a root-owned, shared
directory (default `/opt/smart-commit/githooks`) plus `init.templateDir`
as a redundant fallback for the case a specific repo's local config
unsets `core.hooksPath` (that fallback runs with default policy values,
since it can't resolve the real `config/` from inside `.git/hooks/` —
degraded but safe, not equivalent to the primary path). No developer
action, no `.githooks/` to commit, nothing per-repo.

**Per-repo is the fallback**, used automatically by SKILL.md's Step 0
only when a machine has no global protection (so a repo is never left
unprotected just because a machine wasn't provisioned yet):

```bash
sh scripts/install-git-hooks.sh /path/to/target-repo
```

Copies `githooks/*` and `scripts/*.sh` (except both installers and
`verify-hooks-installed.sh`) flat into `<repo>/.githooks/` — hooks find
siblings via `$(dirname "$0")`, so everything must live in one directory.
Seeds `config/*` only if missing, sets `core.hooksPath .githooks`
(repo-local). Commit `.githooks/` including `.githooks/config/` if using
this path intentionally.

**Either way, the actual backstop for a machine that was never
provisioned and a repo that never got the fallback is Layer 4** — CI
re-validates independent of any local configuration, so skipping both
local layers only delays the catch to the PR, never lets it merge
silently.

**Node-only repos** may prefer `husky` + `commitlint` instead:

```bash
npm install --save-dev husky @commitlint/cli @commitlint/config-conventional
npx husky init
echo "npx --no -- commitlint --edit \$1" > .husky/commit-msg
```

## Layer 4 — CI

Copy [`ci-templates/github-actions.yml`](../ci-templates/github-actions.yml)
to `.github/workflows/commit-checks.yml` and
[`ci-templates/commitlint.config.js`](../ci-templates/commitlint.config.js)
to the repo root. Two jobs, named stably since Layer 5a references them:

1. **`commitlint`** — lints every commit on the PR range, closing the
   `--no-verify`/never-ran-setup holes.
2. **`gitleaks`** — unconditional scan, no graceful-skip. Uses the free
   CLI directly; `gitleaks-action@v3` needs a paid license for org
   accounts, so it's opt-in, not default.

## Layer 5 — pick your host

### 5a — GitHub Cloud

No push-time rejection exists — the strongest gate is a required-status-
check branch protection ruleset (`commitlint` + `gitleaks`), applied
org-wide by default. Honest wording: "no bad commit reaches `main`," not
"can be pushed" — a bad commit can still exist on a feature branch.

### 5b — GitHub Enterprise Server

The only host with a true push-time gate: a pre-receive hook, server-
side, cannot be bypassed client-side. Walk `git rev-list old..new`,
validate each subject, reject the push on any failure. Constraint: all
pre-receive hooks share a **5-second total timeout** — an external
`gitleaks` call per push could approach that budget, so a server-side
rollout should likely use the regex-fallback layer only. Not built in
this pass — a future extension point. With it, the wording becomes the
literal promise: no bad commit can be pushed.

## Bypass policy

- `--no-verify`/`-n`/`-c core.hooksPath=`: blocked outright for
  Claude-driven commits/pushes (Layer 2). For a human in a terminal,
  these bypass Layers 3/3.5 by design — caught at Layer 4 (Cloud) or
  blocked at Layer 5b (Enterprise Server).
- `--force`/`--force-with-lease` to a **protected branch**: blocked
  outright for Claude, no exception. To a non-protected branch: Layer 2
  blocks the first attempt, but can't verify "the user actually asked" —
  that's a Claude-side rule (SKILL.md Step 7), not something a hook can
  check. A human is never restricted from force-pushing their own
  non-protected branch; that's normal git.
- Layer 5a bypass: a repo admin can override a required check on merge —
  a deliberate, logged decision, not a silent gap.

## What this does not do

- No commitizen/interactive prompts, no GPG signing (recommended
  follow-up), no `scope-enum` lockdown (extend `commitlint.config.js`
  per-repo if wanted).
- No build/test/coverage anywhere (see Layer 3.5) — CI is authoritative.
- No monorepo support for nested manifests — `validate-language.sh` and
  `validate-lockfiles.sh` check the repo root only.
- No real proto/OpenAPI compatibility tool — `validate-api.sh` and
  `validate-generated-files.sh` are structural heuristics, not `buf
  breaking`/`openapi-diff`. Wire one in behind `enforce_api_check` once
  the org standardizes on a toolchain.
