# Reusable GitHub Workflows

Just some reusable github workflows.

## Workflows

<!-- SCRIPTS_START -->

- [docker-image-workflow.yml](.github/workflows/docker-image-workflow.yml)
- [python-package-workflow.yml](.github/workflows/python-package-workflow.yml)
<!-- SCRIPTS_END -->

## Examples

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
