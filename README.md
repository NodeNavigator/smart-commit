# Smart Commit — Git Guardrail System

An org-wide guardrail that prevents bad commits and pushes from reaching
a shared branch for human developers and Claude Code alike.

## Architecture

```
smart-commit/
├── SKILL.md                    Claude-facing behavior
├── README.md                   this file
├── references/enforcement.md   full layer model + rollout guide
├── githooks/                   TEMPLATES — copied into a machine-wide or per-repo destination
│   ├── pre-commit               runs validate-*.sh against staged files
│   ├── commit-msg                Conventional Commits format
│   ├── prepare-commit-msg        non-blocking template helper (humans only)
│   ├── post-checkout             non-blocking early warning on a bad new branch name
│   ├── pre-merge-commit          runs validate-*.sh on merge commits (pre-commit skips those)
│   └── pre-push                  validate-*.sh + branch protection over the push range
├── scripts/
│   ├── common.sh                  shared: config, branch checks, file listing, hook parsing
│   ├── validate-commit-msg.sh     the ONE place message rules live
│   ├── validate-files.sh          filename/path denylist
│   ├── validate-secrets.sh        content scan: gitleaks/trufflehog/git-secrets + regex fallback
│   ├── validate-branch.sh         protected-branch push rejection + new-branch naming convention
│   ├── validate-generated-files.sh  stale proto/swagger co-change heuristic
│   ├── validate-language.sh       lint + format dispatch (no build/test)
│   ├── validate-docs.sh           docs-drift heuristic
│   ├── validate-api.sh            proto/OpenAPI breaking-change heuristic
│   ├── validate-migrations.sh     up/down pairing + already-merged-migration check
│   ├── validate-lockfiles.sh      manifest/lockfile sync check
│   ├── claude-commit-gate.sh      Claude gate for `git commit`
│   ├── claude-push-gate.sh        Claude gate for `git push`
│   ├── install-global.sh          PRIMARY: one-time, machine-wide rollout (root)
│   ├── install-git-hooks.sh       FALLBACK: per-repo rollout, used when global isn't detected
│   └── verify-hooks-installed.sh  local health check
├── config/                      policy DEFAULTS — seeded once into the install destination's config/
│   ├── organization-policy.yml    master switches
│   ├── denylist.conf               hard-block / warn-tier patterns
│   ├── allowlist.conf              exceptions
│   └── extensions.conf             binary/IDE/OS/generated-file classification
└── examples/                     settings.json snippet, policy example, good/bad messages
```
