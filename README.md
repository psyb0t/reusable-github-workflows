# Reusable GitHub Workflows

Opinionated, security-hardened reusable GitHub Actions workflows for shipping
Go, Python, and Docker projects — plus ClawHub skill/plugin publishing and a
gate that closes PRs from non-collaborators. Add one `uses:` line to a caller
repo and inherit a full **lint → test → scan → build → publish → release**
pipeline that lives in one versioned place instead of being copy-pasted across
every repo.

See [CHANGELOG.md](CHANGELOG.md) for the per-release notes.

## Contents

- [Shared conventions](#shared-conventions)
- [Pinning](#pinning)
- [Workflows](#workflows)
  - [collaborators-only-workflow.yml](#collaborators-only-workflowyml)
  - [docker-image-workflow.yml](#docker-image-workflowyml)
  - [go-workflow.yml](#go-workflowyml)
  - [python-package-workflow.yml](#python-package-workflowyml)
  - [clawhub-publish.yml](#clawhub-publishyml)
- [License](#license)

## Shared conventions

Every workflow here holds to the same rules, so a caller inherits them for free:

- **Third-party actions pinned by full commit SHA** — never a floating tag, so a re-pointed or compromised upstream tag can't silently change what runs.
- **Least-privilege permissions** — the top level is `permissions: {}`; each job opts in to only the scopes its steps need (`contents: read`, `security-events: write`, …).
- **Concurrency groups cancel superseded runs** — a newer push on the same ref supersedes an in-flight run, except tag pushes, which always run to completion.
- **Triggered from `push`** — you wire `on: [push]`; the workflow itself decides what to act on (branch vs. tag) and no-ops on refs it doesn't handle.
- **Supply-chain discipline on any tooling install** — exact version pins, an age-gate that refuses freshly-published releases, and `npm install --ignore-scripts`.

## Workflows

| Workflow | What it does |
|---|---|
| [`collaborators-only-workflow.yml`](#collaborators-only-workflowyml) | Close (and optionally lock) PRs from non-collaborators. |
| [`docker-image-workflow.yml`](#docker-image-workflowyml) | Buildx multi-arch / multi-target Docker Hub publish + SBOM/provenance + Grype scan → Security tab + GitHub Release. |
| [`go-workflow.yml`](#go-workflowyml) | Go lint / test / `govulncheck` + GitHub Release on tag. |
| [`python-package-workflow.yml`](#python-package-workflowyml) | Python lint matrix / test / build / `pip-audit` + PyPI publish (token or OIDC) + GitHub Release on tag. |
| [`clawhub-publish.yml`](#clawhub-publishyml) | Validate + publish skills and plugins to [ClawHub](https://clawhub.ai) via the official CLI. |

## Pinning

The examples below use `@master` for readability. **Don't use `@master` in production** — pin to a release tag (`@v0.13.0`) or a full commit SHA. `@master` follows whatever lands here without warning.

```yaml
# Recommended — pin to a release tag
uses: psyb0t/reusable-github-workflows/.github/workflows/go-workflow.yml@v0.13.0

# Stricter — pin to a specific SHA (immune to tag re-pointing)
uses: psyb0t/reusable-github-workflows/.github/workflows/go-workflow.yml@<full-40-char-sha>
```

## collaborators-only-workflow.yml

Closes (and optionally locks) any PR whose author is not a collaborator on the repository. Useful when you don't want to triage drive-by PRs from forks.

**Caller MUST trigger with `pull_request_target`** (not `pull_request`). The `pull_request_target` event runs with the base branch's token, which has permission to comment/close PRs from forks; `pull_request` from a fork has a read-only token and the workflow cannot close the PR.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `close_message` | string | `"This repository does not accept external pull requests. Please open an issue instead."` | Comment posted when an unauthorized PR is closed. |
| `lock` | boolean | `true` | Lock the PR conversation after closing. |

### Example

```yaml
name: Collaborators Only

on:
  pull_request_target:
    types: [opened, reopened]

jobs:
  gate:
    uses: psyb0t/reusable-github-workflows/.github/workflows/collaborators-only-workflow.yml@master
    with:
      close_message: "This repo does not accept external PRs — open an issue instead."
      lock: true
```

## docker-image-workflow.yml

Builds and pushes a multi-arch Docker image to Docker Hub.

- Pushes `:latest` from the default branch, `:<tag>` on tag pushes.
- Updates the Docker Hub repository description (the **Overview** tab) from the repo's `README.md` after every successful push via `peter-evans/dockerhub-description`. The Docker Hub token must have permission to edit the repository.
- Generates SBOM + max-mode provenance attestations by default (toggle off with `attestations: false` if your registry rejects OCI attestation manifests).
- On tag pushes, creates a GitHub Release once the build succeeds.
- Optionally scans the pushed image with Grype (`anchore/scan-action`) after push, and uploads the findings as SARIF to the repo's **Security → Code scanning** tab. **Scan runs after the artifact is already published, so it never blocks the push or the GitHub Release.** By default a finding at/above `scan_severity` still fails the workflow (red run); set `scan_fail_build: false` to keep scanning + reporting to the Security tab WITHOUT failing the run — the right posture for images with known-unfixable upstream vulns, and required if you want a downstream job (e.g. another reusable workflow) to `needs:` this one. The SARIF upload needs `permissions: security-events: write` on the caller's job (see below); without it, scanning still runs but the Security tab isn't populated.

Trigger from `push` so it fires on branch and tag pushes. The workflow itself only acts on `refs/heads/main`, `refs/heads/master`, and `refs/tags/*` — pushes to other branches do nothing.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `repository_name` | string | **required** | Docker Hub repo, e.g. `psyb0t/voidalpha`. |
| `target_platforms` | string | `"linux/amd64,linux/arm64"` | Comma-separated buildx platforms. Overridable per matrix entry. |
| `build_targets` | string (JSON) | `""` | Multi-target build matrix (see below). Empty = single-image build. |
| `scan_enabled` | boolean | `true` | Run Grype scan against the pushed image + upload SARIF to the Security tab. |
| `scan_severity` | string | `"medium"` | Grype severity threshold to fail on: `negligible`, `low`, `medium`, `high`, `critical`. |
| `scan_fail_build` | boolean | `true` | Fail the run on a finding at/above `scan_severity`. Set `false` to keep scanning + Security-tab reporting without failing the run (known-unfixable upstream vulns; also lets a downstream job `needs:` this workflow). Populating the Security tab needs `permissions: security-events: write` on the caller job. |
| `cache_mode` | string | `"max"` | Buildx GHA cache mode. Use `min` for smaller cache exports. Cache export is best-effort: a cache-service failure warns but never blocks an image push. |
| `attestations` | boolean | `true` | Emit SBOM + max-mode provenance attestations. Disable if your registry rejects OCI attestation manifests. |
| `free_disk_space` | boolean | `true` | Free ~25-30 GB before build (Android SDK, .NET, Haskell, large apt packages, preloaded docker images). **Disable for self-hosted runners** — wipes shared host directories. |
| `runs_on` | string | `"ubuntu-latest"` | Runner label. Use your self-hosted runner label + `free_disk_space: false`. |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `dockerhub_username` | yes | Docker Hub username. |
| `dockerhub_token` | yes | Docker Hub access token (NOT the account password). |

### Single-image example

```yaml
name: pipeline
on: [push]

jobs:
  docker:
    uses: psyb0t/reusable-github-workflows/.github/workflows/docker-image-workflow.yml@master
    with:
      repository_name: psyb0t/myapp
      target_platforms: "linux/amd64,linux/arm64"
    secrets:
      dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
      dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}
```

### Non-blocking scan + a downstream job that depends on the build

When Grype always finds known-unfixable upstream vulns, set `scan_fail_build: false` so the run goes green (findings still land in the Security tab), and grant `security-events: write` so the SARIF actually uploads. A green run is also what lets another job `needs:` this one:

```yaml
jobs:
  docker:
    permissions:
      contents: write        # GitHub Release
      security-events: write # upload Grype SARIF to the Security tab
    uses: psyb0t/reusable-github-workflows/.github/workflows/docker-image-workflow.yml@master
    with:
      repository_name: psyb0t/myapp
      scan_fail_build: false
    secrets:
      dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
      dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}

  after-build:
    needs: [docker]          # runs only if build + release succeeded (scan no longer blocks)
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest
    steps:
      - run: echo "image + release are done"
```

### Multi-target builds

Ship multiple image variants from one pipeline run by passing `build_targets` (JSON array). Each entry produces one image tagged with `tag_suffix`. Three flavors:

**Multi-stage from one Dockerfile** (e.g. `full` + `minimal` stages):

```yaml
with:
  repository_name: psyb0t/myapp
  build_targets: |
    [
      {"target": "full",    "tag_suffix": ""},
      {"target": "minimal", "tag_suffix": "-minimal"}
    ]
```

**Multi-Dockerfile** (separate CPU and CUDA builds):

```yaml
with:
  repository_name: psyb0t/myapp
  target_platforms: "linux/amd64"
  build_targets: |
    [
      {"file": "Dockerfile",      "tag_suffix": ""},
      {"file": "Dockerfile.cuda", "tag_suffix": "-cuda"}
    ]
```

**Per-image platforms override** (CPU image multi-arch, CUDA image amd64-only):

```yaml
with:
  repository_name: psyb0t/myapp
  target_platforms: "linux/amd64,linux/arm64"
  build_targets: |
    [
      {"file": "Dockerfile",      "tag_suffix": ""},
      {"file": "Dockerfile.cuda", "tag_suffix": "-cuda", "platforms": "linux/amd64"}
    ]
```

**Ordered builds** (a variant that does `FROM <repo>:latest` must build after the base is pushed):

```yaml
with:
  repository_name: psyb0t/myapp
  build_targets: |
    [
      {"file": "Dockerfile",      "tag_suffix": ""},
      {"file": "Dockerfile.full", "tag_suffix": "-full", "stage": 1}
    ]
```

Without `stage`, every target builds in parallel — so a `Dockerfile.full` that
does `FROM psyb0t/myapp:latest` would pull the *previously published* base, not
the one built in the same run. Marking it `"stage": 1` makes it wait until every
stage-0 target has built **and pushed**, so it inherits the fresh base. Targets
sharing a stage still build in parallel; stages run in ascending order.

`build_targets` entry fields:

| Field | Required | Description |
|---|---|---|
| `tag_suffix` | yes | Appended to the image tag. Empty string = unsuffixed (`:latest` / `:v1.2.3`). |
| `target` | no | Dockerfile stage. Omit for multi-Dockerfile builds. |
| `file` | no | Dockerfile path. Defaults to `Dockerfile`. |
| `platforms` | no | Platforms for this entry. Falls back to `inputs.target_platforms`. |
| `stage` | no | Build wave, default `0`. All stage-0 targets build+push before any stage-1 target starts. Use for images that `FROM` another target's pushed tag. |

### Disk space notes

`free_disk_space: true` is on by default because the standard `ubuntu-latest` runner ships with ~14 GB free, which often isn't enough for CUDA / torch / large ML images. The cleanup runs `jlumbroso/free-disk-space@v1.3.1` after checkout in every build job and frees roughly:

- Android SDK + NDK: ~14 GB
- Haskell toolchain (`/opt/ghc`): ~5.3 GB
- .NET (`/usr/share/dotnet`): ~1.6 GB
- Large apt packages: ~5 GB
- Preloaded docker images: ~3 GB

Tool cache (`/opt/hostedtoolcache`) and swap are **not** touched (the tool cache holds Go / Node / Python runtimes the workflow may still need; killing swap is risky on memory-tight builds).

**Self-hosted runners must set `free_disk_space: false`** — the cleanup wipes shared host directories that other workloads on the box may depend on.

### Pinned tool versions

| Component | Pin |
|---|---|
| `jlumbroso/free-disk-space` | `@v1.3.1` |
| `anchore/scan-action` (Grype) | `@v7.4.0` |
| `docker/build-push-action` | `@v7.2.0` |
| `docker/login-action` | `@v4.2.0` |
| `docker/setup-buildx-action` | `@v4.1.0` |
| `docker/setup-qemu-action` | `@v4.1.0` |
| `peter-evans/dockerhub-description` | `@v5.0.0` |

## go-workflow.yml

Lints + tests + scans + (on tag) cuts a GitHub Release.

- Lint job runs unless `lint_command: ""`. Test job runs unless `test_command: ""`. Vulnerability scan (`govulncheck@v1.3.0`) runs unless `scan_enabled: false`.
- Release job runs only on `refs/tags/*`, gated on: `code-checks` succeeded or was skipped, `test` succeeded or was skipped, and (when `scan_enabled: true`) `security-scan` succeeded.
- Release notes: the workflow writes a `CHANGELOG.md` in the CI working tree from `git log <prev_tag>..HEAD --pretty='* %s (%h)'` and uses it as the release body. **If your repo already has a hand-written `CHANGELOG.md`, it is overwritten only in the CI workspace** — your committed file is unaffected, but the release body on GitHub will be the auto-generated commit list, not your file. To use a hand-written changelog as the release body, do the release yourself instead of via this workflow.
- Pre-release classification: any tag containing `alpha`, `beta`, or `rc` (case-insensitive) is marked as a pre-release on GitHub and is NOT marked as the latest release.

Trigger from `push` so it fires on branch and tag pushes.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `go_version` | string | `"1.26"` | Go toolchain version passed to `actions/setup-go`. |
| `dep_command` | string | `"make dep"` | Command to install dependencies. Skipped when `is_vendored: true`. |
| `lint_command` | string | `"make lint"` | Code-checks command. Set to `""` to skip the lint job. |
| `test_command` | string | `"make test"` | Test command. Set to `""` to skip the test job. |
| `is_vendored` | boolean | `false` | Whether dependencies are vendored. Skips `dep_command` when true. |
| `scan_enabled` | boolean | `true` | Run `govulncheck` against the module. |
| `runs_on` | string | `"ubuntu-latest"` | Runner label. |
| `debug` | boolean | `false` | Emit a debug job that prints workflow context + input values. |

### Security note

`test_command`, `lint_command`, and `dep_command` are interpolated into shell scripts. Callers control these strings, which is equivalent to arbitrary code execution on the runner with whatever secrets/permissions the caller workflow exposes. Only call this workflow from trusted repos with branch protection on the workflow files.

### Example

```yaml
name: pipeline
on: [push]

jobs:
  go:
    uses: psyb0t/reusable-github-workflows/.github/workflows/go-workflow.yml@master
    with:
      go_version: "1.26"
      dep_command: "make dep"
      lint_command: "make lint"
      test_command: "make test"
```

## python-package-workflow.yml

Code-checks matrix + tests + build + `pip-audit` + PyPI publish + GitHub Release on tag.

- `code-checks` runs a matrix of the linters in `code_checks` (`fail-fast: false` — every check reports independently). Defaults: `bandit`, `pylint`, `flake8`. `safety` is supported but its upstream `check` subcommand is deprecated; opt in only if needed.
- `test` job is skipped when `test_command: ""`. Otherwise it gates the rest of the pipeline.
- `build` produces artifacts in `dist_dir/` and uploads them as the `dist` artifact (retention 7 days).
- `security-scan` runs `pip-audit==2.8.0 --strict` against installed packages, after build and before publish. Disable with `scan_enabled: false`.
- `pypi-publish` runs only on `refs/tags/*` when build succeeded and (if `scan_enabled`) scan succeeded. Uses `pypa/gh-action-pypi-publish`. With `pypi_oidc: false` (default) it expects `secrets.pypi_api_token`; with `pypi_oidc: true` it uses Trusted Publishing via OIDC.
- `release` job uploads everything matching `${{ inputs.dist_dir }}/*` as files attached to the GitHub Release.

**OIDC caveat**: when `pypi_oidc: true`, the calling workflow's job must also grant `permissions: id-token: write`. A reusable workflow can only narrow the caller's token, not widen it. If the caller's job-level permissions don't include `id-token: write`, OIDC publish fails. Example:

```yaml
jobs:
  python:
    permissions:
      id-token: write   # required for OIDC; passed through to the reusable workflow
    uses: psyb0t/reusable-github-workflows/.github/workflows/python-package-workflow.yml@master
    with:
      pypi_oidc: true
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `python_version` | string | `"3.12.0"` | Python version passed to `actions/setup-python`. |
| `install_dependencies_command` | string | `"make dep"` | Command to install dependencies. |
| `build_command` | string | `"make build"` | Command to build the distribution. |
| `test_command` | string | `""` | Test command. Empty = skip the test job. |
| `dist_dir` | string | `"dist"` | Build output directory uploaded as the `dist` artifact. |
| `enable_code_checks` | boolean | `true` | Run the code-checks matrix. |
| `code_checks` | string (JSON) | `'["bandit", "pylint", "flake8"]'` | Checks to run. Supported: `bandit`, `safety`, `pylint`, `flake8`. `safety check` is upstream-deprecated; opt in only if needed. |
| `scan_enabled` | boolean | `true` | Run `pip-audit` after build, before publish. |
| `pypi_oidc` | boolean | `false` | Use PyPI Trusted Publishing (OIDC) instead of API token. Requires PyPI-side configuration on the project. |
| `runs_on` | string | `"ubuntu-latest"` | Runner label. |
| `debug` | boolean | `false` | Emit a debug job that prints workflow context. |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `pypi_api_token` | no | PyPI API token. Not required when `pypi_oidc: true`. |

### Example (API token)

```yaml
name: pipeline
on: [push]

jobs:
  python:
    uses: psyb0t/reusable-github-workflows/.github/workflows/python-package-workflow.yml@master
    with:
      python_version: "3.12.0"
      install_dependencies_command: "make dep"
      build_command: "make build"
      dist_dir: "dist"
    secrets:
      pypi_api_token: ${{ secrets.PYPI_API_TOKEN }}
```

### Example (Trusted Publishing / OIDC)

Configure the publisher on PyPI first (per project), then:

```yaml
jobs:
  python:
    permissions:
      id-token: write
    uses: psyb0t/reusable-github-workflows/.github/workflows/python-package-workflow.yml@master
    with:
      pypi_oidc: true
```

No `pypi_api_token` secret needed — PyPI authenticates the workflow via OIDC. The `id-token: write` permission on the calling job is required.

## clawhub-publish.yml

Publishes both **skills** and **plugins** to [ClawHub](https://clawhub.ai) (the OpenClaw skill + plugin registry) via the official `clawhub` CLI. **Both halves default on** (`publish_skills` and `publish_plugins`, both `true`) — this org ships skills and plugins out of the same repos, so callers don't repeat the wiring; a repo missing one dir (or with an empty one) skips that half cleanly instead of failing. Each half runs as **validate → publish**: a `validate-*` job runs whenever the workflow is *called* (skill `--dry-run` resolve / static plugin Inspector — no plugin code executes), and the matching `publish-*` job runs only on a tag ref AND only after its validation passed. Dropping a caller's `if: tags` gate therefore gives validation on every push while publishing stays tag-only.

**Skills** — one ClawHub skill per subfolder:

- Discovers each `<skills_dir>/<name>/SKILL.md` and runs the official `clawhub` CLI (`skill publish`) against it. The CLI derives the slug, display name, summary, and file set — every regular file in the skill folder except dotfiles and `node_modules`.
- **Version policy.** On a tag push the ClawHub version **mirrors the git tag** (a leading `v` stripped, e.g. `v1.4.0` → `1.4.0`) — but only when that tag is strictly higher than the skill's current ClawHub version. If ClawHub is already ahead (its version line got out in front of the repo), it falls back to the CLI's automatic patch-bump until a repo tag finally exceeds it, then mirroring takes over. Off a tag (or a non-semver tag) it auto patch-bumps. Set the `version` input to force an explicit version. A version that already exists is treated as "already published", not a failure.
- Drives the CLI directly — no marketplace publish action and not ClawHub's own reusable workflow — so this repo owns the whole flow.
- **Read-only repo access.** The job runs with `contents: read` and nothing else; publishing authenticates with the ClawHub token, never a repo-write scope.
- **Supply-chain hardened.** The CLI version is exact-pinned (`cli_version`), an age-gate step refuses any CLI version published within `min_release_age_days` days, install uses `npm install -g … --ignore-scripts`, and every action is SHA-pinned.
- **License:** ClawHub licenses every published skill as `MIT-0` on its side, with no per-skill override — the CLI sends the acceptance. Your repo's own LICENSE is unaffected; this only governs the copy ClawHub hosts.
- Set `dry_run: true` to resolve + validate every skill without publishing.

**Plugins** — one ClawHub plugin per subfolder (`publish_plugins`, default `true`):

- Discovers each `<plugins_dir>/<name>/openclaw.plugin.json`, runs `clawhub package validate` (STATIC only — no `--runtime`/`--allow-execute`, so no plugin code is imported or executed in CI), then `clawhub package publish`.
- **Version.** ClawHub takes the plugin's `package.json#version` as the release version. On a tag push the git tag (leading `v` stripped) is mirrored into `package.json#version` (and `openclaw.plugin.json#version` if present) before publishing.
- **No dependency install in CI.** `package publish` packs the source (`npm pack`); a plugin's own dependency tree is resolved by the end user at their install time, never here.
- Plugin package names are npm-scoped (`@owner/name`); the scope must match a ClawHub owner you control.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `publish_skills` | boolean | `true` | Publish skills found under `skills_dir`. |
| `publish_plugins` | boolean | `true` | Publish plugins found under `plugins_dir`. |
| `skills_dir` | string | `".agents/skills"` | Directory holding one subfolder per skill, each with a `SKILL.md`. |
| `plugins_dir` | string | `".agents/plugins"` | Directory holding one subfolder per plugin, each with an `openclaw.plugin.json`. |
| `registry` | string | `"https://clawhub.ai"` | ClawHub registry base URL. |
| `site` | string | `"https://clawhub.ai"` | ClawHub site base URL (used by the CLI for page links). |
| `tags` | string | `"latest"` | Comma-separated ClawHub tags applied to the published version. |
| `owner` | string | `""` | Publisher handle to publish under (org-scoped). Empty = infer from the token. |
| `version` | string | `""` | Explicit ClawHub version (semver). Empty = mirror the git tag when it's higher than ClawHub's current version, else auto patch-bump (see Version policy). |
| `cli_version` | string | `"0.23.1"` | Exact `clawhub` CLI version to install (no ranges). |
| `node_version` | string | `"22"` | Node.js major version (the CLI requires ≥22). |
| `min_release_age_days` | number | `7` | Refuse to install a CLI version published more recently than this. |
| `dry_run` | boolean | `false` | Resolve + validate but don't publish. |
| `runs_on` | string | `"ubuntu-latest"` | Runner label. |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `clawhub_token` | yes | ClawHub API token (`clh_...`) with publish scope. |

### Example

```yaml
name: pipeline
on: [push]

jobs:
  clawhub:
    if: startsWith(github.ref, 'refs/tags/')
    uses: psyb0t/reusable-github-workflows/.github/workflows/clawhub-publish.yml@master
    secrets:
      clawhub_token: ${{ secrets.CLAWHUB_TOKEN }}
```

With the defaults, that publishes every skill under `.agents/skills/` and every plugin under `.agents/plugins/` on tag pushes — no `with:` block needed. Drop the `if:` line to also validate skills + plugins on every push (publishing still fires only on tags, enforced inside the workflow).

## License

[WTFPL](http://www.wtfpl.net/) — Do What The Fuck You Want To Public License. See [LICENSE](LICENSE).
