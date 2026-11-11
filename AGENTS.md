# Reusable GitHub Workflows

Reusable GitHub Actions workflows that other repositories call with one `uses:` line to get lint, test, scan, build, publish, and release. Callers pin them by branch or tag, so every change here reaches every caller on its next run.

## Layout

- `.github/workflows/`: the reusable workflows, one file each, triggered with `workflow_call`.
- `scripts/`: shell scripts the workflows run, tested on their own.
- `tests/`: Bash and Python tests that need no token or network. Each file names its run command in its header, such as `bash tests/test-release-flow.sh`.
- `README.md`: the shared conventions and one section per workflow, with its inputs table.
- `CHANGELOG.md`: one entry per release, newest first.

## Checks

There is no Makefile. Before a release, run every test under `tests/` with the command its header names, run `actionlint` over the changed workflows, and run `shellcheck` over changed scripts.

## Rules

Rules for every change live in `.agents/rules/`.

| File | Read before touching |
| --- | --- |
| [workflows.md](.agents/rules/workflows.md) | any workflow, script, test, README section, or CHANGELOG entry |
