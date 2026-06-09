# Reusable GitHub Workflows

A small set of opinionated reusable GitHub Actions workflows for shipping Go, Python, and Docker projects, plus a PR-gate that closes pull requests from non-collaborators.

Every third-party action used inside these workflows is pinned by full commit SHA (no floating tags). Job permissions are scoped to the minimum each step needs. Concurrency groups cancel superseded runs (except for tag pushes, which always complete).

See [CHANGELOG.md](CHANGELOG.md) for the per-release notes.

## Workflows

- [collaborators-only-workflow.yml](.github/workflows/collaborators-only-workflow.yml) — close PRs from non-collaborators (with optional allow-extras + lock)
- [docker-image-workflow.yml](.github/workflows/docker-image-workflow.yml) — buildx multi-arch / multi-target Docker Hub publish + Grype scan + GitHub Release
- [go-workflow.yml](.github/workflows/go-workflow.yml) — Go lint / test / `govulncheck` + GitHub Release on tag
- [python-package-workflow.yml](.github/workflows/python-package-workflow.yml) — Python lint matrix / test / build / `pip-audit` + PyPI publish + GitHub Release on tag

## Pinning

The examples in this README use `@master` for readability. **Do not use `@master` in production** — pin to a tag (`@v0.6.0`) or full commit SHA. `@master` follows whatever lands here without warning.

```yaml
# Recommended
uses: psyb0t/reusable-github-workflows/.github/workflows/go-workflow.yml@v0.6.0

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
- Optionally scans the pushed image with Grype (`anchore/scan-action`) after push. **Scan failure does NOT block the GitHub Release.** The scan runs after the artifact is already published; the failure surfaces in the workflow summary so you can decide whether to yank the tag.

Trigger from `push` so it fires on branch and tag pushes. The workflow itself only acts on `refs/heads/main`, `refs/heads/master`, and `refs/tags/*` — pushes to other branches do nothing.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `repository_name` | string | **required** | Docker Hub repo, e.g. `psyb0t/voidalpha`. |
| `target_platforms` | string | `"linux/amd64,linux/arm64"` | Comma-separated buildx platforms. Overridable per matrix entry. |
| `build_targets` | string (JSON) | `""` | Multi-target build matrix (see below). Empty = single-image build. |
| `scan_enabled` | boolean | `true` | Run Grype scan against the pushed image. |
| `scan_severity` | string | `"medium"` | Grype severity threshold to fail on: `negligible`, `low`, `medium`, `high`, `critical`. |
| `cache_mode` | string | `"max"` | Buildx GHA cache mode. Use `min` if your image is too large for `max` to push the cache manifest. |
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

`build_targets` entry fields:

| Field | Required | Description |
|---|---|---|
| `tag_suffix` | yes | Appended to the image tag. Empty string = unsuffixed (`:latest` / `:v1.2.3`). |
| `target` | no | Dockerfile stage. Omit for multi-Dockerfile builds. |
| `file` | no | Dockerfile path. Defaults to `Dockerfile`. |
| `platforms` | no | Platforms for this entry. Falls back to `inputs.target_platforms`. |

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

## License

See [LICENSE](LICENSE).
