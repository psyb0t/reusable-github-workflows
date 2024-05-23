# Reusable GitHub Workflows

Just some reusable github workflows.

## Workflows

<!-- SCRIPTS_START -->
- [docker-image-workflow.yml](.github/workflows/docker-image-workflow.yml)
<!-- SCRIPTS_END -->

## Example

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
