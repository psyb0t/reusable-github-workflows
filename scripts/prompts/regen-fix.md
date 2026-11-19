An automated validation failed in this repository. Fix the root cause so both
generation (`{{GENERATE_COMMAND}}`) and checks (`{{CHECK_COMMANDS}}`) pass.
Either command may be disabled by an empty string or "-". The failure may be
generation, dependencies, compilation, lint, tests, security scanning or a
rejected prior repair. This is attempt {{ATTEMPT}} of {{MAX_ATTEMPTS}}.
{{SYNC_NOTE}}

Context files under /context:
- check-output.log: output of the latest failing check run. Start here.
- diff-stat.txt and diff.patch: everything changed against the last commit
  so far, the regeneration plus any earlier fix attempts.
- history/check-0.log: the first failure, right after regeneration.
- writing-rules.md: rules for every word you write. Follow them.
{{EARLIER_ATTEMPTS}}

Before you change anything:
1. Read AGENTS.md and every file under .agents/rules/ in the checkout, plus any
   README.md or docs they point to. They are the repository's own standards.
   Follow them for naming, error handling, logging, layout, comments and
   tooling. Match the style of the surrounding code.
2. Use the repository's own tooling, the Make targets listed in AGENTS.md or
   `make help` (for example make generate, make dep, make lint, make test,
   make sec, make pkg-update). Do not run a toolchain directly when a Make
   target does the job. Change dependencies only through those targets.
3. Find the root cause in check-output.log.

How to fix:
- Generated files are overwritten on the next run. Fix the cause at its
  source: the spec patch scripts, the generator config, hand-written code,
  pinned versions in the Dockerfiles, or a dependency bump. Regenerate with the
  repository's generate target afterwards when your fix changes generator
  input.
- Do not weaken the checks. Never add skips or suppressions (t.Skip, nolint,
  nosemgrep, gitleaks:allow, #nosec, noqa, eslint-disable, shellcheck
  disable). Never delete or loosen a test to make it pass. The workflow
  rejects these.
- Security findings require a real fix, such as a patched toolchain or
  dependency. Do not disable scanners, omit checks, reduce their scope, lower
  thresholds, remove functionality or edit schemas to hide a finding. Generated
  headers do not exempt a suppression. Preserve the upstream API contract.
- Only use official provider-controlled API and specification sources. Never
  invent a URL or substitute a third-party mirror. For a new URL, verify its
  provenance in the provider's own documentation or repository. The guard also
  requires that exact URL to be pre-approved by the caller; the approved
  additions are listed below. Existing repository URLs remain permitted.
  If no official source is available, or the necessary replacement is not
  approved, stop with a concise blocker and evidence for the failure issue.
  Do not fake successful generation by reusing stale output or a cached spec.
- Never edit the protected paths listed at the end of this task. The
  workflow rejects any change to them, including the changelog and version
  files, which it writes itself.
- No attribution anywhere: no comment, string or file may say it was written,
  generated or fixed by Claude, Claude Code, Anthropic or any AI tool.
- Run the failing checks yourself until they pass. Leave no stray files behind.
- Do not commit, tag or push.

When you are done, reply with a short plain summary of what you changed and
why, as "- " bullet lines, following writing-rules.md. If you could not fix it,
say what blocks it.

Protected paths (globs, * also matches across directories):
{{PROTECTED_PATHS}}

Caller-approved additional official URLs:
{{OFFICIAL_SOURCE_URLS}}
