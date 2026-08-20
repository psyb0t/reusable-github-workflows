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
  - [make-checks.yml](#make-checksyml)
  - [clawhub-publish.yml](#clawhub-publishyml)
  - [mcp-registry-publish.yml](#mcp-registry-publishyml)
  - [create-badges.yml](#create-badgesyml)
  - [git-mirror.yml](#git-mirroryml)
  - [issue-pull.yml](#issue-pullyml)
  - [archive.yml](#archiveyml)
- [License](#license)

## Shared conventions

Every workflow here holds to the same rules, so a caller inherits them for free:

- **Third-party actions pinned by full commit SHA** — never a floating tag, so a re-pointed or compromised upstream tag can't silently change what runs.
- **Least-privilege permissions** — the top level is `permissions: {}`; each job opts in to only the scopes its steps need (`contents: read`, `security-events: write`, …).
- **Concurrency matches the resource** — a newer push on the same ref supersedes ordinary in-flight work (tag pushes always complete); badge publishing serializes writers for each caller repository and output branch; mirroring serializes per caller repository without cancelling, since each run carries a real ref that still has to reach the targets.
- **Triggered from `push`** — you wire `on: [push]`; the workflow itself decides what to act on (branch vs. tag) and no-ops on refs it doesn't handle.
- **Supply-chain discipline on any tooling install** — exact version pins, an age-gate that refuses freshly-published releases, and `npm install --ignore-scripts`.
- **Network operations retry with exponential backoff** — clones, pushes, package installs, release downloads. A registry 502 or a reset connection shouldn't cost you a whole run. What retrying is *not* for: turning a real failure green. Every retried operation still fails the job if it never succeeds, and the scanners (`govulncheck`, `pip-audit`) are deliberately excluded — they exit non-zero when they *find* something, so retrying them would re-run a genuine finding and just report it slower.
- **Fail honestly, but don't block what shouldn't be blocked** — a job that couldn't do its work goes red rather than reporting a green run that did nothing. The way to avoid a red run blocking unrelated work is to keep the job independent (nothing `needs:` it), not to swallow the failure.

## Workflows

| Workflow | What it does |
|---|---|
| [`collaborators-only-workflow.yml`](#collaborators-only-workflowyml) | Close (and optionally lock) PRs from non-collaborators. |
| [`docker-image-workflow.yml`](#docker-image-workflowyml) | Buildx multi-arch / multi-target Docker Hub publish + SBOM/provenance + Grype scan → Security tab + GitHub Release. |
| [`go-workflow.yml`](#go-workflowyml) | Go lint / test / `govulncheck` + GitHub Release on tag. |
| [`python-package-workflow.yml`](#python-package-workflowyml) | Python lint matrix / test / build / `pip-audit` + PyPI publish (token or OIDC) + GitHub Release on tag. |
| [`code-workflow.yml`](#code-workflowyml) | Chain a repo's own build / lint / test / sec / generate commands (no toolchain setup), upload coverage + a security SARIF, check codegen drift. For projects whose toolchain lives in their container. |
| [`release-workflow.yml`](#release-workflowyml) | Cut a GitHub release for a tag (tag + notes, no artifacts) via the gh CLI. |
| [`clawhub-publish.yml`](#clawhub-publishyml) | Validate + publish skills and plugins to [ClawHub](https://clawhub.ai) via the official CLI. |
| [`mcp-registry-publish.yml`](#mcp-registry-publishyml) | Publish a `server.json` to the official [MCP Registry](https://registry.modelcontextprotocol.io) on tag, secretless via GitHub OIDC. |
| [`create-badges.yml`](#create-badgesyml) | Self-render coverage / license / version / imported-by SVG badges (no third-party service) and commit them to an orphan `badges` branch. |
| [`git-mirror.yml`](#git-mirroryml) | Push-mirror every branch + tag to Codeberg / GitLab / Gitee, creating the repo and syncing description + topics. |
| [`issue-pull.yml`](#issue-pullyml) | Copy issues opened on the Codeberg / GitLab mirrors into GitHub, and close the copy when the original closes. |
| [`archive.yml`](#archiveyml) | Push the repo into the Wayback Machine (pages), Software Heritage (git history) and archive.org (a browsable item of the source itself). |

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
| `allow_authors` | string | `dependabot[bot],dependabot-preview[bot]` | Comma-separated PR author logins that bypass the collaborator check. For trusted bots whose PRs are meant to be reviewed and merged — closing one is also a dead notification path, since a bot-opened, bot-closed PR pings nobody and just vanishes into the Closed tab. |

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
- Updates the Docker Hub repository description (the **Overview** tab) from the repo's `README.md` after every successful push via `peter-evans/dockerhub-description`.

> **The Docker Hub token needs Read, Write AND Delete.** That is more than it sounds and it is worth getting right before the first run. Pushing an image only needs Write — but writing repository *metadata* (the description, the README, the visibility flag) sits behind the same scope Docker Hub uses for Delete, and there is no tier between the two. A Read/Write token pushes images perfectly well and then fails every metadata call with `access denied: insufficient scope`, which reads like a broken workflow rather than a token problem. Nothing in this workflow ever issues a `DELETE`; the scope is required only because Docker Hub bundles it.
- Generates SBOM + max-mode provenance attestations by default (toggle off with `attestations: false` if your registry rejects OCI attestation manifests).
- On tag pushes, creates a GitHub Release once the build succeeds.
- Optionally scans the pushed image with Grype (`anchore/scan-action`) after push, and uploads the findings as SARIF to the repo's **Security → Code scanning** tab. **Scan runs after the artifact is already published, so it never blocks the push or the GitHub Release.** **A finding does not fail the run by default** (`scan_fail_build: false`). Any image on a real base accumulates upstream CVEs continuously, most with no fix available, so failing on them just turns the pipeline permanently red and the signal stops meaning anything — the Security tab is where findings are meant to be read, and they land there regardless. Set `scan_fail_build: true` for an image where a vulnerability genuinely must block the release. Leaving it false is also what lets a downstream job (e.g. another reusable workflow) `needs:` this one. The SARIF upload needs `permissions: security-events: write` on the caller's job (see below); without it, scanning still runs but the Security tab isn't populated.

Trigger from `push` so it fires on branch and tag pushes. The workflow itself only acts on `refs/heads/main`, `refs/heads/master`, and `refs/tags/*` — pushes to other branches do nothing.

**The Docker Hub page is kept in step with the GitHub one.** Three things drift otherwise, and all three are invisible until someone lands on the Docker Hub page and finds nothing useful:

- **Visibility.** Pushing to a repository that does not exist creates it, taking its visibility from the account's default preference. That makes the result depend on a setting nobody looks at — and a repository that came out private still produces a green run with a successful push that nobody else can pull. `dockerhub_private` (default `false`) is read back after every push and corrected when it differs.
- **The short description.** Set from the GitHub repository description, so the two cannot diverge. Docker Hub caps it at **100 characters**; longer text is cut to end in `...`, counting codepoints rather than bytes — a byte count would slice a multi-byte character in half.
- **Links.** Docker Hub has no field for a project URL or a source URL, the same gap GitLab has. With `readme_url_header` (default `true`) a source link — plus the project page when the repo has a homepage — is prepended to the long description. Only the copy pushed to Docker Hub is affected; the README in the repository is untouched.

Topics are deliberately **not** synced: Docker Hub's `categories` are a fixed taxonomy rather than free-form tags, so GitHub topics have nothing to map onto.

**Suppressing a CVE you have actually assessed — `scan_vex_file`.** An image on a real base carries upstream CVEs in code it never executes. A blanket ignore list is the wrong answer to that, because it reads identically to "we stopped looking". An [OpenVEX](https://openvex.dev) document is the right one: it names the CVE, states `not_affected`, gives a machine-readable justification (`vulnerable_code_not_in_execute_path` and friends) plus a human impact statement, and lives in the repo where it gets reviewed like any other file.

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

**A VEX-suppressed finding leaves the Security tab as well as the build result.** That is the point of it — but it also means a wrong assertion hides a real vulnerability with nothing left in the UI to notice. One statement per CVE, with the impact statement spelling out why the code is unreachable, reviewed like code. `scan_only_fixed` is the blunter companion: it hides everything with no published fix, which is honest triage for a base image and also hides genuinely unfixed problems.

Setting `scan_vex_file` makes the scan job check the repository out — it otherwise needs nothing from it, only the pushed image — so that job grants `contents: read`.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `repository_name` | string | **required** | Docker Hub repo, e.g. `psyb0t/voidalpha`. |
| `target_platforms` | string | `"linux/amd64,linux/arm64"` | Comma-separated buildx platforms. Overridable per matrix entry. |
| `build_targets` | string (JSON) | `""` | Multi-target build matrix (see below). Empty = single-image build. |
| `scan_enabled` | boolean | `true` | Run Grype scan against the pushed image + upload SARIF to the Security tab. |
| `scan_severity` | string | `"medium"` | Grype severity threshold to fail on: `negligible`, `low`, `medium`, `high`, `critical`. |
| `scan_fail_build` | boolean | `false` | Fail the run on a finding at/above `scan_severity`. Off by default — upstream CVEs are continuous and mostly unfixable, so failing on them makes the pipeline permanently red for no signal; findings still reach the Security tab. Set `true` where a vuln must block the release. Populating the Security tab needs `permissions: security-events: write` on the caller job. |
| `scan_vex_file` | string | `""` | Path in the repo to an [OpenVEX](https://openvex.dev) document, passed to Grype as `--vex`. For a CVE you have **assessed** as not affecting this image. See below — suppressed findings leave the Security tab too. |
| `scan_only_fixed` | boolean | `false` | Only report vulnerabilities that have a fix available. |
| `dockerhub_private` | boolean | `false` | Visibility the Docker Hub repo should have. Read after every push and corrected when it differs — see below. |
| `sync_description` | boolean | `true` | Set the Docker Hub short description from the GitHub repo description (cut to 100 characters), and compose the long one. |
| `readme_url_header` | boolean | `true` | Prepend source + project-page links to the long description on Docker Hub. The repo's own README is not modified. |
| `cache_mode` | string | `"max"` | Buildx GHA cache mode. Use `min` for smaller cache exports. Cache export is best-effort: a cache-service failure warns but never blocks an image push. |
| `attestations` | boolean | `true` | Emit SBOM + max-mode provenance attestations. Disable if your registry rejects OCI attestation manifests. |
| `free_disk_space` | boolean | `true` | Free ~25-30 GB before build (Android SDK, .NET, Haskell, large apt packages, preloaded docker images). **Disable for self-hosted runners** — wipes shared host directories. |
| `runs_on` | string | `"ubuntu-latest"` | Runner label. Use your self-hosted runner label + `free_disk_space: false`. |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `dockerhub_username` | yes | Docker Hub username. |
| `dockerhub_token` | yes | Docker Hub access token (NOT the account password). **Needs Read, Write and Delete** — see below. |

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

This is the default posture, so `scan_fail_build: false` below is only shown for clarity — findings land in the Security tab and the run stays green. Grant `security-events: write` so the SARIF actually uploads. A green run is also what lets another job `needs:` this one:

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

Without `stage`, every target builds in parallel — so a `Dockerfile.full` that
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

- `dep_command`, `lint_command` and `test_command` accept `-` (preferred) or `""` to skip that step entirely. `-` is preferred because an empty string in a caller's YAML is indistinguishable from a templating accident, while `-` reads as a deliberate opt-out. `generate_command` is the exception — it has no `-` escape, because `has_codegen` already decides whether that job runs.
- Lint job runs unless `lint_command` is disabled. Test job runs unless `test_command` is disabled. Vulnerability scan (`govulncheck@v1.3.0`) runs unless `scan_enabled: false`.
- Codegen drift (`generate-check` job) runs `generate_command`, then fails if the working tree moved. It catches a source change whose generator was never re-run, and a hand-edit to a generated file that the next regeneration would silently wipe — neither breaks the build, so only a diff finds them. The check is `git status --porcelain`, not `git diff`, so a generator emitting a brand-new uncommitted file is caught too (`.gitignore` is still respected). **Off by default** — set `has_codegen: true` in a repo that commits generated files. A repo that generates nothing has no drift to check and usually has no `generate` target either.
  - The generator must be idempotent. One that stamps a timestamp or hostname, or iterates a map in random order, will fail on every run — pin the generator version (for Go, the `go.mod` `tool` block) rather than disabling the job.
- Release job runs only on `refs/tags/*`, gated on: `code-checks` succeeded or was skipped, `test` succeeded or was skipped, `generate-check` succeeded or was skipped, and (when `scan_enabled: true`) `security-scan` succeeded.
- Release notes: the workflow writes a `CHANGELOG.md` in the CI working tree from `git log <prev_tag>..HEAD --pretty='* %s (%h)'` and uses it as the release body. **If your repo already has a hand-written `CHANGELOG.md`, it is overwritten only in the CI workspace** — your committed file is unaffected, but the release body on GitHub will be the auto-generated commit list, not your file. To use a hand-written changelog as the release body, do the release yourself instead of via this workflow.
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

**A ClawHub outage does not fail your release.** Publishing distinguishes two kinds of failure and treats them differently:

- **ClawHub-side fault** — their sandbox, service or network broke: `plugin-inspector-error` / "could not inspect", `ENOENT` under `/home/sbx_user*`, a Convex stack trace, HTTP 429/5xx, `ECONNRESET`, `socket hang up`. These are retried `publish_attempts` times with quadratic backoff (5s, 20s, 45s…). If ClawHub never recovers the job **fails** (`fail_on_upstream_error`, default `true`) — a green run that did not publish reads as "shipped" and is how a package quietly drifts versions behind the repo that owns it. Set `fail_on_upstream_error: false` to downgrade that to a `::warning::` plus a **deferred** line in the summary and let the run go green; the tag is already cut and the artifact is unchanged either way, so re-running the job once their service is back publishes it.
- **Rejection of your content** — their validator ran and found something in your skill or plugin ("blocked publish: N breakages", "validation failed"). This **fails on the first attempt with no retries**, because retrying a real defect just wastes minutes and hides it.

The discriminator is whether their validator *ran*: an inspector that reported findings is your problem, an inspector that could not start is theirs.

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

With the defaults, that publishes every skill under `.agents/skills/` and every plugin under `.agents/plugins/` on tag pushes — no `with:` block needed. Drop the `if:` line to also validate skills + plugins on every push (publishing still fires only on tags, enforced inside the workflow).

## mcp-registry-publish.yml

Publishes a `server.json` (default: caller repo root) to the official [MCP Registry](https://registry.modelcontextprotocol.io) on tag pushes. The registry stores metadata only — it points at the already-published artifact (e.g. a Docker Hub image), it does not host it.

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

Renders status badges as flat SVGs and commits them to an orphan `badges` branch in the caller repo. There is no third-party render service in the path — no shields.io, no codecov — so a badge embedded in a README keeps rendering for as long as the repo exists. The value is baked into the committed SVG at creation time; nothing stays live behind it. The badge files are served straight from GitHub at `https://raw.githubusercontent.com/<owner>/<repo>/badges/<name>.svg`.

Four badge kinds ship today; add more by dropping another block into the workflow's "Render badges" step:

- **coverage** — a **dumb reader**. It reads a percentage out of a file and renders it. It does NOT run tests, set up Go, or compute anything — producing that number is entirely your pipeline's job. Point it at a file your pipeline produced (default: downloaded from the `coverage` artifact, file `coverage-percent.txt`). If the coverage badge is enabled and the file is missing, the job **fails**. Colored by threshold (≥90 green, ≥80 light-green, ≥70 yellow, ≥50 orange, else red).
- **license** — the repo's detected license SPDX id (from the GitHub API).
- **version** — the latest SemVer tag (`git tag --sort=-v:refname`).
- **imported by** (Go modules, opt-in) — how many public packages import this module, read from pkg.go.dev. It also writes `importers.md` next to the SVGs: the importing repositories, grouped, package counts descending, each linked, and marked `— **external**` when the owner isn't one of yours. Link the badge at that file so the count is one click from the names.

**The imported-by badge is a blast-radius indicator, not an adoption metric**, and the distinction decides how strictly you have to version the module. A library with no stars can still be imported by dozens of packages — nobody stars a logging or error dependency, they just import it — but if every one of those is your own repo, that means "I use my own library", not that the public depends on it. The `— **external**` mark and the count above the table are what tell those apart.

pkg.go.dev has no API for this, so the count only exists in the page's HTML — which means a changed selector, a failed fetch, and "genuinely nobody imports it" would all produce the same answer unless they're told apart. On a schedule a wrongly-rendered `0` would overwrite a real count while still looking like data.

So the job distinguishes **three** outcomes:

| page | badge | when it can't be trusted |
|---|---|---|
| states a total | that number, **cross-checked** against the links it extracts | disagreement renders `unknown` and **warns** — real drift, but a count that disagrees with its own page is worse than none |
| says `No known importers` | `0` | — |
| anything else (not indexed yet, fetch failed, no count) | `unknown` in grey | a **warning**, not a failure |

The cross-check is the interesting part: the total is read twice by different means — the links, and the count stated in prose — and a number is rendered only if the two agree.

`unknown` is never rendered as `0`. "Nothing imports this" and "I could not tell" are different facts.

**No row fails the job**, drift included. This step is all-or-nothing: coverage, version and license are already rendered by the time the importers page is read, and the publish step runs once at the end — so exiting here threw those three away and reddened the run over a badge that wasn't its subject. A freshly renamed module sits in the `unknown` state for days until pkg.go.dev crawls it, and that is not a build failure. What none of the rows will do is print a number the page doesn't support.

It lists only public packages pkg.go.dev has crawled, and the crawl lags publication by days; `importers.md` says so in the file.

The coverage value typically arrives via an artifact an earlier job uploaded — pair this with `go-workflow.yml`'s `coverage_file` input (below), which uploads the percentage file your `test_command` produced. The badges job writes ONLY the SVGs to the `badges` branch; its commit is marked `[skip ci]` so publishing badges never re-triggers a pipeline. Invocations targeting the same caller repository and `badges_branch` are serialized, so default-branch pushes (coverage freshness) and tag pushes (the released version) can safely update the same branch.

### Inputs

| Input | Default | Description |
|---|---|---|
| `coverage` | `false` | Generate the coverage badge by reading a percentage from a file. |
| `coverage_artifact` | `coverage` | Artifact to download the coverage file from (empty = file already in the workspace). |
| `coverage_file` | `coverage-percent.txt` | Path to the file containing the coverage percentage. |
| `license` | `true` | Generate the license badge. |
| `version` | `true` | Generate the version badge. |
| `importers` | `false` | Go modules only. Generate the imported-by badge and the `importers.md` backlink list from pkg.go.dev. Off by default because every caller pins this workflow at `@master` — on by default would start scraping from every repo at once. |
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

An importer count goes stale on its own, unlike coverage or version, which change only when you push. To keep it current, put a `schedule:` on the **whole pipeline** — not on a badges-only job:

```yaml
on:
  push:
  schedule:
    - cron: "54 4 * * 5"
  workflow_dispatch:
```

Two things that are easy to get wrong here:

- **Schedule the entire pipeline, never a badges-only refresh.** The publish step wipes the `badges` branch and republishes only what that run produced, so a job that regenerated just the importers badge would **delete** the coverage, license and version badges.
- **Weekly beats daily.** pkg.go.dev's crawl lags publication by days, so a daily run re-derives an unchanged number six extra times a week — and each one drags your full test suite along, since the badges job needs the coverage artifact.

GitHub cron has no randomness (no Jenkins-style `H`), so spread the slot deterministically instead of picking a round number every repo converges on — the scheduler is best-effort and sheds queued runs hardest at popular times:

```bash
h=$(printf '%s' "<owner>/<repo>" | sha256sum | tr -d ' -')
printf '%d %d * * %d\n' $((0x${h:0:4} % 60)) $((0x${h:4:4} % 24)) $((0x${h:8:4} % 7))
```

## git-mirror.yml

Push-mirrors the caller repo to Codeberg, GitLab and/or Gitee the moment you push to GitHub, creating the destination repo if it doesn't exist yet and syncing the GitHub description (plus topics and the project URL, where the platform has them). Every target is opt-in and runs as its own job with no `needs` between them, so enabling a second platform can't break the first, and a bad token on one doesn't hold up the others.

The mirror is one-way and authoritative. `--force` means anything pushed directly to a target that GitHub doesn't have is overwritten, and `prune: true` (the default) deletes refs there that no longer exist here — so the copies stay byte-identical to GitHub. Set `prune: false` if you'd rather stale branches linger than vanish. These are read-only mirrors, and `disable_pull_requests` (default `true`) makes that structural rather than a request: the pull/merge request feature is switched off on Codeberg and GitLab. A PR merged on a mirror is destroyed by the very next force-push, and unlike GitHub — where a workflow can close one with an explanation — neither platform can refuse it, so the honest move is to remove the button and let a contributor find out *before* writing the patch. Issues stay enabled, and so does forking; see [`issue-pull.yml`](#issue-pullyml) for getting those issues back.

Two implementation details are deliberate and worth knowing before you copy the pattern elsewhere:

- **It bare-clones the source instead of `actions/checkout` + `git push --all`.** A checkout creates exactly ONE local branch — every other branch stays a remote-tracking ref — so `--all` silently mirrors a single branch and quietly drops the rest. The bare clone carries all heads and tags, and the push uses explicit `+refs/heads/*` / `+refs/tags/*` refspecs.
- **Every API call uses `curl --fail-with-body`, and the response body ends up in the error annotation.** Plain `curl -s` exits 0 on 401 / 404 / 500, so `set -euo pipefail` does *not* catch a revoked token or a missing scope — the step would go green having synced nothing. Discarding the body with `-o /dev/null` is almost as bad: the first live failure reported nothing but `curl: (22) ... error: 422`, with the message explaining it thrown away.

The synced description is prefixed with `description_prefix` (empty by default) and capped at `description_max_length`, cut to end in `...` when it would exceed that. **The cap is in characters, not bytes** — GitLab and Gitee both reject anything past 2000 and Gitee states its limit that way (`最长为 2000 个字符`), so the truncation runs through `jq`, which counts codepoints. Bash's `${#var}` counts bytes and would cut a description containing any multi-byte character short of the real limit.

Pushing a commit and its tag together starts two runs about a second apart, so runs are serialized per caller repository (without `cancel-in-progress` — each one carries a real ref that still has to reach the targets). Repo creation tolerates losing that race anyway: on a failed create it re-checks existence and continues if the repo is there.

Platform differences that aren't obvious:

| Platform | Description | Topics | Project URL | Notes |
|---|---|---|---|---|
| Codeberg (Gitea) | yes | yes | yes (`website`) | Gitea rejects the whole topics array if one entry is invalid, so topics are lowercased, stripped to `[a-z0-9-]`, de-duped and capped at 25. A rejection the normalizer doesn't model is a warning, not a failed mirror. |
| GitLab | yes | yes | **no** → README | Project creation needs a token with `api` scope, not just `write_repository`. Its project object exposes only derived URLs (`web_url`, `readme_url`, …), none writable, so the homepage goes at the top of the README instead — see below. It also auto-protects the default branch, which blocks every force push after the first — the job strips protection to prevent that; see below. |
| Gitee | yes | **no** | yes (`homepage`) | `name` is **required** on the repo-edit call — a body without it is rejected — so it's sent unchanged. See the visibility note below. |

**GitLab has nowhere to put a project URL, so it goes in the README.** GitLab is the only target with no writable homepage field, and its README *is* the project landing page. When the GitHub repo has a homepage set, `readme_url_header` (default `true`) prepends it as a markdown link at the top of the README on the mirror's default branch.

This is the one place a GitLab mirror deliberately differs from its source: that branch carries one extra commit. Every other branch, every tag and every other file stay byte-identical. The commit is authored by `git-mirror <git-mirror@noreply.invalid>` and dated from the source tip rather than "now", which makes its hash stable — an unchanged source re-mirrors to the identical SHA, so the force-push is a no-op instead of rewriting the branch on every run. A repo with no homepage, or no README, is left alone. Set `readme_url_header: false` to keep the mirror an exact copy.

**GitLab auto-protects the default branch, and it freezes mirrors silently.** A new GitLab project gets its default branch protected with `allow_force_push: false`. A mirror force-pushes, so every run *after the first* is rejected with `You are not allowed to force push code to a protected branch`. The first one succeeds because it *creates* the branch instead of force-pushing over it — so setup looks perfect, all the refs are there, and the mirror then sits frozen at that snapshot while every later run fails.

The job therefore strips **every** protected-branch rule from the target after ensuring the project exists — not just the default branch, since a wildcard rule like `release/*` rejects a force push identically. Protection is meaningless on a read-only mirror. If a rule can't be removed the job warns and names the branch, rather than letting it surface later as an unexplained push failure.

**A topic the target refuses doesn't cost you the rest.** GitLab validates the topic array as a unit and rejects the whole request with an opaque `422 Project could not be updated!` over a single entry — and a topic that's perfectly legal on GitHub can be refused there, with nothing saying which one (observed: `fileupload` refused while `fileuploader` on the same repo was fine). The bulk call is still tried first, so the normal case is one request; only on rejection does it fall back to setting the description alone and then growing the topic list one entry at a time, keeping everything accepted and skipping just the offenders, which are named in a warning.

**Gitee visibility.** Gitee requires a mobile number bound to the account before any repository can be public. Rather than refusing a `private: false` create, it accepts the call and creates a **private** repo — so the mirror runs green while the result is invisible to everyone else. The Gitee job re-reads visibility after creating and warns when this happens. Flipping such a repo afterwards returns `422` with `仓库转公开需绑定手机号码` ("making a repository public requires binding a phone number"); that's an account setting, not something the workflow can fix.

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
| `gitee_user` | Gitee | Username for the push (optional — defaults to the target owner). |

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

Copies issues opened on the Codeberg and GitLab mirrors into GitHub, so the mirrors can carry a conversation without anyone having to watch them. [`git-mirror.yml`](#git-mirroryml) turns pull requests **off** on those copies but leaves issues on — this is the other half of that decision: issues are the one thing a visitor who finds the project on a mirror can still open, and without this they'd sit there unread forever.

**Direction is the whole design.** It only ever READS the mirrors and WRITES here, so no GitHub credential ever leaves the runner. The relayed issue is opened with the built-in `GITHUB_TOKEN`, scoped to the one repo and expired when the job ends. The alternative — a bot on Codeberg pushing into GitHub — needs a GitHub PAT stored on a third-party forge, fired by untrusted contributor input. That's the same footgun `collaborators-only-workflow.yml` exists to avoid, and pulling instead of pushing removes it entirely.

**The relayed issue is authored by `github-actions[bot]`, never by you.** An issue that claims to be written by you but wasn't is a lie you have to live with forever, and you'd get notified about something "you" wrote. The real author, timestamp and a link to the original go in the body instead. A bot-authored issue also doesn't re-trigger workflows, so there's no loop to guard against.

**State lives in the relayed issues themselves.** Each carries an invisible marker comment holding its source URL, and that's what the next run diffs against — so there's no cache to evict, no state file to corrupt, and a run that dies halfway simply picks up where it left off. Same principle as the `sourcerevision` check in [`archive.yml`](#archiveyml): ask the thing you actually care about instead of remembering.

What propagates, and what deliberately doesn't:

| | |
|---|---|
| Issue opened on a mirror | → opened here, labelled `relayed` + `codeberg`/`gitlab` |
| Issue closed on a mirror | → closed here, with a note saying where it was closed, how many comments it drew and how long it was open |
| Issue reopened on a mirror | → reopened here |
| Comments, reviews, labels | **not synced** — one-way, open/close/reopen only. Two-way comment sync is a product, not a workflow; the original is one click away in the body. |

**Reading public issues needs no token at all.** The mirror tokens are optional and only raise the rate limit — and an *under-scoped* one is worse than none, because it turns a request that would have succeeded anonymously into a `403`. So every authenticated read falls back to an anonymous one and warns, rather than skipping that platform for the run.

**Jitter, not just a staggered cron.** GitHub fires a whole account's crons together, so N repos on the same 6-hourly schedule is one thundering herd per platform, forever. `jitter_seconds` (default 600) sleeps a random moment before the first request. Only the cron needs it — a manual run is one repo triggered by one person who's waiting for it, so callers should pass `0` for anything else.

### Inputs

| Input | Default | Description |
|---|---|---|
| `codeberg_enabled` | `true` | Pull issues from the Codeberg mirror. |
| `gitlab_enabled` | `true` | Pull issues from the GitLab mirror. |
| `codeberg_url` | `https://codeberg.org` | Base URL of the Codeberg/Gitea instance. |
| `target_owner` | `""` | Owner on Codeberg + GitLab. Defaults to this repo's owner. |
| `jitter_seconds` | `600` | Upper bound on a random delay before the first request. |
| `label` | `relayed` | Label put on every relayed issue — and the query that finds them again, so changing it orphans everything relayed under the old one. |
| `runs_on` | `ubuntu-latest` | Runner to use. |

### Secrets

Both optional; public issues read fine without them.

| Secret | Description |
|---|---|
| `codeberg_token` | Raises the Codeberg rate limit. |
| `gitlab_token` | Raises the GitLab rate limit. |

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

The caller job needs `permissions: issues: write` — the workflow can't grant itself more than the caller has.

## archive.yml

Pushes the caller repo into public archives so it survives the platform it lives on. Three targets, covering three different failure modes:

- **Wayback Machine** archives the rendered **page** — your README as HTML, and the project homepage. Good against link rot, useless if what you need back is the code.
- **Software Heritage** archives the **git object graph** — every commit and every blob, git-native. This is the one that matters if a host disappears entirely. It's the archive academic citations point at, run by Inria under a UNESCO mandate.
- **archive.org item** archives the **working tree itself** as a page a person can land on, read and download — description, topics, licence and links back to the repo and project page attached as real metadata. The other two keep the code or keep the page; neither gives you something browsable. Requires the archive.org key pair.

**The first two need no API key**, and neither pulls in a third-party action — both are plain `curl`, so there's no marketplace action to SHA-pin and no supply-chain surface. Both services are anonymous-friendly and *rate-limited* rather than gated, which drives the two design decisions here:

- **Every request retries with exponential backoff**, because the expected failure is "too many requests right now", not "no". `max_attempts` (default 5) with `backoff_seconds` (default 30) gives 30s, 60s, 120s, 240s between tries — about seven minutes of patience. That figure is sized to a real constraint: an archive.org account gets **three concurrent Save Page Now sessions**, so several repositories archiving at once queue behind each other and answer `429` until one frees up. The previous 3 × 10s gave up while the queue was still draining. Only a `429`, a `404`, a `5xx`, or a timeout is retried — any other `4xx` means the URL itself is unacceptable and waiting won't change that answer. **`404` is in that set** even though it normally means "gone": Save Page Now answers `404` when it's under load and abandons the fetch, and the URL passed here is always the caller's own page, which exists.
- **If it still can't archive after all that, the job goes red.** A green run that archived nothing is a lie. Going red costs nothing here because the job is deliberately independent — nothing `needs:` it, so it reports the truth without blocking the release or any other job. Set `fail_on_error: false` if you'd rather not see it.

The bundled `mirror-and-archive.yml` caller sets `fail_on_error: false`: it is
an auxiliary durability job attached to a source push, so a provider outage is
reported as a warning without turning the caller's release pipeline red. Call
`archive.yml` directly with its default when an archive confirmation is a gate
for your own workflow.

**Save Page Now caps captures per URL per day** — five, currently — separately from the account's daily quota, which can be almost untouched while this one refuses. It answers HTTP 200 with no job id and `status_ext=error:too-many-daily-captures`. That counts as archived, because it is: the snapshots exist and another would add nothing. Every *other* jobless 200 is a real refusal and still fails.

**Wayback is slow** — a single save measured **~110 seconds** — hence the generous `url_timeout_seconds` (default 180) and a deliberately short URL list rather than every page. A timeout is *not* treated as a refusal: Wayback frequently finishes the save after the client has given up, so a retry there is a second chance, not a correction.

By default it archives the repo's GitHub page plus the URL set as the repo's homepage (`include_homepage`), and `extra_urls` takes any others, one per line.

**Archiving the pages your README links to needs archive.org keys**, and the keyless path fails at it in the worst way: `capture_outlinks` is *silently ignored* rather than refused. The save returns HTTP 200, the page itself lands in the archive, and not one linked page does.

The reason is that outlink capture only exists on the authenticated Save Page Now v2 API — an unauthenticated `POST https://web.archive.org/save` answers `You need to be logged in to use Save Page Now` even for a plain save with no options at all. The keyless `GET /save/<url>` this workflow falls back to is an older path that takes no options.

Generate an S3 key pair at [archive.org/account/s3.php](https://archive.org/account/s3.php) and pass them as `archiveorg_access_key` / `archiveorg_secret_key`. They're named for the **account**, not for one caller: the same two values sign Save Page Now, the S3 upload API and the metadata API alike. With them the job switches to the v2 API and `capture_outlinks` (default `true`) and `capture_screenshot` (default `false`) start working. Without them everything still runs and the job emits a warning, so the gap is visible instead of silent.

**The archive.org item is the one you can actually browse.** It uploads the working tree as a single tarball — one request rather than hundreds — which archive.org unpacks on its side, and attaches the GitHub description, topics, licence and links back to both the repo and the project page. `.git` is excluded: Software Heritage already holds the history, and duplicating it here is bulk with no benefit.

Two things about it are worth understanding before you enable it elsewhere:

- **It skips when nothing changed.** The item records the source commit as `sourcerevision`, and a run whose HEAD already matches it uploads nothing. Without that, a README typo re-ships the entire tree. This also gives retry-on-schedule for free: a run that died mid-upload never wrote its revision, so the next one sees a mismatch and tries again. **The absence of the revision is the failure record** — there is no retry flag because none is needed.
- **Creating an item is rate-limited far harder than uploading to one.** A burst of new items answers `503 SlowDown` with *"appears to be spam"*. So `max_new_items_per_day` (default 5) caps creation, counted by **asking archive.org** how many items with your prefix are dated today — not by keeping a tally. A tally drifts the moment a run dies between doing the work and recording it, and there's nowhere to keep one anyway: Actions caches are repo-scoped and evictable, and account-level variables don't exist outside an organisation. Over the cap the job exits **green** — nothing is wrong, the work simply belongs to a later run. Uploads to an item that already exists are ordinary PUTs and never gated. The ceiling is deliberately well under the level that tripped the filter (about a dozen inside an hour): it's counted per day, but the search index it reads from lags by minutes, so the real burst can exceed the ceiling before the count catches up — five leaves margin for that.

`item_identifier_prefix` (default `psyb0t-`) is not decoration. **archive.org identifiers are global and permanent**; claiming an unprefixed one is a landgrab that eventually collides with someone else's project of the same name.

### Inputs

| Input | Default | Description |
|---|---|---|
| `wayback_enabled` | `true` | Archive pages to the Wayback Machine. |
| `software_heritage_enabled` | `true` | Archive the git history to Software Heritage. |
| `include_homepage` | `true` | Also archive the repo's homepage URL, when it has one. |
| `extra_urls` | `""` | Additional URLs to archive, one per line. |
| `capture_outlinks` | `true` | Also archive every page the archived page links to. **Requires the archive.org key secrets** — silently ignored without them. |
| `capture_screenshot` | `false` | Also store a screenshot of each page. Same key requirement. |
| `item_upload_enabled` | `true` | Upload the working tree to archive.org as a browsable item. Needs the key pair. |
| `item_identifier_prefix` | `psyb0t-` | Prefixed to the repo name to form the archive.org identifier. Identifiers are global and permanent. |
| `max_new_items_per_day` | `5` | Ceiling on NEW items created per day across the account. Over it the job exits green and leaves the rest to a later run. |
| `item_collection` | `opensource` | archive.org collection to file the item under. |
| `fail_on_error` | `true` | Fail the job when a request is still refused after every retry — a green run that archived nothing is a lie. Nothing `needs:` this job, so red here blocks nothing. |
| `max_attempts` | `5` | Attempts per request, including the first. |
| `backoff_seconds` | `30` | Base delay between attempts; doubles each retry. |
| `url_timeout_seconds` | `180` | Per-URL budget for a Wayback save. |
| `runs_on` | `ubuntu-latest` | Runner to use. |

### Secrets

Both optional. Without them the Wayback and Software Heritage jobs still run using the keyless save; the item upload skips with a warning.

| Secret | Description |
|---|---|
| `archiveorg_access_key` | archive.org S3 access key, from [archive.org/account/s3.php](https://archive.org/account/s3.php). An **account** credential — the same pair signs Save Page Now, the S3 upload API and the metadata API. Needed for `capture_outlinks`, `capture_screenshot` and the item upload. |
| `archiveorg_secret_key` | The paired secret key. |

### Example

Keyless — archives the repo page and its homepage, no setup at all:

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

With keys — additionally sweeps in every page the archived pages link to, and publishes the source as a browsable archive.org item:

```yaml
jobs:
  archive:
    uses: psyb0t/reusable-github-workflows/.github/workflows/archive.yml@master
    secrets:
      archiveorg_access_key: ${{ secrets.ARCHIVEORG_ACCESS_KEY }}
      archiveorg_secret_key: ${{ secrets.ARCHIVEORG_SECRET_KEY }}
```

## License

[WTFPL](http://www.wtfpl.net/) — Do What The Fuck You Want To Public License. See [LICENSE](LICENSE).
