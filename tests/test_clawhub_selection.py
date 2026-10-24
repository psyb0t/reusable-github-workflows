"""Test ClawHub workflow selection without publishing."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

WORKFLOW = (
    Path(__file__).resolve().parents[1]
    / ".github/workflows/clawhub-publish.yml"
)
CLI_MOCK = """#!/bin/bash
set -euo pipefail
jq -nc --args '$ARGS.positional' -- "$@" >> "$CALL_LOG"
slug=fixture
for argument in "$@"; do
    if [[ -f "$argument/SKILL.md" ]]; then
        slug="$(basename "$argument")"
    fi
done
jq -nc --arg slug "$slug" '{slug:$slug,version:"1.2.3",status:"published"}'
"""
CURL_MOCK = """#!/bin/bash
set -euo pipefail
output=""
identity=false
slug=fixture
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) output="$2"; shift ;;
        */whoami) identity=true ;;
        */skills/*) slug="${1##*/skills/}"; slug="${slug%%/*}" ;;
    esac
    shift
done
if [[ "$identity" == true ]]; then
    printf '%s\\n' '{"user":{"handle":"fixture-owner"}}' > "$output"
else
    jq -nc --arg slug "$slug" '{skill:{slug:$slug},version:{version:"1.2.3"}}' > "$output"
fi
printf 200
"""
FIXTURE_NAMES = ("public", "private")
FIXTURE_VERSION = "0.1.0"
TAG_VERSION = "1.2.3"


class ClawHubSelectionTests(unittest.TestCase):
    def run_step(self, job_name, selection, present=True):
        workflow_path = Path(os.environ.get("TEST_CLAWHUB_WORKFLOW", WORKFLOW))
        workflow = yaml.safe_load(workflow_path.read_text())
        step = workflow["jobs"][job_name]["steps"][-1]
        family = "skills" if job_name.endswith("skills") else "plugins"
        selector_input = (
            "skill_names" if family == "skills" else "plugin_names"
        )
        selector_expression = "${{ inputs." + selector_input + " }}"
        manifest = "SKILL.md" if family == "skills" else "openclaw.plugin.json"
        with tempfile.TemporaryDirectory(
            prefix="clawhub-selection-"
        ) as temporary:
            root = Path(temporary)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            cli = bin_dir / "clawhub"
            cli.write_text(CLI_MOCK)
            cli.chmod(0o755)
            curl = bin_dir / "curl"
            curl.write_text(CURL_MOCK)
            curl.chmod(0o755)
            data_dir = root / ".agents" / family
            if present:
                for name in FIXTURE_NAMES:
                    directory = data_dir / name
                    directory.mkdir(parents=True)
                    (directory / manifest).write_text(
                        json.dumps({"version": FIXTURE_VERSION})
                    )
                    (directory / "package.json").write_text(
                        json.dumps({"version": FIXTURE_VERSION})
                    )
                (data_dir / "unmanifested").mkdir()
            call_log = root / "calls.jsonl"
            environment = dict(os.environ)
            environment.update(
                {
                    key: selection if value == selector_expression else ""
                    for key, value in step.get("env", {}).items()
                }
            )
            environment.update(
                PATH=f"{bin_dir}:{os.environ['PATH']}",
                CALL_LOG=str(call_log),
                SKILLS_DIR=str(data_dir),
                PLUGINS_DIR=str(data_dir),
                CLAWHUB_TOKEN="EXAMPLE-DO-NOT-USE",
                SOURCE_REPO="fixture/project",
                SOURCE_REF=f"refs/tags/v{TAG_VERSION}",
                SOURCE_COMMIT="fixture-commit",
                INPUT_VERSION=TAG_VERSION,
                DRY_RUN="false",
                PUBLISH_ATTEMPTS="1",
                FAIL_ON_UPSTREAM_ERROR="true",
            )
            result = subprocess.run(
                ["bash", "-c", step["run"]],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            calls = []
            if call_log.exists():
                calls = [
                    json.loads(line)
                    for line in call_log.read_text().splitlines()
                ]
            versions = {}
            if present:
                versions = {
                    name: json.loads(
                        (data_dir / name / "package.json").read_text()
                    )["version"]
                    for name in FIXTURE_NAMES
                }
            called_names = [
                Path(argument).name
                for call in calls
                for argument in {
                    value
                    for value in call
                    if value.startswith(str(data_dir) + "/")
                }
            ]
            return result, called_names, versions

    def test_selection_in_validation_and_publishing(self):
        cases = (
            ("", list(FIXTURE_NAMES)),
            ('["public"]', ["public"]),
            ('["private"]', ["private"]),
            ('["public", "public"]', ["public"]),
            ("[]", []),
        )
        for job in (
            "validate-skills",
            "publish-skills",
            "validate-plugins",
            "publish-plugins",
        ):
            for selection, expected in cases:
                with self.subTest(job=job, selection=selection):
                    result, names, versions = self.run_step(job, selection)
                    self.assertEqual(
                        result.returncode, 0, result.stdout + result.stderr
                    )
                    self.assertEqual(set(names), set(expected))
                    calls_per_name = 2 if job == "publish-plugins" else 1
                    for name in expected:
                        self.assertEqual(names.count(name), calls_per_name)
                    if job == "publish-plugins":
                        for name in FIXTURE_NAMES:
                            expected_version = (
                                TAG_VERSION
                                if name in expected
                                else FIXTURE_VERSION
                            )
                            self.assertEqual(versions[name], expected_version)

    def test_bad_selections_fail_before_any_cli_call(self):
        selections = (
            '["public", "missing"]',
            '["unmanifested"]',
            "not-json",
            "null",
            '"public"',
            "[1]",
            '[""]',
            '["../public"]',
            '["."]',
            '[".."]',
            '["public\\\\private"]',
            '["public\\nprivate"]',
            '["$(touch owned)"]',
        )
        for job in (
            "validate-skills",
            "publish-skills",
            "validate-plugins",
            "publish-plugins",
        ):
            for selection in selections:
                with self.subTest(job=job, selection=selection):
                    result, names, versions = self.run_step(job, selection)
                    self.assertNotEqual(
                        result.returncode, 0, result.stdout + result.stderr
                    )
                    self.assertEqual(names, [])
                    self.assertEqual(set(versions.values()), {FIXTURE_VERSION})

    def test_missing_directory_defaults_skip_but_explicit_names_fail(self):
        for job in (
            "validate-skills",
            "publish-skills",
            "validate-plugins",
            "publish-plugins",
        ):
            for selection, succeeds in (
                ("", True),
                ("[]", True),
                ('["public"]', False),
            ):
                with self.subTest(job=job, selection=selection):
                    result, names, _ = self.run_step(
                        job, selection, present=False
                    )
                    self.assertEqual(
                        result.returncode == 0,
                        succeeds,
                        result.stdout + result.stderr,
                    )
                    self.assertEqual(names, [])


if __name__ == "__main__":
    unittest.main()
