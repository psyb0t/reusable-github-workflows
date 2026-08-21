# Reusable GitHub Workflows

Opinionated, security-hardened reusable GitHub Actions workflows for shipping
Go, Python, and Docker projects, plus ClawHub skill/plugin publishing and a
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
  - [code-workflow.yml](#code-workflowyml)
  - [make-checks.yml](#make-checksyml)
  - [release-workflow.yml](#release-workflowyml)
  - [clawhub-publish.yml](#clawhub-publishyml)
  - [mcp-registry-publish.yml](#mcp-registry-publishyml)
  - [create-badges.yml](#create-badgesyml)
  - [git-mirror.yml](#git-mirroryml)
  - [issue-pull.yml](#issue-pullyml)
  - [archive.yml](#archiveyml)
- [License](#license)

## Shared conventions

Every workflow here holds to the same rules, so a caller inherits them for free:

- **Third-party actions pinned by full commit SHA.** Never use a floating tag. A re-pointed or compromised upstream tag cannot silently change what runs.
- **Least-privilege permissions.** The top level is `permissions: {}`. Each job opts into only the scopes it needs (`contents: read`, `security-events: write`, …).
- **Concurrency matches the resource.** A newer push on the same ref supersedes ordinary in-flight work. Tag pushes always complete. Badge publishing serializes writers for each caller repository and output branch. Mirroring serializes per caller repository without cancellation because every run carries a real ref that must reach the targets.
- **Triggered from `push`.** You wire `on: [push]`. The workflow decides whether the ref applies and no-ops otherwise.
- **Supply-chain discipline on tooling installs.** Exact version pins, an age gate that rejects fresh releases, and `npm install --ignore-scripts`.
- **Network operations retry with exponential backoff.** Clones, pushes, package installs, and release downloads retry transient failures. Scanners (`govulncheck`, `pip-audit`) do not retry because a finding is a real failure.
- **Fail honestly without blocking unrelated work.** An independent job goes red when it did not complete. Do not hide its failure to keep a run green.

## Workflows

| Workflow | What it does |
|---|---|
| [`collaborators-only-workflow.yml`](#collaborators-only-workflowyml) | Close (and optionally lock) PRs from non-collaborators. |
| [`docker-image-workflow.yml`](#docker-image-workflowyml) | Buildx multi-arch / multi-target Docker Hub publish + SBOM/provenance + Grype scan → Security tab + GitHub Release. |
| [`go-workflow.yml`](#go-workflowyml) | Go lint / test / `govulncheck` + GitHub Release on tag. |
| [`python-package-workflow.yml`](#python-package-workflowyml) | Python lint matrix / test / build / `pip-audit` + PyPI publish (token or OIDC) + GitHub Release on tag. |
| [`code-workflow.yml`](#code-workflowyml) | Chain a repo's own build / lint / test / sec / generate commands (no toolchain setup), upload coverage + a security SARIF, check codegen drift. For projects whose toolchain lives in their container. |
| [`make-checks.yml`](#make-checksyml) | Deprecated compatibility runner for container-backed `make lint` and `make test` checks. Use `code-workflow.yml` for new callers. |
| [`release-workflow.yml`](#release-workflowyml) | Cut a GitHub release for a tag (tag + notes, no artifacts) via the gh CLI. |
| [`clawhub-publish.yml`](#clawhub-publishyml) | Validate + publish skills and plugins to [ClawHub](https://clawhub.ai) via the official CLI. |
| [`mcp-registry-publish.yml`](#mcp-registry-publishyml) | Publish a `server.json` to the official [MCP Registry](https://registry.modelcontextprotocol.io) on tag, secretless via GitHub OIDC. |
| [`create-badges.yml`](#create-badgesyml) | Self-render coverage / license / version / imported-by SVG badges (no third-party service) and commit them to an orphan `badges` branch. |
| [`git-mirror.yml`](#git-mirroryml) | Push-mirror every branch + tag to Codeberg / GitLab / Gitee, creating the repo and syncing description + topics. |
| [`issue-pull.yml`](#issue-pullyml) | Copy mirror issues and replies into GitHub with linked source identities, track source edits and state changes, and preserve confidential GitLab issues as generic source links. |
| [`archive.yml`](#archiveyml) | Push the repo into the Wayback Machine (pages), Software Heritage (git history) and archive.org (a browsable item of the source itself). |

## Pinning

The examples below use `@master` for readability. **Do not use `@master` in production.** Pin to a release tag (`@v0.13.0`) or a full commit SHA. `@master` follows whatever lands here without warning.

```yaml
# Recommended: pin to a release tag
uses: psyb0t/reusable-github-workflows/.github/workflows/go-workflow.yml@v0.13.0

# Stricter: pin to a specific SHA (immune to tag re-pointing)
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
| `allow_authors` | string | `dependabot[bot],dependabot-preview[bot]` | Comma-separated PR author logins that bypass the collaborator check. Use it for trusted bots whose PRs are meant to be reviewed and merged. Closing their PRs creates a dead notification path because nobody sees a bot-opened, bot-closed PR. |

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
      close_message: "This repo does not accept external PRs. Open an issue instead."
      lock: true
```

## docker-image-workflow.yml

Builds and pushes a multi-arch Docker image to Docker Hub.

- Pushes `:latest` from the default branch, `:<tag>` on tag pushes.
- Updates the Docker Hub repository description (the **Overview** tab) from the repo's `README.md` after every successful push via `peter-evans/dockerhub-description`.

> **The Docker Hub token needs Read, Write and Delete.** Pushing an image needs Write. Updating repository metadata, including the description, README, and visibility, needs the Docker Hub scope that also includes Delete. Nothing in this workflow issues a `DELETE`.
- Generates SBOM + max-mode provenance attestations by default (toggle off with `attestations: false` if your registry rejects OCI attestation manifests).
- On tag pushes, creates a GitHub Release once the build succeeds.
- Optionally scans the pushed image with Grype (`anchore/scan-action`) after push and uploads findings as SARIF to **Security → Code scanning**. The artifact and GitHub Release are already published when the scan runs. A finding does not fail the run by default (`scan_fail_build: false`) because base-image CVEs are continuous and often lack a fix. Set `scan_fail_build: true` when a finding must block release. The caller needs `permissions: security-events: write` for SARIF to reach the Security tab.

Trigger from `push` so it fires on branch and tag pushes. The workflow only acts on `refs/heads/main`, `refs/heads/master`, and `refs/tags/*`.

**The Docker Hub page is kept in step with the GitHub one.** Three things drift otherwise, and all three are invisible until someone lands on the Docker Hub page and finds nothing useful:

- **Visibility.** A pushed repository starts with the account default visibility. `dockerhub_private` (default `false`) checks and corrects it after every push.
- **The short description.** It comes from the GitHub repository description. Docker Hub caps it at **100 characters**, and the workflow counts codepoints so it does not split a multi-byte character.
- **Links.** Docker Hub has no project or source URL field. With `readme_url_header` (default `true`), the workflow prepends the source link and homepage to the long description. It does not change the repository README.

Topics are deliberately **not** synced: Docker Hub's `categories` are a fixed taxonomy rather than free-form tags, so GitHub topics have nothing to map onto.

**Suppressing an assessed CVE with `scan_vex_file`.** An image can carry an upstream CVE in code it never executes. An [OpenVEX](https://openvex.dev) document names the CVE, states `not_affected`, records a machine-readable justification, and lives in the repository for review.

```yaml
with:
  scan_vex_file: security/myimage-cpython.openvex.json
  scan_only_fixed: true
```

```json
{
  "@context": "https://openvex.dev/ns/v0.2.0",
  "statements": [
    {
      "vulnerability": { "name": "CVE-2026-11940" },
      "products": [{ "@id": "pkg:generic/python@3.14.6" }],
      "status": "not_affected",
      "justification": "vulnerable_code_not_in_execute_path",
      "impact_statement": "This service accepts no archive input and its source has no tarfile import or call path."
    }
  ]
}
```

**A VEX-suppressed finding disappears from the Security tab and the build result.** Each statement must explain why the vulnerable code is unreachable. Review it like code. `scan_only_fixed` hides every vulnerability without a published fix.

Setting `scan_vex_file` makes the scan job check out the repository. That job grants `contents: read` for the file.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `repository_name` | string | **required** | Docker Hub repo, e.g. `psyb0t/voidalpha`. |
| `target_platforms` | string | `"linux/amd64,linux/arm64"` | Comma-separated buildx platforms. Overridable per matrix entry. |
| `build_targets` | string (JSON) | `""` | Multi-target build matrix (see below). Empty = single-image build. |
| `scan_enabled` | boolean | `true` | Run Grype scan against the pushed image + upload SARIF to the Security tab. |
| `scan_severity` | string | `"medium"` | Grype severity threshold to fail on: `negligible`, `low`, `medium`, `high`, `critical`. |
| `scan_fail_build` | boolean | `false` | Fail the run on a finding at or above `scan_severity`. Off by default because upstream CVEs are continuous and often unfixable. Findings still reach the Security tab. Set `true` where a finding must block release. The caller needs `permissions: security-events: write` for the Security tab. |
| `scan_vex_file` | string | `""` | Path to an [OpenVEX](https://openvex.dev) document passed to Grype as `--vex`. Use it only for an assessed CVE that does not affect this image. Suppressed findings leave the Security tab. |
| `scan_only_fixed` | boolean | `false` | Only report vulnerabilities that have a fix available. |
| `dockerhub_private` | boolean | `false` | Visibility the Docker Hub repository should have. The workflow checks and corrects it after every push. |
| `sync_description` | boolean | `true` | Set the Docker Hub short description from the GitHub repo description (cut to 100 characters), and compose the long one. |
| `readme_url_header` | boolean | `true` | Prepend source + project-page links to the long description on Docker Hub. The repo's own README is not modified. |
| `cache_mode` | string | `"max"` | Buildx GHA cache mode. Use `min` for smaller cache exports. Cache export is best-effort: a cache-service failure warns but never blocks an image push. |
| `attestations` | boolean | `true` | Emit SBOM + max-mode provenance attestations. Disable if your registry rejects OCI attestation manifests. |
| `free_disk_space` | boolean | `true` | Free ~25 to 30 GB before build. **Disable for self-hosted runners.** The cleanup wipes shared host directories. |
| `runs_on` | string | `"ubuntu-latest"` | Runner label. Use your self-hosted runner label + `free_disk_space: false`. |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `dockerhub_username` | yes | Docker Hub username. |
| `dockerhub_token` | yes | Docker Hub access token, not the account password. **Needs Read, Write and Delete.** |

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

This is the default posture. Findings land in the Security tab and the run stays green. Grant `security-events: write` so the SARIF uploads. A green run lets another job `needs:` this one:

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

Ship multiple image variants from one pipeline run by passing `build_targets` (JSON array). Each entry produces one image tagged as `tag_prefix` + the moving or release tag + `tag_suffix`. Four flavors:

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

**Tag-prefixed companion image** (a controller with a worker/cell image in the
same repository):

```yaml
with:
  repository_name: psyb0t/myapp
  build_targets: |
    [
      {"file": "Dockerfile",      "tag_suffix": ""},
      {"file": "cell/Dockerfile", "tag_prefix": "cell-"}
    ]
```

This publishes `:latest` and `:cell-latest` from the default branch, then
`:vX.Y.Z` and `:cell-vX.Y.Z` from a release tag.

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

Without `stage`, every target builds in parallel. A `Dockerfile.full` that
does `FROM psyb0t/myapp:latest` would pull the *previously published* base, not
the one built in the same run. Marking it `"stage": 1` makes it wait until every
stage-0 target has built **and pushed**, so it inherits the fresh base. Targets
sharing a stage still build in parallel; stages run in ascending order.

`build_targets` entry fields:

| Field | Required | Description |
|---|---|---|
| `tag_prefix` | no | Prepended to the image tag. `"cell-"` produces `:cell-latest` / `:cell-v1.2.3`. |
| `tag_suffix` | no | Appended to the image tag. `"-minimal"` produces `:latest-minimal` / `:v1.2.3-minimal`. |
| `build_args` | no | Newline-delimited non-secret Docker build arguments for this target. Never pass credentials or tokens. |
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

**Self-hosted runners must set `free_disk_space: false`.** The cleanup wipes shared host directories that other workloads may use.

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

- `dep_command`, `lint_command`, and `test_command` accept `-` or `""` to skip that step. Prefer `-` because an empty string can be a templating accident. `generate_command` has no `-` escape because `has_codegen` already decides whether that job runs.
- Lint job runs unless `lint_command` is disabled. Test job runs unless `test_command` is disabled. Vulnerability scan (`govulncheck@v1.3.0`) runs unless `scan_enabled: false`.
- Codegen drift (`generate-check`) runs `generate_command`, then fails if the working tree moved. It catches missed regeneration and hand edits to generated files. The check uses `git status --porcelain`, so it catches a new uncommitted file while respecting `.gitignore`. Set `has_codegen: true` only in a repository that commits generated files.
  - The generator must be idempotent. Pin its version rather than disabling the job when it emits timestamps, hostnames, or random map order.
- Release job runs only on `refs/tags/*`, gated on: `code-checks` succeeded or was skipped, `test` succeeded or was skipped, `generate-check` succeeded or was skipped, and (when `scan_enabled: true`) `security-scan` succeeded.
- Release notes come from `git log <prev_tag>..HEAD --pretty='* %s (%h)'`. The workflow overwrites `CHANGELOG.md` only in the CI workspace. A repository's committed changelog remains untouched. Use a separate release workflow when the hand-written changelog must become the release body.
- Pre-release classification: any tag containing `alpha`, `beta`, or `rc` (case-insensitive) is marked as a pre-release on GitHub and is NOT marked as the latest release.

Trigger from `push` so it fires on branch and tag pushes.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `go_version` | string | `"1.26"` | Go toolchain version passed to `actions/setup-go`. |
| `dep_command` | string | `"make dep"` | Command to install dependencies. Set to `-` to skip it in every job. Also skipped when `is_vendored: true`. |
| `has_codegen` | boolean | `false` | This repo commits generated files. Turns on the codegen-drift job. |
| `generate_command` | string | `"make generate"` | Regenerates the committed generated files, run only when `has_codegen: true`; the job fails if the tree changed afterwards. |
| `lint_command` | string | `"make lint"` | Code-checks command. Set to `-` to skip the lint job. |
| `test_command` | string | `"make test"` | Test command. Set to `-` to skip the test job. |
| `is_vendored` | boolean | `false` | Whether dependencies are vendored. Skips `dep_command` when true. |
| `coverage_file` | string | `""` | If set, upload this file (produced by `test_command`, containing the coverage percentage) as an artifact for a downstream `create-badges.yml` job. |
| `coverage_artifact` | string | `"coverage"` | Name of the uploaded coverage artifact. |
| `scan_enabled` | boolean | `true` | Run `govulncheck` against the module. |
| `runs_on` | string | `"ubuntu-latest"` | Runner label. |
| `debug` | boolean | `false` | Emit a debug job that prints workflow context + input values. |

### Security note

`test_command`, `lint_command`, `dep_command`, and `generate_command` are interpolated into shell scripts. Callers control these strings, which is equivalent to arbitrary code execution on the runner with whatever secrets/permissions the caller workflow exposes. Only call this workflow from trusted repos with branch protection on the workflow files.

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

- `code-checks` runs each linter in `code_checks` independently (`fail-fast: false`). Defaults: `bandit`, `pylint`, `flake8`. `safety` is supported, but its upstream `check` subcommand is deprecated.
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

No `pypi_api_token` secret is needed. PyPI authenticates the workflow via OIDC. The calling job needs `id-token: write`.

## make-checks.yml

Deprecated compatibility runner for repositories whose Make targets run the
toolchain in Docker. It checks out the caller, then runs the supplied dependency,
lint, and test commands in order. It can upload a coverage artifact for
`create-badges.yml`.

New callers should use [`code-workflow.yml`](#code-workflowyml). It adds a build
gate, security SARIF upload, and generated-file drift checking.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `lint_command` | string | `"make lint"` | Lint command. Empty or `-` skips it. |
| `test_command` | string | `"make test"` | Test command. Empty or `-` skips it. |
| `dep_command` | string | `""` | Dependency command, run before lint and test. Empty or `-` skips it. |
| `coverage_file` | string | `""` | Coverage file to upload. Empty skips artifact upload. |
| `coverage_artifact` | string | `"coverage"` | Artifact name for `coverage_file`. |
| `runs_on` | string | `"ubuntu-latest"` | Runner label. |

### Example

```yaml
jobs:
  checks:
    uses: psyb0t/reusable-github-workflows/.github/workflows/make-checks.yml@master
    with:
      lint_command: "make lint"
      test_command: "make test"
      coverage_file: coverage-percent.txt
```

## code-workflow.yml

Chains a repo's own build / lint / test / sec / generate commands. No language, no toolchain setup: the toolchain lives in the repo's container and its Makefile owns everything past checkout. This flow is a dumb runner plus the CI-only plumbing (upload the coverage artifact, upload the security SARIF, check for codegen drift). All the real work is a `make X` the repo defines.

- Every `*_command` accepts `-` (preferred) or `""` to skip that step.
- `build_command` runs FIRST and gates the rest: if it fails, lint / test / sec / generate are skipped, so the run fails fast on the real problem. Leave it empty and there is no gate (lint runs first).
- `sec_command` should write a SARIF to `sarif_file`; the flow uploads it to Security > Code scanning under `sarif_category` (so a repo with both a Go and a Python leg does not overwrite itself). Needs `security-events: write` on the caller job.
- `generate_command` just runs the generators; the flow then fails on `git status` drift. Ordered last because it rewrites the tree.
- Set `coverage_file` and the file is uploaded as the artifact a downstream [`create-badges.yml`](#create-badgesyml) job reads.

**Required caller permission:** the `code` job declares `security-events: write` (for the SARIF upload), and a reusable workflow cannot request more than the caller grants. So the calling job MUST grant `security-events: write` even when it sets no `sec_command`. Omit it and the run fails at startup with no logs.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `build_command` | string | `""` | Compile gate, e.g. `make build`. Runs first; its failure skips the rest. `-` / `""` skips it. |
| `lint_command` | string | `""` | Lint command, e.g. `make lint`. `-` / `""` skips it. |
| `test_command` | string | `""` | Test command, e.g. `make test-coverage`. `-` / `""` skips it. |
| `sec_command` | string | `""` | Security scan, e.g. `make sec`; writes a SARIF to `sarif_file`. `-` / `""` skips it. |
| `generate_command` | string | `""` | Codegen, e.g. `make generate`; the flow then fails on drift. `-` / `""` skips it. |
| `coverage_file` | string | `""` | If set, uploaded as `coverage_artifact` for a downstream `create-badges.yml` job. |
| `coverage_artifact` | string | `"coverage"` | Name of the uploaded coverage artifact. |
| `sarif_file` | string | `""` | Path `sec_command` wrote SARIF to. If set, uploaded to the Security tab. |
| `sarif_category` | string | `"code"` | Code-scanning category, so multiple legs in one repo do not collide. |
| `runs_on` | string | `"ubuntu-latest"` | Runner label. |
| `debug` | boolean | `false` | Print the workflow context. |

### Security note

`build_command`, `lint_command`, `test_command`, `sec_command` and `generate_command` are interpolated into shell scripts, exactly as in [`go-workflow.yml`](#go-workflowyml). Callers control these strings, which is arbitrary code execution on the runner with whatever secrets and permissions the caller exposes. Only call this from trusted repos with branch protection on the workflow files.

### Example

Checks on every push; the image build and badges wait on them. The caller grants `security-events: write` so the sec SARIF reaches the Security tab.

```yaml
jobs:
  code:
    permissions:
      contents: read
      security-events: write
    uses: psyb0t/reusable-github-workflows/.github/workflows/code-workflow.yml@master
    with:
      lint_command: "make lint"
      test_command: "make test-coverage"
      sec_command: "make sec"
      generate_command: "make generate"
      coverage_file: coverage-percent.txt
      sarif_file: sec.sarif
      sarif_category: go

  docker:
    needs: [code]
    if: github.ref_name == github.event.repository.default_branch || startsWith(github.ref, 'refs/tags/')
    permissions:
      contents: write
      security-events: write
    uses: psyb0t/reusable-github-workflows/.github/workflows/docker-image-workflow.yml@master
    with:
      repository_name: you/yourimage
    secrets:
      dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
      dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}
```

## release-workflow.yml

Cuts a GitHub release for a tag: tag plus notes, no artifacts, since these repos ship Docker images and pip-installable packages rather than bare binaries. Uses the pre-installed `gh` CLI, not a third-party action. Pair it with [`code-workflow.yml`](#code-workflowyml) and [`docker-image-workflow.yml`](#docker-image-workflowyml) and gate it on them with `needs:`.

- Runs only on `refs/tags/*`.
- `changelog_file`: its contents become the release body. Empty means `gh` generates notes from the commits since the last tag.
- A tag matching `prerelease_match` (default `alpha` / `beta` / `rc`) is flagged as a prerelease.
- Idempotent: a re-run of a tag whose release already exists is a no-op.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `changelog_file` | string | `""` | File whose contents become the release body. Empty = generated notes. |
| `prerelease_match` | string | `"(alpha\|beta\|rc)"` | Regex of tag substrings that mark a prerelease. |
| `runs_on` | string | `"ubuntu-latest"` | Runner label. |
| `debug` | boolean | `false` | Print the workflow context. |

### Example

```yaml
jobs:
  release:
    needs: [code, docker]
    if: startsWith(github.ref, 'refs/tags/')
    permissions:
      contents: write
    uses: psyb0t/reusable-github-workflows/.github/workflows/release-workflow.yml@master
    with:
      changelog_file: CHANGELOG.md
```

## clawhub-publish.yml

Publishes **skills** and **plugins** to [ClawHub](https://clawhub.ai) through the official `clawhub` CLI. `publish_skills` and `publish_plugins` both default to `true`. A missing or empty directory skips that half. Validation runs on every call. Publishing runs only on a tag after validation passes.

**Skills:** one skill per `<skills_dir>/<name>/SKILL.md`. The CLI derives metadata and packages regular files except dotfiles and `node_modules`. A tag mirrors its version when it is newer than ClawHub's current version. Otherwise the CLI patch-bumps. `version` overrides both paths. Existing versions count as already published. The job has `contents: read`, uses the ClawHub token for publishing, pins the CLI and actions, applies the release-age gate, and installs with `npm install -g … --ignore-scripts`. ClawHub licenses its hosted skill copy as `MIT-0`. `dry_run: true` validates without publishing.

**Plugins:** one plugin per `<plugins_dir>/<name>/openclaw.plugin.json`. The workflow runs static `clawhub package validate` without `--runtime` or `--allow-execute`, then publishes. A tag updates `package.json#version` and `openclaw.plugin.json#version` when present. `npm pack` packages source without installing the plugin dependency tree. Plugin package names are npm-scoped (`@owner/name`).
- **Version.** ClawHub takes the plugin's `package.json#version` as the release version. On a tag push the git tag (leading `v` stripped) is mirrored into `package.json#version` (and `openclaw.plugin.json#version` if present) before publishing.
- **No dependency install in CI.** `package publish` packs the source (`npm pack`); a plugin's own dependency tree is resolved by the end user at their install time, never here.
- Plugin package names are npm-scoped (`@owner/name`); the scope must match a ClawHub owner you control.

**ClawHub failures are distinguished.** Service, sandbox, or network faults retry `publish_attempts` times with quadratic backoff. They fail the job by default (`fail_on_upstream_error: true`) because a green release that did not publish is wrong. Set it to `false` to report a deferred publish as a warning. A validator rejection fails immediately without retries. If the validator reported findings, fix the package. If it could not start, retry later.

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
| `publish_attempts` | number | `4` | Attempts per publish before giving up. Retries apply to ClawHub-side faults only. |
| `fail_on_upstream_error` | boolean | `true` | Fail the job when ClawHub's own service is still down after every attempt. Set `false` to downgrade to a warning + deferred summary. Rejections of your content always fail regardless. |

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

With the defaults, that publishes every skill under `.agents/skills/` and every plugin under `.agents/plugins/` on tag pushes. Drop the `if:` line to validate skills and plugins on every push. Publishing still runs only on tags.

## mcp-registry-publish.yml

Publishes a `server.json` from the caller repository root by default to the official [MCP Registry](https://registry.modelcontextprotocol.io) on tag pushes. The registry stores metadata and points at the published artifact. It does not host the artifact.

Auth is **secretless**: it uses the GitHub Actions OIDC token to prove ownership of the `io.github.<owner>/*` namespace, so there is no registry token to store. The calling job MUST grant `id-token: write`. Ownership of a referenced Docker image is verified by the registry against an `io.modelcontextprotocol.server.name` LABEL on the image, which must equal `server.json`'s `name`.

On a tag push (`vX.Y.Z`) it stamps `server.json`'s `version` to `X.Y.Z` and rewrites each `oci` package `identifier` tag to the git tag, so the entry points at the exact image the same release built. `mcp-publisher` is exact-pinned (`publisher_version`, default `v1.8.0`) behind an age-gate.

### Inputs

| Input | Default | Description |
|---|---|---|
| `server_json` | `server.json` | Path to the `server.json` at the caller repo root. |
| `publisher_version` | `v1.8.0` | Exact `mcp-publisher` release tag to install (no ranges). |
| `min_release_age_days` | `7` | Refuse an `mcp-publisher` release published more recently than this. |
| `runs_on` | `ubuntu-latest` | Runner to use. |

### Example

Runs after the image is built + pushed (so the labeled image exists), on tag pushes only:

```yaml
jobs:
  publish-to-mcp-registry:
    needs: [call-docker-image-workflow]
    if: startsWith(github.ref, 'refs/tags/')
    permissions:
      id-token: write   # secretless OIDC auth to the registry
      contents: read
    uses: psyb0t/reusable-github-workflows/.github/workflows/mcp-registry-publish.yml@master
```

## create-badges.yml

Renders status badges as flat SVGs and commits them to an orphan `badges` branch in the caller repository. It uses no third-party badge service. The badge value is baked into the committed SVG and served from `https://raw.githubusercontent.com/<owner>/<repo>/badges/<name>.svg`.

Four badge kinds ship today; add more by dropping another block into the workflow's "Render badges" step:

- **coverage:** reads a percentage from a pipeline file. It does not run tests or compute coverage. Missing input fails the job. Colors are ≥90 green, ≥80 light-green, ≥70 yellow, ≥50 orange, otherwise red.
- **license:** the repository's SPDX identifier from the GitHub API.
- **version:** the latest SemVer tag (`git tag --sort=-v:refname`).
- **imported by:** an opt-in Go-module count from pkg.go.dev. It also writes `importers.md` beside the SVGs and marks importers outside the configured owner set as **external**.

**The imported-by badge shows change blast radius, not adoption.** The external marker separates public users from your own repositories.

pkg.go.dev has no importer API. The workflow reads its HTML and distinguishes a stated total, `No known importers`, and an untrusted result. It never overwrites a real count with a guessed `0`.

So the job distinguishes **three** outcomes:

| page | badge | when it can't be trusted |
|---|---|---|
| states a total | that number, **cross-checked** against extracted links | disagreement renders `unknown` and warns |
| says `No known importers` | `0` | none |
| anything else (not indexed yet, fetch failed, no count) | `unknown` in grey | a **warning**, not a failure |

The workflow renders a stated total only when it agrees with the extracted links.

`unknown` is never rendered as `0`. "Nothing imports this" and "I could not tell" are different facts.

**No importer outcome fails the job.** A renamed module can stay `unknown` until pkg.go.dev crawls it. The workflow never renders a number the page does not support.

It lists only public packages pkg.go.dev has crawled, and the crawl lags publication by days; `importers.md` says so in the file.

The coverage value usually arrives through `go-workflow.yml`'s `coverage_file` input. The badges job writes only SVGs to the `badges` branch, with `[skip ci]` on its commit. Runs targeting the same caller repository and branch are serialized.

### Inputs

| Input | Default | Description |
|---|---|---|
| `coverage` | `false` | Generate the coverage badge by reading a percentage from a file. |
| `coverage_artifact` | `coverage` | Artifact to download the coverage file from (empty = file already in the workspace). |
| `coverage_file` | `coverage-percent.txt` | Path to the file containing the coverage percentage. |
| `license` | `true` | Generate the license badge. |
| `version` | `true` | Generate the version badge. |
| `importers` | `false` | Go modules only. Generate the imported-by badge and `importers.md` from pkg.go.dev. Off by default to avoid every caller scraping at once. |
| `importers_module` | `""` | Module path to look up. Empty means `github.com/<owner>/<repo>`. |
| `importers_own_owners` | `""` | Owners to treat as *yours* when marking external importers, space- or comma-separated. Empty means this repo's owner. Set it if you publish under more than one account or org, otherwise your own second org reads as external. Matched on whole owner segments, so `acme` does not swallow `acme-labs`. |
| `badges_branch` | `badges` | Branch the generated SVGs are committed to. |
| `runs_on` | `ubuntu-latest` | Runner to use. |

### Example

Wire `go-workflow.yml` to upload the coverage percentage, then read it here:

```yaml
jobs:
  call-go-workflow:
    uses: psyb0t/reusable-github-workflows/.github/workflows/go-workflow.yml@master
    with:
      test_command: "make test-coverage"   # must produce coverage-percent.txt
      coverage_file: "coverage-percent.txt"

  badges:
    needs: [call-go-workflow]
    if: github.ref_name == github.event.repository.default_branch || startsWith(github.ref, 'refs/tags/')
    permissions:
      contents: write   # commit the SVGs to the badges branch
    uses: psyb0t/reusable-github-workflows/.github/workflows/create-badges.yml@master
    with:
      coverage: true
```

Then embed in the README (raw, GitHub-hosted, no external service):

```markdown
![coverage](https://raw.githubusercontent.com/<owner>/<repo>/badges/coverage.svg)
![license](https://raw.githubusercontent.com/<owner>/<repo>/badges/license.svg)
![version](https://raw.githubusercontent.com/<owner>/<repo>/badges/version.svg)
```

The imported-by badge wants a link, so the count reaches the names behind it:

```markdown
[![imported by](https://raw.githubusercontent.com/<owner>/<repo>/badges/importers.svg)](https://github.com/<owner>/<repo>/blob/badges/importers.md)
```

### Refreshing the count on a schedule

An importer count goes stale on its own. To keep it current, put a `schedule:` on the **whole pipeline**, not on a badges-only job:

```yaml
on:
  push:
  schedule:
    - cron: "54 4 * * 5"
  workflow_dispatch:
```

Two things that are easy to get wrong here:

- **Schedule the entire pipeline, never a badges-only refresh.** The publish step wipes the `badges` branch and republishes only what that run produced, so a job that regenerated just the importers badge would **delete** the coverage, license and version badges.
- **Weekly beats daily.** pkg.go.dev can lag publication by days. A daily run repeats the test suite for the same count.

GitHub cron has no randomness (no Jenkins-style `H`). Spread the slot deterministically instead of picking a round number every repository converges on:

```bash
h=$(printf '%s' "<owner>/<repo>" | sha256sum | tr -d ' -')
printf '%d %d * * %d\n' $((0x${h:0:4} % 60)) $((0x${h:4:4} % 24)) $((0x${h:8:4} % 7))
```

## git-mirror.yml

Push-mirrors the caller repo to Codeberg, GitLab and/or Gitee the moment you push to GitHub, creating the destination repo if it doesn't exist yet and syncing the GitHub description (plus topics and the project URL, where the platform has them). Every target is opt-in and runs as its own job with no `needs` between them, so enabling a second platform can't break the first, and a bad token on one doesn't hold up the others.

The mirror is one-way and authoritative. `--force` overwrites target work absent from GitHub, and `prune: true` deletes target refs absent from GitHub. The copies stay byte-identical. Set `prune: false` when stale branches should remain. `disable_pull_requests: true` turns off pull and merge requests on Codeberg and GitLab because a later force-push would destroy a merged mirror PR. Issues and forking remain enabled. [`issue-pull.yml`](#issue-pullyml) brings mirror issues back to GitHub.

Two implementation details are deliberate and worth knowing before you copy the pattern elsewhere:

- **It bare-clones the source rather than using `actions/checkout` plus `git push --all`.** A checkout has one local branch. The bare clone carries every head and tag, then pushes explicit `+refs/heads/*` and `+refs/tags/*` refspecs.
- **Every API call uses `curl --fail-with-body`.** The response body reaches the error annotation. Plain `curl -s` would let a 401, 404, or 500 look successful.

The synced description gets `description_prefix` and is capped at `description_max_length`. The cap counts characters, not bytes. GitLab and Gitee reject descriptions over 2000 characters.

Pushing a commit and its tag together starts two runs close together. Runs are serialized per caller repository without `cancel-in-progress` because each ref must reach the targets. A failed create re-checks for an existing target repository before failing.

Platform differences that aren't obvious:

| Platform | Description | Topics | Project URL | Notes |
|---|---|---|---|---|
| Codeberg (Gitea) | yes | yes | yes (`website`) | Gitea rejects the whole topics array if one entry is invalid, so topics are lowercased, stripped to `[a-z0-9-]`, de-duped and capped at 25. A rejection the normalizer doesn't model is a warning, not a failed mirror. |
| GitLab | yes | yes | **no** → README | Project creation needs an `api` token. The homepage goes in the README because GitLab exposes no writable project-URL field. The workflow strips default-branch protection because it blocks mirror force-pushes. |
| Gitee | yes | **no** | yes (`homepage`) | `name` is required on the repository-edit call, so the workflow sends it unchanged. |

**GitLab has nowhere to put a project URL, so it goes in the README.** GitLab is the only target with no writable homepage field, and its README *is* the project landing page. When the GitHub repo has a homepage set, `readme_url_header` (default `true`) prepends it as a markdown link at the top of the README on the mirror's default branch.

This is the one intentional GitLab mirror difference. The default branch gets one README-header commit when a homepage and README exist. The commit uses the source tip date, so an unchanged source produces the same SHA. Set `readme_url_header: false` for an exact mirror.

**GitLab auto-protects the default branch.** A mirror force-push then fails after its first run. The workflow removes the target's protected-branch rules.

The workflow removes every protected-branch rule because a wildcard such as `release/*` blocks a force-push too. If it cannot remove a rule, it names the branch in a warning.

**A rejected topic does not block the rest.** GitLab validates all topics together. On rejection, the workflow syncs the description and adds topics one at a time, warning for each rejected topic.

**Gitee visibility.** Gitee can create a private repository when the requested one is public and the account lacks a bound mobile number. The workflow reads the result back and warns.

### Inputs

| Input | Default | Description |
|---|---|---|
| `codeberg_enabled` | `false` | Mirror to Codeberg. |
| `gitlab_enabled` | `false` | Mirror to GitLab. |
| `gitee_enabled` | `false` | Mirror to Gitee. |
| `create_missing` | `true` | Create the repo on the target when it doesn't exist yet. |
| `sync_metadata` | `true` | Sync the GitHub description (and topics / project URL, where supported). |
| `description_prefix` | `""` | Prepended to the synced description. Empty by default. |
| `disable_pull_requests` | `true` | Turn the pull/merge request feature OFF on the mirror. Issues and forking stay on. |
| `description_max_length` | `2000` | Cap on the synced description, in **characters**. Over it, the text is cut and ends in `...`. |
| `prune` | `true` | Delete refs on the target that no longer exist here. |
| `max_attempts` | `3` | Attempts per network operation (the bare clone and the force push), including the first. |
| `backoff_seconds` | `10` | Base delay between attempts; doubles each retry. |
| `readme_url_header` | `true` | On targets with no project-URL field (GitLab only), prepend this repo's homepage as a link at the top of the README on the mirror's default branch. Costs one extra commit on that branch. No effect without a homepage or a README. |
| `codeberg_url` | `https://codeberg.org` | Base URL of the Codeberg/Gitea instance. |
| `target_owner` | `""` | Owner/namespace on Codeberg, GitLab and Gitee (empty = this repo's owner). |
| `runs_on` | `ubuntu-latest` | Runner to use. |

### Secrets

| Secret | Needed for | Description |
|---|---|---|
| `codeberg_token` | Codeberg | Token with repo write + create scope. |
| `gitlab_token` | GitLab | PAT with `api` scope. |
| `gitee_token` | Gitee | Private access token with projects scope. |
| `gitee_user` | Gitee | Username for the push. Defaults to the target owner. |

A target that's enabled with an empty secret fails immediately with a message naming the exact secret to set, rather than failing deep inside a push.

### Example

Trigger on every branch and tag so nothing is missed:

```yaml
name: pipeline

on:
  push:
    branches: ['**']
    tags: ['**']

jobs:
  git-mirror:
    uses: psyb0t/reusable-github-workflows/.github/workflows/git-mirror.yml@master
    with:
      codeberg_enabled: true
      gitlab_enabled: true
      gitee_enabled: true
    secrets:
      codeberg_token: ${{ secrets.CODEBERG_TOKEN }}
      gitlab_token: ${{ secrets.GITLAB_TOKEN }}
      gitee_token: ${{ secrets.GITEE_TOKEN }}
```

## issue-pull.yml

Copies issues and replies from the Codeberg and GitLab mirrors into GitHub, so the mirrors can carry a conversation without anyone having to watch them. [`git-mirror.yml`](#git-mirroryml) turns pull requests **off** on those copies but leaves issues on. A visitor who finds the project on a mirror can still open an issue, and this job brings that conversation home.

**Direction is the design.** The workflow reads mirrors and writes only to GitHub. The built-in `GITHUB_TOKEN` is scoped to the caller repository and expires with the job. A mirror-side bot would require a GitHub token stored on a third-party forge.

**The relayed issue and replies are authored by `github-actions[bot]`, never by you.** An issue that claims to be written by you but was not is false, and it also notifies you about something you did not write. Public imports name their original author as a link to that person's GitLab or Codeberg profile, with a direct source link beside it. Confidential GitLab imports keep only the source issue link. A bot-authored write also does not re-trigger workflows, so there is no loop to guard against.

**State lives in the relayed issues themselves.** Each issue carries an invisible source marker. Each imported reply carries a marker for its source comment ID. The next run uses those markers to create missing replies and update an already imported reply when its source text changes. A run that dies halfway picks up again without a cache or state file.

What propagates, and what deliberately doesn't:

| | |
|---|---|
| Public issue opened or edited on a mirror | → opened or refreshed here, labelled `relayed` + `codeberg`/`gitlab`, with the original author linked |
| Public reply added or edited on a mirror | → created or updated here, with the original author and source reply linked |
| Confidential GitLab issue or reply | → generic GitHub breadcrumb with only the source issue link. No title, author, body, attachment, reply text, or comment author is copied. The source link still requires GitLab permission. |
| Root-relative source attachment link | → rewritten to the source forge, never accidentally to GitHub |
| Issue closed or reopened on a mirror | → closed or reopened here, with a state note and the source link |
| Reviews and labels | Not synced. The mirror only reads issues and issue replies. |

**Issue lists fall back to anonymous reads.** An under-scoped token can turn a public request into a `403`, so the workflow retries without it and warns. GitLab can restrict public note reads, though. Set `gitlab_token` with `api` scope when you want GitLab replies mirrored. Without it, the issue and its state still sync, but the workflow warns and leaves replies alone.

If a previously public GitLab issue becomes confidential, the next run replaces the copied title and body with the generic breadcrumb and removes only the bot-authored replies imported from that source. Human GitHub comments stay put.

**Jitter prevents an account-wide cron burst.** `jitter_seconds` defaults to 600 and sleeps before the first request. Set it to `0` for manual runs.

### Inputs

| Input | Default | Description |
|---|---|---|
| `codeberg_enabled` | `true` | Pull issues from the Codeberg mirror. |
| `gitlab_enabled` | `true` | Pull issues from the GitLab mirror. |
| `codeberg_url` | `https://codeberg.org` | Base URL of the Codeberg/Gitea instance. |
| `target_owner` | `""` | Owner on Codeberg + GitLab. Defaults to this repo's owner. |
| `jitter_seconds` | `600` | Upper bound on a random delay before the first request. |
| `label` | `relayed` | Label put on every relayed issue and used to find it again. Changing it orphans issues relayed under the old label. |
| `runs_on` | `ubuntu-latest` | Runner to use. |

### Secrets

Both are optional for issue lists. Set `gitlab_token` when GitLab requires authentication to read source replies.

| Secret | Description |
|---|---|
| `codeberg_token` | Authenticates Codeberg reads. The workflow falls back to anonymous reads when it can. |
| `gitlab_token` | Authenticates GitLab reads. Use a token with `api` scope to mirror replies when the notes API rejects anonymous access. |

### Example

```yaml
name: issue-pull

on:
  schedule:
    # Stagger the minute per repo; the job jitters on top of it.
    - cron: "23 */6 * * *"
  workflow_dispatch:

jobs:
  issue-pull:
    permissions:
      issues: write
    uses: psyb0t/reusable-github-workflows/.github/workflows/issue-pull.yml@master
    with:
      jitter_seconds: ${{ github.event_name == 'schedule' && 600 || 0 }}
    secrets:
      codeberg_token: ${{ secrets.CODEBERG_TOKEN }}
      gitlab_token: ${{ secrets.GITLAB_TOKEN }}
```

The caller job needs `permissions: issues: write`. A reusable workflow cannot grant itself more permissions.

## archive.yml

Pushes the caller repo into public archives so it survives the platform it lives on. Three targets, covering three different failure modes:

- **Wayback Machine** archives the rendered page, including the README and homepage.
- **Software Heritage** archives the git object graph, including every commit and blob.
- **archive.org item** uploads the working tree as a browsable archive.org item. It needs the archive.org key pair.

**The first two need no API key.** Both use plain `curl`, not a third-party action. They are anonymous-friendly and rate-limited.

- **Every request retries with exponential backoff.** `max_attempts` defaults to 5 and `backoff_seconds` to 30. The workflow retries 429, 404, 5xx, and timeouts. Save Page Now can return 404 while overloaded.
- **A failed archive job goes red by default.** It is independent, so nothing needs it. Set `fail_on_error: false` to report the failure without failing the caller.

The bundled `mirror-and-archive.yml` caller sets `fail_on_error: false`: it is
an auxiliary durability job attached to a source push, so a provider outage is
reported as a warning without turning the caller's release pipeline red. Call
`archive.yml` directly with its default when an archive confirmation is a gate
for your own workflow.

**Save Page Now caps captures per URL per day.** A jobless 200 with `status_ext=error:too-many-daily-captures` means the existing captures satisfy the request. Other jobless 200 responses fail.

**Wayback is slow.** `url_timeout_seconds` defaults to 180. A timeout retries because Wayback can complete after the client gives up.

By default it archives the repo's GitHub page plus the URL set as the repo's homepage (`include_homepage`), and `extra_urls` takes any others, one per line.

**Archiving the pages your README links to needs archive.org keys**, and the keyless path fails at it in the worst way: `capture_outlinks` is *silently ignored* rather than refused. The save returns HTTP 200, the page itself lands in the archive, and not one linked page does.

Outlink capture exists only on the authenticated Save Page Now v2 API. The keyless `GET /save/<url>` fallback takes no options.

Generate an S3 key pair at [archive.org/account/s3.php](https://archive.org/account/s3.php) and pass them as `archiveorg_access_key` / `archiveorg_secret_key`. They're named for the **account**, not for one caller: the same two values sign Save Page Now, the S3 upload API and the metadata API alike. With them the job switches to the v2 API and `capture_outlinks` (default `true`) and `capture_screenshot` (default `false`) start working. Without them everything still runs and the job emits a warning, so the gap is visible instead of silent.

**The archive.org item is browsable.** The workflow uploads the working tree as one tarball and attaches GitHub metadata. It excludes `.git` because Software Heritage archives the history.

Two things about it are worth understanding before you enable it elsewhere:

- **It skips unchanged source.** The item records `sourcerevision`. A matching HEAD uploads nothing. A failed upload leaves no revision, so a later run retries.
- **New item creation is rate-limited.** `max_new_items_per_day` defaults to 5 and queries archive.org for today's items with this prefix. Existing items can still upload. The job exits green over the ceiling.

`item_identifier_prefix` (default `psyb0t-`) is not decoration. **archive.org identifiers are global and permanent**; claiming an unprefixed one is a landgrab that eventually collides with someone else's project of the same name.

### Inputs

| Input | Default | Description |
|---|---|---|
| `wayback_enabled` | `true` | Archive pages to the Wayback Machine. |
| `software_heritage_enabled` | `true` | Archive the git history to Software Heritage. |
| `include_homepage` | `true` | Also archive the repo's homepage URL, when it has one. |
| `extra_urls` | `""` | Additional URLs to archive, one per line. |
| `capture_outlinks` | `true` | Also archive pages linked from an archived page. **Requires archive.org keys.** The keyless API ignores it. |
| `capture_screenshot` | `false` | Also store a screenshot of each page. Same key requirement. |
| `item_upload_enabled` | `true` | Upload the working tree to archive.org as a browsable item. Needs the key pair. |
| `item_identifier_prefix` | `psyb0t-` | Prefixed to the repo name to form the archive.org identifier. Identifiers are global and permanent. |
| `max_new_items_per_day` | `5` | Ceiling on NEW items created per day across the account. Over it the job exits green and leaves the rest to a later run. |
| `item_collection` | `opensource` | archive.org collection to file the item under. |
| `fail_on_error` | `true` | Fail when a request remains refused after all retries. Nothing needs this job, so it does not block the caller's release work. |
| `max_attempts` | `5` | Attempts per request, including the first. |
| `backoff_seconds` | `30` | Base delay between attempts; doubles each retry. |
| `url_timeout_seconds` | `180` | Per-URL budget for a Wayback save. |
| `runs_on` | `ubuntu-latest` | Runner to use. |

### Secrets

Both optional. Without them the Wayback and Software Heritage jobs still run using the keyless save; the item upload skips with a warning.

| Secret | Description |
|---|---|
| `archiveorg_access_key` | archive.org S3 access key from [archive.org/account/s3.php](https://archive.org/account/s3.php). The pair signs Save Page Now, the S3 upload API, and the metadata API. Needed for `capture_outlinks`, `capture_screenshot`, and item upload. |
| `archiveorg_secret_key` | The paired secret key. |

### Example

Keyless setup archives the repository page and homepage:

```yaml
name: archive
on:
  release:
    types: [published]

jobs:
  archive:
    uses: psyb0t/reusable-github-workflows/.github/workflows/archive.yml@master
    with:
      extra_urls: |
        https://example.com/docs/my-project
```

With keys, the workflow also captures outlinks and publishes a browsable archive.org item:

```yaml
jobs:
  archive:
    uses: psyb0t/reusable-github-workflows/.github/workflows/archive.yml@master
    secrets:
      archiveorg_access_key: ${{ secrets.ARCHIVEORG_ACCESS_KEY }}
      archiveorg_secret_key: ${{ secrets.ARCHIVEORG_SECRET_KEY }}
```

## License

[WTFPL](http://www.wtfpl.net/). Do What The Fuck You Want To Public License. See [LICENSE](LICENSE).
