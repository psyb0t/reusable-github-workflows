"""Run: python3 -m unittest discover -s tests -p 'test_regen_repair_workflow.py'."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from types import SimpleNamespace

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/regen-and-update-repo.yml"
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}")


class Values(dict):
    def __getattr__(self, key):
        return self.get(key, SimpleNamespace(outputs=Values(), outcome="skipped"))


class RepairWorkflowTests(unittest.TestCase):
    def run_fixture(self, repairs, *, broken="security", budget=3):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        inputs_spec = workflow.get("on", workflow.get(True))["workflow_call"]["inputs"]
        inputs = Values({key: value.get("default", "") for key, value in inputs_spec.items()})
        with tempfile.TemporaryDirectory(prefix="regen-workflow-") as directory:
            temporary = Path(directory)
            repo = temporary / "repo with spaces"
            repo.mkdir()
            (repo / "toolchain").write_text("broken\n")
            (repo / "source.txt").write_text("https://provider.example/spec.yml\n")
            initialize = temporary / "git-update.sh"
            initialize.write_text(
                "set -eu\ngit init -q\ngit add toolchain source.txt\n"
                "git -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture\n"
            )
            subprocess.run(["bash", str(initialize)], cwd=repo, check=True, capture_output=True)
            (temporary / "reusable-workflow-tools").symlink_to(ROOT, target_is_directory=True)
            generator = 'test "$(cat toolchain)" = patched' if broken == "generation" else "true"
            inputs.update(
                generate_command=generator,
                check_commands='test "$(cat toolchain)" = patched' if broken else "",
                fix_attempts=budget,
                fix_protected_paths=".github/*\nMakefile",
            )
            steps = Values()
            context = {
                "inputs": inputs,
                "steps": steps,
                "runner": SimpleNamespace(temp=str(temporary)),
                "github": SimpleNamespace(workspace=str(repo)),
                "always": lambda: True,
            }

            def evaluate(expression):
                expression = expression.strip()
                expression = expression.removeprefix("${{").removesuffix("}}").strip()
                expression = expression.replace("&&", " and ").replace("||", " or ")
                expression = re.sub(r"!(?!=)", " not ", expression)
                # Only this repository's trusted workflow expressions are evaluated.
                return eval(expression, {"__builtins__": {}}, context)

            def render(value):
                return EXPRESSION.sub(lambda match: str(evaluate(match[1])), str(value))

            job = workflow["jobs"]["regen"]
            base_env = {key: render(value) for key, value in job.get("env", {}).items()}
            attempt = 0
            executed = []
            for step in job["steps"]:
                name = step["name"]
                if name == "Sync with the branch tip":
                    break
                if name.startswith(("Checkout", "Move reusable")):
                    continue
                if not evaluate(step.get("if", "True")):
                    continue
                executed.append(name)
                if "uses" in step:
                    self.assertIn("docker-claudebox", step["uses"])
                    prompt = Path(render(step["with"]["prompt-file"]))
                    self.assertTrue(prompt.is_file())
                    if attempt and repairs[min(attempt - 1, len(repairs) - 1)] == "suppress":
                        feedback = prompt.parent / "context" / "check-output.log"
                        self.assertIn("suppression", feedback.read_text())
                    action = repairs[min(attempt, len(repairs) - 1)]
                    attempt += 1
                    if action == "suppress":
                        (repo / "bad.go").write_text("// nolint:security\n")
                        (repo / "toolchain").write_text("patched\n")
                    elif action == "fix":
                        (repo / "bad.go").write_text("package fixture\n")
                        (repo / "toolchain").write_text("patched\n")
                    elif action != "nothing":
                        self.fail("unknown fixture repair")
                    if "id" in step:
                        steps[step["id"]] = SimpleNamespace(outputs=Values(), outcome="success")
                    continue
                output = temporary / "output"
                output.write_text("")
                environment = {
                    **os.environ,
                    **base_env,
                    **{key: render(value) for key, value in step.get("env", {}).items()},
                    "RUNNER_TEMP": str(temporary),
                    "GITHUB_OUTPUT": str(output),
                    "GITHUB_STEP_SUMMARY": str(temporary / "summary"),
                }
                result = subprocess.run(
                    ["bash", "-euo", "pipefail", "-c", render(step["run"])],
                    cwd=repo,
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
                outputs = Values(line.split("=", 1) for line in output.read_text().splitlines())
                if "id" in step:
                    steps[step["id"]] = SimpleNamespace(
                        outputs=outputs, outcome="success" if result.returncode == 0 else "failure"
                    )
                if result.returncode and not step.get("continue-on-error"):
                    return False, attempt, executed
            return True, attempt, executed

    def test_unchanged_security_failure_reaches_repair(self):
        success, attempts, _ = self.run_fixture(["fix"])
        self.assertTrue(success)
        self.assertEqual(attempts, 1)

    def test_generation_failure_reaches_repair(self):
        success, attempts, _ = self.run_fixture(["fix"], broken="generation")
        self.assertTrue(success)
        self.assertEqual(attempts, 1)

    def test_rejections_feed_back_until_third_attempt_repairs(self):
        success, attempts, _ = self.run_fixture(["suppress", "suppress", "fix"])
        self.assertTrue(success)
        self.assertEqual(attempts, 3)

    def test_repeated_suppression_exhausts_budget(self):
        success, attempts, executed = self.run_fixture(["suppress"])
        self.assertFalse(success)
        self.assertEqual(attempts, 3)
        self.assertNotIn("Detect changes", executed)

    def test_explicit_disable_still_blocks_failure(self):
        success, attempts, _ = self.run_fixture(["fix"], budget=0)
        self.assertFalse(success)
        self.assertEqual(attempts, 0)

    def test_unchanged_success_does_not_start_model(self):
        success, attempts, _ = self.run_fixture(["fix"], broken=None)
        self.assertTrue(success)
        self.assertEqual(attempts, 0)

    def test_noop_model_cannot_turn_failure_into_success(self):
        success, attempts, _ = self.run_fixture(["nothing"])
        self.assertFalse(success)
        self.assertEqual(attempts, 3)

    def test_invalid_budgets_fail_before_model(self):
        for budget in (-1, 4, "invalid"):
            with self.subTest(budget=budget):
                success, attempts, _ = self.run_fixture(["fix"], budget=budget)
                self.assertFalse(success)
                self.assertEqual(attempts, 0)

    def test_failure_issue_is_created_once_then_updated(self):
        job = yaml.safe_load(WORKFLOW.read_text())["jobs"]["report-failure"]
        with tempfile.TemporaryDirectory(prefix="regen-issue-") as directory:
            temporary = Path(directory)
            command = temporary / "gh"
            command.write_text(
                '#!/bin/bash\nset -eu\ncase "$2" in\n'
                'list) if [ -f "$STATE" ]; then echo 17; fi ;;\n'
                'create) touch "$STATE"; echo create >>"$CALLS" ;;\n'
                'comment) echo comment >>"$CALLS" ;;\n'
                '*) exit 9 ;;\nesac\n'
            )
            command.chmod(0o700)
            environment = {
                **os.environ,
                "PATH": f"{temporary}:{os.environ['PATH']}",
                "STATE": str(temporary / "state"),
                "CALLS": str(temporary / "calls"),
                "TITLE": "Fixture failure",
                "RUN_URL": "https://github.com/fixture/client/actions/runs/10",
                "REGEN_RESULT": "failure",
                "COMMIT_RESULT": "skipped",
                "GITHUB_STEP_SUMMARY": str(temporary / "summary"),
            }
            for _ in range(2):
                subprocess.run(
                    ["bash", "-euo", "pipefail", "-c", job["steps"][0]["run"]],
                    env=environment,
                    check=True,
                    capture_output=True,
                    timeout=30,
                )
            self.assertEqual((temporary / "calls").read_text().splitlines(), ["create", "comment"])

    def test_failure_reporting_covers_schedule_and_manual_but_not_success(self):
        expression = yaml.safe_load(WORKFLOW.read_text())["jobs"]["report-failure"]["if"]
        expression = expression.replace("&&", " and ").replace("||", " or ")
        expression = " ".join(expression.split())
        for event in ("schedule", "workflow_dispatch"):
            for result in ("failure", "success"):
                with self.subTest(event=event, result=result):
                    context = {
                        "always": lambda: True,
                        "github": SimpleNamespace(event_name=event),
                        "needs": SimpleNamespace(
                            regen=SimpleNamespace(result=result),
                            commit=SimpleNamespace(result="skipped"),
                        ),
                    }
                    self.assertEqual(eval(expression, {"__builtins__": {}}, context), result == "failure")


if __name__ == "__main__":
    unittest.main()
