"""Check which events and refs make docker-image-workflow.yml publish an image.

Run: python -m pytest tests/test_docker_publish_events.py
Needs: pytest and PyYAML. No token or network.

The job conditions are evaluated as written in the workflow, with a small
evaluator for the GitHub expression syntax they use.
"""

import re
from pathlib import Path

import pytest
import yaml

WORKFLOW = (
    Path(__file__).resolve().parents[1]
    / ".github/workflows/docker-image-workflow.yml"
)

TOKEN = re.compile(
    r"\s*(?:(?P<string>'[^']*')|(?P<op>==|!=|&&|\|\||[()!,])"
    r"|(?P<name>[A-Za-z_][A-Za-z0-9_.]*))"
)


def evaluate(expression, context):
    """Evaluate a GitHub expression built from ==, !=, &&, ||, !, parentheses,
    startsWith(), string literals and context names."""
    tokens = []
    position = 0
    expression = expression.strip()
    while position < len(expression):
        match = TOKEN.match(expression, position)
        assert match, f"cannot parse {expression[position:]!r}"
        position = match.end()
        tokens.append(match.group(match.lastgroup))
    index = 0

    def peek():
        return tokens[index] if index < len(tokens) else None

    def take(expected=None):
        nonlocal index
        token = tokens[index]
        assert expected is None or token == expected, (token, expected)
        index += 1
        return token

    def primary():
        token = take()
        if token == "(":
            value = disjunction()
            take(")")
            return value
        if token == "!":
            return not primary()
        if token.startswith("'"):
            return token[1:-1]
        if token == "startsWith":
            take("(")
            text = disjunction()
            take(",")
            prefix = disjunction()
            take(")")
            return text.startswith(prefix)
        assert token in context, f"unknown name {token}"
        return context[token]

    def comparison():
        value = primary()
        while peek() in ("==", "!="):
            operator = take()
            other = primary()
            value = (value == other) if operator == "==" else (value != other)
        return value

    def conjunction():
        value = comparison()
        while peek() == "&&":
            take()
            right = comparison()
            value = value and right
        return value

    def disjunction():
        value = conjunction()
        while peek() == "||":
            take()
            right = conjunction()
            value = value or right
        return value

    result = disjunction()
    assert index == len(tokens), f"trailing tokens in {expression!r}"
    return bool(result)


@pytest.fixture(scope="module")
def jobs():
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]


CASES = [
    ("push", "refs/heads/main", True),
    ("push", "refs/heads/master", True),
    ("push", "refs/tags/v1.2.3", True),
    ("workflow_dispatch", "refs/tags/v1.2.3", True),
    ("schedule", "refs/heads/main", False),
    ("workflow_dispatch", "refs/heads/main", False),
    ("schedule", "refs/heads/master", False),
    ("push", "refs/heads/feature", False),
    ("pull_request", "refs/pull/7/merge", False),
]


@pytest.mark.parametrize(
    ("job", "build_targets"),
    [("build", ""), ("plan-multi", '[{"tag_suffix":""}]')],
)
@pytest.mark.parametrize(("event", "ref", "publishes"), CASES)
def test_image_jobs_publish_only_from_pushes_and_tags(
    jobs, job, build_targets, event, ref, publishes
):
    context = {
        "github.event_name": event,
        "github.ref": ref,
        "inputs.build_targets": build_targets,
    }
    assert evaluate(jobs[job]["if"], context) is publishes


@pytest.mark.parametrize(
    ("job", "build_targets"),
    [("build", '[{"tag_suffix":""}]'), ("plan-multi", "")],
)
def test_image_jobs_keep_their_build_target_split(jobs, job, build_targets):
    context = {
        "github.event_name": "push",
        "github.ref": "refs/heads/main",
        "inputs.build_targets": build_targets,
    }
    assert evaluate(jobs[job]["if"], context) is False


def test_evaluator_rejects_unknown_names():
    with pytest.raises(AssertionError):
        evaluate("github.unknown == 'x'", {})
