// commitlint.config.js — CI-side (Layer 4) mirror of
// ../scripts/validate-commit-msg.sh. This is the one place these rules are
// necessarily re-expressed, since commitlint is JS config, not a shell
// script the validator could be called from directly. Keep this and the
// validator in lockstep — references/enforcement.md documents the
// config-parity test that catches drift between them.
//
// Not expressible here: the validator's whole-subject junk-word ban
// (bare "fix", "wip", "update", ...) has no commitlint equivalent, but it
// doesn't need one — a bare word with no colon has no parseable type or
// subject, so @commitlint/config-conventional's default `type-empty` and
// `subject-empty` rules already reject it, just via a different mechanism.
// The config-parity test confirms both implementations agree on outcome.
//
// Deliberately `header-min-length`, not `subject-min-length`: commitlint's
// "subject" is only the text after the colon, but the validator's length
// check (matching the original "no message under 10 chars" rule) measures
// the WHOLE header line. Using subject-min-length here was a real bug the
// parity test caught — "fix: handle it" passed the validator (14 chars)
// but failed commitlint (subject "handle it" alone is 9). header-min-length
// measures the same thing the validator does.
//
// Copy this file to the target repo's root (or reference it via `extends`
// from a repo-local commitlint.config.js) and run:
//   npx commitlint --from <base-sha> --to <head-sha>
// in CI — see ci-templates/github-actions.yml.
module.exports = {
  extends: ['@commitlint/config-conventional'],
  defaultIgnores: true, // Merge/Revert/fixup!/squash! pass-throughs — explicit for visibility
  rules: {
    'type-enum': [
      2,
      'always',
      ['feat', 'fix', 'refactor', 'perf', 'docs', 'test', 'style', 'chore', 'build', 'ci', 'revert'],
    ],
    'header-max-length': [2, 'always', 72],
    'header-min-length': [2, 'always', 10],
  },
};
