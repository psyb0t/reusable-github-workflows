"""Run the Pages build step with a temporary caller checkout.

Run: python -m pytest tests/test_pages_build.py
Needs: Bash, GNU coreutils, pytest and PyYAML. No token or network.
"""

import os
import subprocess
from pathlib import Path

import pytest
import yaml

WORKFLOW = (
    Path(__file__).resolve().parents[1]
    / ".github/workflows/pages-workflow.yml"
)
BUILD_SITE = 'mkdir -p public && printf "site" > public/index.html'


@pytest.fixture
def checkout(tmp_path):
    return tmp_path / "caller"


@pytest.fixture
def build(checkout):
    checkout.mkdir()
    document = yaml.safe_load(WORKFLOW.read_text())
    step = next(
        step
        for step in document["jobs"]["build"]["steps"]
        if step.get("id") == "site"
    )

    def run(**overrides):
        env = {
            "PATH": os.environ["PATH"],
            "BUILD_COMMAND": BUILD_SITE,
            "SITE_DIR": "public",
            "OPENAPI_FILE": "",
            "OPENAPI_COMMAND": 'printf "%s" "$OPENAPI_FILE" > generated',
            "MAX_ATTEMPTS": "1",
            "BACKOFF_SECONDS": "0",
            "GITHUB_OUTPUT": str(checkout / "output"),
            **overrides,
        }
        return subprocess.run(
            ["bash", "-eo", "pipefail", "-c", step["run"]],
            cwd=checkout,
            env=env,
            check=False,
            capture_output=True,
            text=True,
        )

    return run


@pytest.mark.parametrize("extension", ["json", "yaml", "yml"])
def test_spec_runs_generator_before_build(build, checkout, extension):
    spec = checkout / f"api document.{extension}"
    spec.write_text("{}")
    result = build(
        OPENAPI_FILE=spec.name,
        BUILD_COMMAND=(
            "test -f generated && mkdir -p public && "
            "cp generated public/index.html"
        ),
    )
    assert result.returncode == 0, result.stderr
    assert (checkout / "public/index.html").read_text() == spec.name
    assert (checkout / "output").read_text() == f"path={checkout / 'public'}\n"


@pytest.mark.parametrize("generator", ["", "-"])
def test_generator_can_run_as_part_of_build(build, checkout, generator):
    (checkout / "api.json").write_text("{}")
    result = build(
        OPENAPI_FILE="api.json",
        OPENAPI_COMMAND=generator,
        BUILD_COMMAND=(
            "mkdir -p public && "
            'printf "%s" "$OPENAPI_FILE" > public/index.html'
        ),
    )
    assert result.returncode == 0, result.stderr
    assert (checkout / "public/index.html").read_text() == "api.json"
    assert not (checkout / "generated").exists()


def test_markdown_only_build_skips_generator(build, checkout):
    result = build(OPENAPI_COMMAND="exit 7")
    assert result.returncode == 0, result.stderr
    assert (checkout / "public/index.html").read_text() == "site"


@pytest.mark.parametrize(
    "spec", ["api.xml", "missing.yaml", "../outside.yaml"]
)
def test_bad_spec_stops_build(build, checkout, spec):
    (checkout.parent / "outside.yaml").write_text("{}")
    result = build(OPENAPI_FILE=spec)
    assert result.returncode != 0
    assert not (checkout / "public").exists()
    assert not (checkout / "generated").exists()


def test_generator_failure_prevents_build_after_retries(build, checkout):
    (checkout / "api.json").write_text("{}")
    result = build(
        OPENAPI_FILE="api.json",
        OPENAPI_COMMAND="printf x >> attempts && exit 7",
        MAX_ATTEMPTS="2",
    )
    assert result.returncode != 0
    assert "exit 7" in result.stderr
    assert (checkout / "attempts").read_text() == "xx"
    assert not (checkout / "public").exists()


def test_retry_can_recover_build(build, checkout):
    result = build(
        BUILD_COMMAND=(
            "if [[ ! -f tried ]]; then touch tried; exit 7; fi\n"
            "mkdir -p public && touch public/index.html"
        ),
        MAX_ATTEMPTS="2",
    )
    assert result.returncode == 0, result.stderr
    assert (checkout / "output").is_file()


@pytest.mark.parametrize("site_dir", [".", "../outside", "missing"])
def test_output_must_be_a_separate_site_directory(build, checkout, site_dir):
    result = build(SITE_DIR=site_dir, BUILD_COMMAND="-")
    assert result.returncode != 0
    assert not (checkout / "output").exists()


@pytest.mark.parametrize("link_kind", ["symlink", "hardlink"])
def test_static_output_cannot_link_to_other_files(build, checkout, link_kind):
    public = checkout / "public"
    public.mkdir()
    (public / "index.html").write_text("site")
    extra = checkout / "fixture.txt"
    extra.write_text("private fixture")
    link = public / "other.txt"
    if link_kind == "symlink":
        link.symlink_to(extra)
    else:
        link.hardlink_to(extra)

    result = build(BUILD_COMMAND="-")
    assert result.returncode != 0
    assert not (checkout / "output").exists()
