# Reusable GitHub Workflows

Just some reusable github workflows.

## Workflows

<!-- SCRIPTS_START -->
- [collaborators-only-workflow.yml](.github/workflows/collaborators-only-workflow.yml)
- [docker-image-workflow.yml](.github/workflows/docker-image-workflow.yml)
- [go-workflow.yml](.github/workflows/go-workflow.yml)
- [python-package-workflow.yml](.github/workflows/python-package-workflow.yml)
<!-- SCRIPTS_END -->

## Pinning

Examples below use `@master` for readability. For production use, pin to a tag (`@v0.4.0`) or full commit SHA — `@master` will pick up any future change without warning.

## Examples

### collaborators-only-workflow.yml

```yaml
name: Collaborators Only

on:
  pull_request_target:
    types: [opened, reopened]

jobs:
  collaborators-only:
    uses: psyb0t/reusable-github-workflows/.github/workflows/collaborators-only-workflow.yml@master
    with:
      close_message: "This repository does not accept external pull requests. Please open an issue instead."
      lock: true
```

### docker-image-workflow.yml

```yaml
name: pipeline

on: [push]

jobs:
  call-docker-image-workflow:
    uses: psyb0t/reusable-github-workflows/.github/workflows/docker-image-workflow.yml@master
    with:
      repository_name: dockerhub-org/repo
      target_platforms: "linux/amd64,linux/arm64"

    secrets:
      dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
      dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}
```

#### Multi-target builds (multi-stage or multi-Dockerfile)

Ship multiple image variants from one pipeline run by passing a `build_targets` JSON array. Each entry produces one image tagged with `tag_suffix`.

**Multi-stage from one Dockerfile** (e.g. `full` + `minimal` stages):

```yaml
jobs:
  call-docker-image-workflow:
    uses: psyb0t/reusable-github-workflows/.github/workflows/docker-image-workflow.yml@master
    with:
      repository_name: dockerhub-org/repo
      build_targets: |
        [
          {"target": "full",    "tag_suffix": ""},
          {"target": "minimal", "tag_suffix": "-minimal"}
        ]
    secrets:
      dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
      dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}
```

**Multi-Dockerfile** (e.g. separate CPU and CUDA builds):

```yaml
jobs:
  call-docker-image-workflow:
    uses: psyb0t/reusable-github-workflows/.github/workflows/docker-image-workflow.yml@master
    with:
      repository_name: dockerhub-org/repo
      target_platforms: "linux/amd64"
      build_targets: |
        [
          {"file": "Dockerfile",      "tag_suffix": ""},
          {"file": "Dockerfile.cuda", "tag_suffix": "-cuda"}
        ]
    secrets:
      dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
      dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}
```

**Per-image platforms override** (CPU image multi-arch, CUDA image amd64-only):

```yaml
jobs:
  call-docker-image-workflow:
    uses: psyb0t/reusable-github-workflows/.github/workflows/docker-image-workflow.yml@master
    with:
      repository_name: dockerhub-org/repo
      target_platforms: "linux/amd64,linux/arm64"
      build_targets: |
        [
          {"file": "Dockerfile",      "tag_suffix": ""},
          {"file": "Dockerfile.cuda", "tag_suffix": "-cuda", "platforms": "linux/amd64"}
        ]
    secrets:
      dockerhub_username: ${{ secrets.DOCKERHUB_USERNAME }}
      dockerhub_token: ${{ secrets.DOCKERHUB_TOKEN }}
```

Entry fields:
- `tag_suffix` (required) — appended to the image tag. Empty string = unsuffixed (`:latest` / `:v1.2.3`).
- `target` (optional) — Dockerfile stage. Omit for multi-Dockerfile builds.
- `file` (optional) — Dockerfile path. Defaults to `Dockerfile`. Use for multi-Dockerfile repos.
- `platforms` (optional) — comma-separated platforms for this entry. Falls back to `inputs.target_platforms` if absent.

### python-package-workflow.yml

```yaml
name: pipeline

on: [push]

jobs:
  call-python-package-workflow:
    uses: psyb0t/reusable-github-workflows/.github/workflows/python-package-workflow.yml@master

    with:
      python_version: "3.12.0"
      install_dependencies_command: "make dep"
      build_command: "make build"
      dist_dir: "dist"

    secrets:
      pypi_api_token: ${{ secrets.PYPI_API_TOKEN }}
```

### go-workflow.yml

```yaml
name: pipeline

on: [push]

jobs:
  call-go-workflow:
    uses: psyb0t/reusable-github-workflows/.github/workflows/go-workflow.yml@master
    with:
      go_version: "1.24"
      dep_command: "make dep"
      lint_command: "make lint"
      test_command: "make test"
```
