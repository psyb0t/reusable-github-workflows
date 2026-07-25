# Changelog

All notable changes per release. Versions follow [semver](https://semver.org)
pre-1.0 conventions: minor bumps may include breaking input/behavior changes
(called out explicitly), patch bumps are docs / build / fixes only.

## v0.13.0 — 2026-07-25

`clawhub-publish.yml`: both halves default ON, missing dirs skip cleanly, and a validate stage now gates every publish.

- **`publish_plugins` now defaults `true`** (was `false`). Skills and plugins both publish by default, so a caller that ships both no longer passes a `with:` block at all. `skills_dir` / `plugins_dir` keep their `.agents/skills` / `.agents/plugins` defaults.
- **Missing/empty dir = clean skip, not failure.** When `skills_dir` or `plugins_dir` is absent (or contains no `SKILL.md` / `openclaw.plugin.json`), that half logs and exits 0 instead of erroring — so a skills-only or plugin-only repo can safely leave both halves on.
- **New validate stage.** Each half runs `validate-*` → `publish-*`: `validate-skills` runs `clawhub skill publish --dry-run` per skill; `validate-plugins` runs the static `clawhub package validate` (Plugin Inspector — no `--runtime`, no token, no plugin code executed) per plugin. Each `publish-*` job `needs:` its matching validate job, so a malformed skill/plugin fails validation before anything is published.
- **Publish jobs are internally tag-gated.** `publish-skills` / `publish-plugins` now also require `startsWith(github.ref, 'refs/tags/')`. Validation runs whenever the workflow is *called*; publishing only fires on a tag ref. A caller can drop its own `if: tags` gate to get validation on every push while publishing stays tag-only. **Behavior note for existing callers:** publishing now requires a tag ref even if the caller doesn't gate — an intentional guardrail against publishing off a branch.

## v0.12.0 — 2026-07-25

New `clawhub-publish.yml` — one flow that publishes both **skills and plugins**. The old `clawhub-skills-publish-workflow.yml` name is retained as a thin pass-through shim.

- **New `clawhub-publish.yml`** is the canonical flow, with two independent jobs: `publish-skills` (unchanged behaviour; `publish_skills` input default `true`) and `publish-plugins` (new; `publish_plugins` default `false`).
- **Plugin path** — publishes every `<plugins_dir>/<name>/openclaw.plugin.json` (default `plugins_dir: .agents/plugins`) as a ClawHub plugin: `clawhub package validate` (STATIC only — no `--runtime`/`--allow-execute`, so no plugin code runs in CI) then `clawhub package publish`. On a tag push, the git tag is mirrored into each plugin's `package.json#version` (ClawHub takes the package version as the release version). The plugin path never installs a plugin's own dependencies in CI — `package publish` packs the source only.
- **New inputs:** `publish_skills`, `publish_plugins`, `plugins_dir`. Same supply-chain hardening as the skills path (exact-pinned, age-gated CLI; `npm install --ignore-scripts`; SHA-pinned actions; `contents: read`).
- **Backward compatible:** `clawhub-skills-publish-workflow.yml` now forwards to `clawhub-publish.yml` with plugins off, so existing `@master` callers keep working unchanged. Migrate to `clawhub-publish.yml` when convenient.

## v0.11.1 — 2026-07-25

`clawhub-skills-publish-workflow.yml`: fix the version-mirroring query so publishing a brand-new skill no longer fails.

- **Fix — first-time publish of a new skill.** The per-skill version check (`GET /api/v1/skills/<slug>`) ran under `curl -fsS`; for a skill that doesn't exist on ClawHub yet that request 404s, and with `-f` under `set -o pipefail` the step exited non-zero and aborted the whole publish. The query now tolerates the 404 (and any transient error) — the result is treated as an empty current version, so the new-skill / mirror-repo-tag branch runs as intended and the skill is created at the repo tag version. Publishing an existing skill is unchanged.

## v0.11.0 — 2026-07-24

`clawhub-skills-publish-workflow.yml`: the ClawHub version now follows the repo's git tag when it's ahead, instead of always blind patch-bumping.

- **Change — version mirrors the git tag.** On a tag push, each skill publishes at the git tag version (leading `v` stripped) — but only when that version is strictly higher than the skill's current ClawHub version. If ClawHub is already ahead (its version line drifted out in front of the repo, e.g. from earlier auto-patch publishes), it falls back to the CLI's automatic patch-bump until a repo tag finally exceeds it, then mirroring takes over. Off a tag or with a non-semver tag it auto patch-bumps as before. The per-skill decision queries `GET /api/v1/skills/<slug>` for the current version and compares with `sort -V`.
- **New `version` input** (default empty) to force an explicit ClawHub version, overriding the tag/auto logic.
- **A version that already exists is now treated as "already published"**, not a hard failure — so re-running a tag's pipeline no longer red-fails the publish job.

## v0.10.0 — 2026-07-24

`docker-image-workflow.yml`: Grype scan now uploads SARIF to the Security tab, plus a `scan_fail_build` toggle so a scan finding no longer has to fail the run.

- New `scan_fail_build` input (default `true`, backwards compatible). When `false`, Grype still scans + reports but a finding at/above `scan_severity` no longer fails the workflow — the right posture for images with known-unfixable upstream vulns, and what lets a downstream job `needs:` this workflow (a perpetually-red scan would otherwise block it forever).
- Both the single-image `scan` job and the multi-target `scan-multi` job now run Grype with `output-format: sarif` and upload the result to **Security → Code scanning** via `github/codeql-action/upload-sarif` (SHA-pinned `v4.37.1`). `scan-multi` uses a per-image `category` so matrix targets are tracked separately instead of overwriting each other. The SARIF upload is `continue-on-error` so a missing permission never fails an otherwise-green run.
- **Caller action needed for the Security tab:** the calling job must grant `permissions: security-events: write` (and `contents: write` if it also cuts a Release). Without it, scanning still runs but the Security tab isn't populated. README documents the pattern.
- Behavior change for existing callers: scan output moved from a log table to the Security tab (SARIF). Pass/fail behavior is unchanged by default (`scan_fail_build` defaults to `true`).

## v0.9.0 — 2026-07-24

New `clawhub-skills-publish-workflow.yml` — publishes skills to ClawHub via the official `clawhub` CLI.

- New reusable workflow that discovers every `<skills_dir>/<name>/SKILL.md` (default `skills_dir: .agents/skills`) and publishes each as its own ClawHub skill by driving the official `clawhub` CLI (`skill publish --json`). The CLI derives slug, display name, next version (auto patch-bump off the published version, `1.0.0` for new skills), summary, and file set. Records GitHub provenance via `--source-repo` / `--source-commit` / `--source-path` / `--source-ref`.
- **Read-only repo access** — the job runs with `contents: read` only; publishing authenticates with the `clawhub_token` secret written to a temp CLI config, not a repo-write scope.
- **Supply-chain hardened** — `cli_version` is exact-pinned (default `0.23.1`); an age-gate step queries the npm registry and refuses any CLI version published within `min_release_age_days` (default 7) days; install uses `npm install -g clawhub@<ver> --ignore-scripts`; `actions/checkout` and `actions/setup-node` are SHA-pinned.
- Inputs: `skills_dir`, `registry`, `site`, `tags`, `owner`, `cli_version`, `node_version`, `min_release_age_days`, `dry_run`, `runs_on`. Secret: `clawhub_token` (required). `dry_run: true` resolves + validates without publishing.
- Note: ClawHub licenses every published skill as `MIT-0` on its side (no per-skill override); the CLI sends the acceptance. The caller repo's own LICENSE is unaffected.

## v0.8.1 — 2026-07-22

GitHub Actions cache export is now best-effort for every Docker image build
path. A cache-service failure no longer cancels a successfully built and pushed
image.

## v0.8.0 — 2026-07-04

Ordered multi-target builds via optional per-target `stage`, so a variant that `FROM`s another target's tag builds after the base is pushed.

- New optional `stage` field on `build_targets` matrix entries (default `0`) in `docker-image-workflow.yml`. All stage-0 targets build+push before any stage-1 target starts. Use it for an image whose Dockerfile does `FROM <repo>:latest` — without ordering it would build in parallel with the base and inherit the *previously published* base instead of the one built in the same run.
- Multi-target path restructured into waves: a new `plan-multi` job splits `build_targets` into `wave0`/`wave1` with `jq`; `build-multi` builds wave 0, and a new `build-multi-wave1` job builds wave 1 gated on `needs: build-multi`. `release-multi`, `scan-multi`, and `update-dockerhub-description` now depend on both build jobs and tolerate `build-multi-wave1` being skipped.
- **Backwards compatible.** Targets without `stage` all land in wave 0 and build in parallel exactly as before; `build-multi-wave1` is skipped when no target sets `stage: 1`. Existing callers need no changes.
- README documents the `stage` field, adds an "Ordered builds" example, and notes stages run in ascending order while same-stage targets stay parallel.

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
