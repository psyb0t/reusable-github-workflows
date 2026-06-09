# Changelog

All notable changes per release. Versions follow [semver](https://semver.org)
pre-1.0 conventions: minor bumps may include breaking input/behavior changes
(called out explicitly), patch bumps are docs / build / fixes only.

## v0.7.0 — 2026-06-09

`free_disk_space` flipped to default-on, hand-written README, removed `update-readme.yml` auto-generator, dropped `actions/github-script` dependency, bumped pinned actions.

- **Breaking for self-hosted runner callers.** `free_disk_space` default flipped from `false` (as shipped in v0.6.0) to `true`. Any caller that targets a self-hosted runner MUST set `free_disk_space: false` — the cleanup wipes shared host directories (`/opt/ghc`, `/usr/local/lib/android`, `/usr/share/dotnet`, etc.) and will damage the host. GitHub-hosted runners get the ~25-30 GB freed by default.
- Removed `.github/workflows/update-readme.yml` + `update_readme.py`. README is now hand-written and documents every workflow's inputs, secrets, and example usage.
- `collaborators-only-workflow.yml`: replaced `actions/github-script@v7.0.1` with an inline shell script using the preinstalled `gh` CLI. Removes a third-party action dependency (and the associated SHA-pin maintenance) for the only workflow that used it. Behavior unchanged: 204 from `repos/.../collaborators/<user>` allows, 404 closes (with comment + optional lock), anything else fails.
- Bumped pinned actions to the latest releases ≥7 days old (OSV/GHSA scan clean on every prior pin): `actions/checkout` v6.0.2 → v6.0.3, `actions/setup-go` v6.3.0 → v6.4.0, `actions/setup-python` v6.1.0 → v6.2.0, `docker/build-push-action` v7.0.0 → v7.2.0, `docker/login-action` v4.0.0 → v4.2.0, `docker/setup-buildx-action` v4.0.0 → v4.1.0, `docker/setup-qemu-action` v4.0.0 → v4.1.0, `softprops/action-gh-release` v2.6.1 → v2.6.2, `pypa/gh-action-pypi-publish` `release/v1.12` branch SHA → `v1.14.0` (pin to a specific tag instead of a release branch).

## v0.6.0 — 2026-06-08

Opt-in runner disk cleanup for the docker image workflow.

- New input `free_disk_space` (default `false`) on `docker-image-workflow.yml`. Runs `jlumbroso/free-disk-space@v1.3.1` after checkout to free ~25-30 GB on GitHub-hosted runners (removes Android SDK, .NET, Haskell, large apt packages, preloaded docker images). Tool cache + swap left untouched.
- Applies to both single-image (`build`) and multi-target (`build-multi`) paths.
- Do NOT enable on self-hosted runners — wipes shared host directories.

## v0.5.0 — 2026-05-21

Multi-Dockerfile + per-target platform support for multi-target builds.

- `build_targets` matrix entries now accept optional `dockerfile` + `platforms` keys, so individual targets can use a different `Dockerfile` and/or override `target_platforms`.
- README documents the extended matrix entry shape.
- Tightened collaborators-only workflow: switched author identity check from `sender.login` to `pull_request.user.login`, moved templated inputs into `env:` for the github-script step (script injection trust boundary).

## v0.4.0 — 2026-04-22

Self-hosted runner support + cache mode control.

- New input `runs_on` (default `ubuntu-latest`) on `go-workflow.yml`, `python-package-workflow.yml`, `docker-image-workflow.yml`. Caller can pin jobs to a self-hosted runner label.
- New input `cache_mode` (default `max`) on `docker-image-workflow.yml`. Switch to `min` for very large images that fail to push the cache manifest.

## v0.3.2 — 2026-04-16

`update-readme.yml` watcher fix.

## v0.3.1 — 2026-04-16

Reordered docker pipeline so scan runs last.

- Push + GitHub Release now happen before the Grype scan; scan failure still surfaces in CI but no longer blocks the release artifact from being published. Caller sees the failure on the workflow summary.

## v0.3.0 — 2026-04-15

Security hardening pass.

- Added `collaborators-only-workflow.yml` — reusable PR gate that closes (and optionally locks) PRs from non-collaborators. Requires caller to trigger via `pull_request_target` so the token can comment/close fork PRs.
- Pinned every third-party action by full commit SHA (no floating tags).
- Added `govulncheck` job to the Go workflow + `pip-audit` job to the Python workflow.
- Added Grype image scan to the docker workflow with configurable severity threshold (`scan_severity`, default `medium`).
- Tightened workflow permissions away from blanket `write-all`.

## v0.2.1 — 2026-03-28

`build_targets` matrix fix.

## v0.2.0 — 2026-03-28

Multi-target docker builds.

- New input `build_targets` on `docker-image-workflow.yml`: JSON array of `{target, tag_suffix}` entries to build multiple Dockerfile stages from one repo into multiple tags in a single pipeline run.
- Empty `build_targets` keeps the original single-image behavior (backwards compatible).

## v0.1.0 — 2026-01-15

First tagged release.

- `go-workflow.yml` — Go test/lint/release reusable workflow with optional `is_vendored` input to skip the dep download step for vendored projects.
- `python-package-workflow.yml` — Python lint/test/build/publish reusable workflow with code-check matrix (bandit/pylint/flake8) and PyPI publish on tags.
- `docker-image-workflow.yml` — single-image Docker buildx pipeline with QEMU multi-arch, Docker Hub push, GitHub Release on tags.
- `update-readme.yml` — self-watcher that regenerates `README.md` from the workflow files in this repo.
