"""Run the actual publication step against a loopback registry."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
from threading import Thread
import unittest
from urllib.parse import parse_qs, urlsplit

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/clawhub-publish.yml"
VERSION = "1.2.3"
PUBLIC = {"skill": {"slug": "fixture"}, "version": {"version": VERSION}}
CLI = """#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" >> "$CALL_LOG"
if [[ "${EXISTING:-false}" == true ]]; then
    printf 'already exists\\n' >&2
    exit 1
fi
printf '%s\\n' "$PUBLISH_RESULT"
"""


@contextmanager
def registry(responses, owner_response=None, listing_response=None):
    requests = []
    pending = list(responses)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append((self.path, self.headers.get("Authorization")))
            if urlsplit(self.path).path == "/api/v1/whoami":
                status, body = owner_response or (200, {"user": {"handle": "fixture-owner"}})
            elif "/versions/" not in self.path:
                status, body = listing_response or (200, {"skill": {"slug": "fixture"}})
            else:
                status, body = pending[0]
                if len(pending) > 1:
                    pending.pop(0)
            if status == 0:
                self.close_connection = True
                return
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            if status == 302:
                self.send_header("Location", "/redirect-target")
            self.end_headers()
            content = body if isinstance(body, str) else json.dumps(body)
            self.wfile.write(content.encode())

        def log_message(self, format, *args):
            return

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class ClawHubPublicationTests(unittest.TestCase):
    def run_publication(self, responses, owner_response=None, listing_response=None, **overrides):
        step = yaml.safe_load(WORKFLOW.read_text())["jobs"]["publish-skills"]["steps"][-1]
        with tempfile.TemporaryDirectory(prefix="clawhub-publication-") as temporary:
            root = Path(temporary)
            skill = root / "skills" / "fixture"
            skill.mkdir(parents=True)
            (skill / "SKILL.md").write_text("# Fixture\n")
            binary = root / "bin"
            binary.mkdir()
            cli = binary / "clawhub"
            cli.write_text(CLI)
            cli.chmod(0o755)
            call_log = root / "calls"
            environment = dict(os.environ)
            environment.update({key: "" for key in step["env"]})
            environment.update(
                PATH=f"{binary}:{os.environ['PATH']}", CALL_LOG=str(call_log),
                SKILLS_DIR=str(skill.parent), SKILL_NAMES='["fixture"]',
                CLAWHUB_TOKEN="EXAMPLE-DO-NOT-USE", SOURCE_REPO="fixture-owner/project",
                SOURCE_REF=f"refs/tags/v{VERSION}", SOURCE_COMMIT="fixture-commit",
                INPUT_VERSION=VERSION, DRY_RUN="false", PUBLISH_ATTEMPTS="1",
                FAIL_ON_UPSTREAM_ERROR="true", PUBLICATION_TIMEOUT_SECONDS="2",
                PUBLICATION_POLL_SECONDS="1",
                PUBLISH_RESULT=json.dumps({"slug": "fixture", "version": VERSION, "status": "published"}),
            )
            environment.update(overrides)
            with registry(responses, owner_response, listing_response) as (url, requests):
                environment.update(REGISTRY=url, SITE=url)
                result = subprocess.run(
                    ["bash", "-c", step["run"]], cwd=root, env=environment,
                    capture_output=True, text=True, timeout=10, check=False,
                )
            calls = call_log.read_text().splitlines() if call_log.exists() else []
            self.assertNotIn(environment["CLAWHUB_TOKEN"], result.stdout + result.stderr)
            return result, calls, requests

    def test_hidden_upload_fails_even_when_upstream_deferral_is_enabled(self):
        for policy in ("true", "false"):
            with self.subTest(policy=policy):
                result, calls, _ = self.run_publication([(403, "pending.publication")], FAIL_ON_UPSTREAM_ERROR=policy)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(len(calls), 1)

    def test_public_version_and_credential_boundaries(self):
        result, calls, requests = self.run_publication([(200, PUBLIC)])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        public = [(path, auth) for path, auth in requests if "/versions/" in path]
        self.assertEqual(len(public), 1)
        self.assertIsNone(public[0][1])
        self.assertEqual(parse_qs(urlsplit(public[0][0]).query), {"ownerHandle": ["fixture-owner"]})
        self.assertEqual([auth for path, auth in requests if path == "/api/v1/whoami"], ["Bearer EXAMPLE-DO-NOT-USE"])

    def test_transient_errors_retry_reads_not_uploads(self):
        for status in (0, 403, 404, 429, 503):
            with self.subTest(status=status):
                result, calls, requests = self.run_publication([(status, "not public"), (200, PUBLIC)])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(len(calls), 1)
                self.assertEqual(sum("/versions/" in path for path, _ in requests), 2)

    def test_wrong_identity_or_malformed_response_fails(self):
        for body in ({"skill": {"slug": "fixture"}, "version": {"version": "1.0.0"}},
                     {"skill": {"slug": "another"}, "version": {"version": VERSION}},
                     {"skill": {"slug": "fixture"}, "version": {"version": VERSION, "publicationStatus": "pending"}},
                     {"version": None}, "not-json"):
            with self.subTest(body=body):
                result, _, _ = self.run_publication([(200, body)])
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_existing_version_still_requires_publication(self):
        for status in (200, 403):
            with self.subTest(status=status):
                result, calls, _ = self.run_publication([(status, PUBLIC)], EXISTING="true")
                self.assertEqual(result.returncode == 0, status == 200, result.stdout + result.stderr)
                self.assertEqual(len(calls), 1)

    def test_dry_run_does_not_query_registry(self):
        result, calls, requests = self.run_publication([(403, "hidden")], DRY_RUN="true", PUBLISH_RESULT='{"status":"would-publish"}')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(requests, [])

    def test_explicit_owner_skips_identity_lookup(self):
        result, _, requests = self.run_publication([(200, PUBLIC)], OWNER="selected-owner")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(requests), 2)
        self.assertEqual(parse_qs(urlsplit(requests[0][0]).query), {"ownerHandle": ["selected-owner"]})

    def test_invalid_upload_metadata_fails(self):
        for body in ("not-json", "{}", '{"slug":"../evil","version":"1.2.3"}',
                     '{"slug":"another","version":"1.2.3"}',
                     '{"slug":"fixture","version":"1.0.0"}', '{"slug":"fixture","version":""}'):
            with self.subTest(body=body):
                result, _, _ = self.run_publication([(200, PUBLIC)], PUBLISH_RESULT=body)
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_invalid_deadlines_fail_before_upload(self):
        for key in ("PUBLICATION_TIMEOUT_SECONDS", "PUBLICATION_POLL_SECONDS"):
            for value in ("0", "-1", "1.5", "no", "9999999999999999999999"):
                with self.subTest(key=key, value=value):
                    result, calls, _ = self.run_publication([(200, PUBLIC)], **{key: value})
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(calls, [])

    def test_permanent_errors_and_redirects_fail(self):
        for status in (302, 400, 401, 409, 422):
            with self.subTest(status=status):
                result, _, requests = self.run_publication([(status, "refused")])
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(any("redirect-target" in path for path, _ in requests))

    def test_invalid_identity_response_fails(self):
        for response in ((401, "refused"), (200, {})):
            with self.subTest(response=response):
                result, _, _ = self.run_publication([(200, PUBLIC)], owner_response=response)
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_hidden_listing_fails_even_when_version_would_be_public(self):
        result, _, requests = self.run_publication([(200, PUBLIC)], listing_response=(403, "hidden"))
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any("/versions/" in path for path, _ in requests))

    def test_default_and_maximum_deadlines_allow_public_versions(self):
        for timeout, poll in (("", ""), ("3600", "60")):
            with self.subTest(timeout=timeout, poll=poll):
                result, _, _ = self.run_publication(
                    [(200, PUBLIC)], PUBLICATION_TIMEOUT_SECONDS=timeout, PUBLICATION_POLL_SECONDS=poll,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
