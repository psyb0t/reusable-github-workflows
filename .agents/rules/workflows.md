# Workflows

These conventions come from the existing workflows and the "Shared conventions" section of `README.md`.

- **WF1** Pin every third-party action by its full commit SHA, with the version in a trailing comment, as `actions/checkout@<sha> # v6.0.3`.
- **WF2** Set top-level `permissions: {}` and give each job only the scopes it needs. A reusable job cannot ask for more than the caller grants, so a new scope is a breaking change for callers.
- **WF3** Keep concurrency groups keyed by workflow, event, and ref, so a scheduled or manual run never cancels the push run a tag release waits for.
- **WF4** Network operations retry with exponential backoff. Expose the policy as `max_attempts` and `backoff_seconds` inputs, as `archive.yml` and `code-workflow.yml` do.
- **WF5** Pass caller-controlled strings to shell steps through `env:`, not by pasting `${{ inputs.* }}` into the script text.
- **WF6** A command input accepts `-` or an empty string to skip its step.
- **WF7** Every input change updates that workflow's inputs table in `README.md`, and every behavior change gets a `CHANGELOG.md` entry that says what a caller sees and whether a caller needs to change anything.
- **WF8** Versions follow the pre-1.0 convention at the top of `CHANGELOG.md`: a minor bump may change inputs or behavior and calls it out, a patch bump is docs, build, or fixes only.
- **WF9** Logic longer than a few lines goes in `scripts/` or a tested helper, and every new script or helper gets a test under `tests/` that runs without a token or network.
