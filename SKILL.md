---
name: smart-commit
description: >
  Analyze git changes and produce clean, atomic, Conventional Commits.
  Activate on any commit/push intent — "commit this", "push it", "save my
  work", "commit and push", "/commit". Do NOT activate on bare "done" or
  "finished" alone (code-hygiene handles those, before this skill runs).
  Backed by a deterministic hook system — see references/enforcement.md.
allowed-tools: Bash(git status *) Bash(git diff *) Bash(git log *) Bash(git branch *) Bash(git config *) Bash(git add *) Bash(git commit *) Bash(git push *) Bash(sh ${CLAUDE_SKILL_DIR}/scripts/install-git-hooks.sh *) Bash(mkdir -p .github/workflows) Bash(cp ${CLAUDE_SKILL_DIR}/ci-templates/* *)
---

# Smart Commit

Analyze the working tree, catch what shouldn't be committed, group changes
into atomic units, and commit with Conventional Commits format. **Never
pass `--no-verify`, `-n`, or `-c core.hooksPath=`.** If a hook rejects a
commit, fix the issue and retry — it's a quality gate, not a denial.

## Step 0 — Confirm enforcement is active (first commit in a repo only)

Machine-wide install is the default now — most repos are already
protected via `core.hooksPath` set org-wide (see
[references/enforcement.md](references/enforcement.md)), nothing to do.

Check: does `git config --get core.hooksPath` point to a directory
containing `validate-commit-msg.sh`? (Works whether it's the global path
or a local `.githooks` — don't hardcode a specific path.) If yes, skip
silently. If no hooks are active at all, this machine isn't provisioned
— don't attempt a system-wide install yourself (that needs root and is
an admin/MDM action, not something to run per-repo). Fall back to
per-repo protection so this repo isn't left unprotected, without asking,
then say one line ("no machine-wide protection detected — turned on
per-repo protection for this repo; ask an admin to run
scripts/install-global.sh for full coverage"):

```bash
sh ${CLAUDE_SKILL_DIR}/scripts/install-git-hooks.sh .
```



## Step 0b — Offer Layer 4 CI (once per repo, ask first)

Layer 3 (hooks, above) is machine-wide and self-installing via
`core.hooksPath` — one git config value covers every repo on the
machine. Layer 4 (CI) can't work that way: it only reads a config file
committed inside *this* repo, so no machine-level install reaches it — a
JumpCloud-provisioned machine gets Layer 3 for free and Layer 4 not at
all, per repo, until someone adds it. Layer 4 is also the gate that
`--no-verify` cannot bypass on cloud hosts, so it matters most.

First detect the host — the CI format is host-specific:

```bash
git config --get remote.origin.url
```

`github.com` → GitHub path. `gitlab.com` (or a GitLab host) → GitLab
path. Anything else (Bitbucket, no remote) → don't offer a template;
say one line pointing to `deploy/` for that host and move on.

**GitHub** — check once per repo: does a `.github/workflows/*.yml`
already run `commitlint` or `gitleaks` on `pull_request`, and does
`commitlint.config.js` exist at the repo root? If yes, skip silently.

**GitLab** — check once per repo: does `.gitlab-ci.yml` already define a
job calling `validate-commit-msg.sh` or running `gitleaks`? If yes, skip
silently.

If no — unlike Step 0's hook fallback, this touches CI and is visible to
the whole team, so **ask first**, don't just do it: "this repo has no
PR/MR-time commit + secret check (Layer 4) — want me to add it?" If they
say yes, run the block for the detected host:

GitHub:
```bash
mkdir -p .github/workflows
cp ${CLAUDE_SKILL_DIR}/ci-templates/github-actions.yml .github/workflows/commit-checks.yml
cp ${CLAUDE_SKILL_DIR}/ci-templates/commitlint.config.js .
```

GitLab:
```bash
cp ${CLAUDE_SKILL_DIR}/ci-templates/gitlab-ci.yml .gitlab-ci.yml
```

Commit the file(s) as their own commit (e.g. `ci: add commit and secret
checks`) via the normal Step 1–6 flow, and push only under Step 7's
rules (only if asked, never straight to a protected branch — open a
PR/MR). Then say, once, the manual host-side step that actually turns the
pipeline into a gate — it isn't something to do on the user's behalf:

- **GitHub:** enable `commitlint` + `gitleaks` as **required status
  checks** in Settings → Branches (or Rulesets).
- **GitLab:** the pipeline needs `SMART_COMMIT_REPO` set as a group
  CI/CD variable, plus Settings → Merge requests → **"Pipelines must
  succeed"** turned on, and protected branches configured. On
  Premium/Ultimate also run `deploy/gitlab/apply-push-rules.sh` for the
  server-side, `--no-verify`-proof push gate. Full steps: the GitLab
  section of the root `README.md`'s "Installing — machine-wide" heading,
  or `apply-push-rules.sh`'s own header comments.

The pipeline runs either way, but nothing is enforced until that
host-side step is done.

## Step 1 — Confirm scope, gather context

State in one line what will be committed (e.g. "committing the 3 changed
files in `src/auth/`"). Then run in parallel:

```bash
git status --short
git diff --cached --stat
git diff --cached
git diff --stat
git diff
git log --oneline -10
git branch --show-current
```

Diff >400 lines: use `--stat` first, then `git diff --cached -- <path>`
selectively.

## Step 2 — Pre-commit hygiene check

Scan the diff for blockers before writing a message — matches the
`pre-commit` hook so the skill and hook never disagree.

**Hard blockers — fix first, don't commit:**

| Pattern | Languages | Why |
|---|---|---|
| `console.log(`, `console.error(`, `console.warn(` | JS/TS | Debug artifact |
| `print(`, `pprint(` (non-test, non-logger) | Python | Debug artifact |
| `fmt.Println(`, `fmt.Printf(` (non-test) | Go | Debug artifact |
| `dbg!(`, `println!(` (non-test) | Rust | Debug artifact |
| `debugger;` | JS/TS | Debug breakpoint |
| `TODO`, `FIXME`, `HACK` | Any | Needs an issue ref or removal |
| Hardcoded secrets/keys/tokens/connection strings | Any | Security — hook runs `gitleaks` plus an always-on regex fallback (AWS, PEM keys, JWTs, DB URLs, GCP/Azure creds, and Google/GitHub/Stripe/Razorpay/Slack/Discord/OpenAI key formats — `validate-secrets.sh`) even when `gitleaks` isn't installed |
| `.env` files (except `.env.example`) | Any | Secrets exposure |
| Merge conflict markers (`<<<<<<<` etc.) | Any | Broken code |
| Binary/build artifacts: `dist/`, `build/`, `*.pyc`, `node_modules/` | Any | Belongs in `.gitignore` |
| Files over 5MB | Any | Hook also blocks these |
| Commented-out code (>3 lines) | Any | Delete or keep, not grayed-out |

**Soft warnings — flag, don't block:**

- \>500 lines changed — suggest splitting into multiple commits
- New logic files with no matching test file
- Lock file changed without its manifest changing

The hooks (`validate-*.sh`) also deterministically check blockchain key
files and lockfile/migration/docs drift — full list in
[references/enforcement.md](references/enforcement.md), configurable in
[config/organization-policy.yml](config/organization-policy.yml).

If blockers exist: list each with file/line, stop, don't generate a
commit message.

## Step 3 — Detect issue references

Priority: branch name (`feature/PROJ-123-x` → `Refs: PROJ-123`;
`fix/456-x` → `Closes #456`) → diff content (`#123`) → user's message.
Footer: `Closes #N` / `Refs: KEY-N` / `BREAKING CHANGE: ...` first if
applicable. Omit if nothing found — never invent a number.

If asked to create a branch, name it `<type>/kebab-case-description`
(same types as commit types, e.g. `feat/add-oauth-login`) — enforced on
first push per [config/organization-policy.yml](config/organization-policy.yml)'s
`enforce_branch_naming`. Check that setting before pushing a new branch:
if it's `block` (not the older `warn` default), a non-compliant name
hard-fails the push — get the name right up front rather than pushing
and fixing after a rejection.

## Step 4 — Group into atomic commits

One commit = one logical reason to change.

- Config changes (tsconfig, eslint, package.json) → separate from feature code
- Tests → same commit as the code they test
- Feature / bugfix / refactor / docs / deps → separate commits, matching type

Multiple groups: plan all commits, tell the user, then run them in sequence.

## Step 5 — Write the commit message

```
<type>(<scope>): <short description>

<body — only when WHY isn't obvious>

<footer>
```

**Title:** 10–72 chars, lowercase after the colon, no trailing period,
imperative mood ("add" not "added"), specific
(`fix(auth): handle expired refresh token on mobile`, not `fix: auth bug`).

**Types:** `feat fix refactor perf docs test style chore build ci revert`

**Never propose as the entire subject** (hooks reject these): `fix`,
`update`, `changes`, `wip`, `misc`, `stuff`, `done`, `temp`, `patch`, `hotfix`.

**Body:** only when WHY isn't obvious; wrap at 72 chars; bullets for
multiple changes; explain what + why, not how.

## Step 6 — Commit

Run it directly — don't just print commands for the user to copy. Multiple
commits: one-line note before each, then run in sequence.

```
git commit -m "feat(auth): add OAuth2 PKCE flow for mobile clients

Replaces implicit grant flow, deprecated by RFC 9126. Mobile clients
were silently failing on iOS 17+ due to missing code_verifier support.

Closes #234"
```

**If a hook blocks it:** read stderr, fix the actual issue, retry the
same commit. Don't stop and wait, don't add `--no-verify`.

## Step 7 — Push (only if asked)

Committing ≠ pushing. Only push when the user explicitly said so ("push
it", "commit and push").

- **Never push to a protected branch** — check `protected_branches` in
  [config/organization-policy.yml](config/organization-policy.yml) rather
  than assuming a fixed list (it's per-install and grows over time, e.g.
  an org may add `dev`/`qa`/`testnet` alongside `main`/`master`/
  `production`/`release`) — not even if asked. Open a PR instead.
- **Never construct `--force`/`--force-with-lease` on your own initiative.**
  Only if the user's own message this turn asked for it on this exact
  branch — prefer `--force-with-lease`, never on a protected branch.
- **Never pass `--no-verify`.**

If `pre-push` blocks it: same rule as Step 6 — fix and retry, don't bypass.

## Tone

Direct and fast. Small change → one-line message. Don't explain
Conventional Commits to the developer — just commit correctly.
