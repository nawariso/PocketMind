"""Admin/API authorization and one-request end-to-end HTTP delivery."""
import http.cookiejar
import json
import re
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from governance.server import make_server
from test_governance_contracts import request


class AdminTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.server = make_server(Path(self.tmp.name), "admin-token-for-testing-123456789012345",
                                  {"local": "agent-token-for-testing-123456789012345"}, port=0, embedded_agent=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.server.start_workers()
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(); self.tmp.cleanup()
    def call(self, method, path, value=None, token=None, headers=None):
        headers = dict(headers or {})
        if token: headers["Authorization"] = "Bearer " + token
        data = json.dumps(value).encode() if value is not None else None
        if value is not None: headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with self.opener.open(req, timeout=5) as response: return response.status, response.read().decode()
        except urllib.error.HTTPError as exc:
            with exc: return exc.code, exc.read().decode()

    def test_anonymous_and_agent_cannot_submit_or_read_admin_jobs(self):
        data = request(model_id="pocketmind-fixtures/tiny-gguf")
        for token in [None, "agent-token-for-testing-123456789012345"]:
            self.assertEqual(self.call("POST", "/model-acquisitions", data, token, {"Idempotency-Key": "one"})[0], 401)
        self.assertEqual(self.call("GET", "/jobs")[0], 200)  # Login redirect followed by urllib.
        self.assertIn("Sign in", self.call("GET", "/jobs")[1])

    def test_request_reaches_ready_and_status_exposes_no_lease_or_tokens(self):
        token = "admin-token-for-testing-123456789012345"
        status, raw = self.call("POST", "/model-acquisitions", request(model_id="pocketmind-fixtures/tiny-gguf"), token, {"Idempotency-Key": "one"})
        self.assertEqual(status, 202)
        job_id = json.loads(raw)["job_id"]
        for _ in range(100):
            status, raw = self.call("GET", "/model-acquisitions/" + job_id, token=token)
            value = json.loads(raw)
            if value["state"] in {"ready", "failed", "rejected"}: break
            time.sleep(0.03)
        self.assertEqual(value["state"], "ready", raw)
        self.assertTrue(all(s["status"] == "succeeded" for s in value["steps"]))
        self.assertNotIn("lease", value); self.assertNotIn(token, raw)
        self.assertEqual(self.server.runtime.read()["groups"], {"test-model": "testers"})

    def test_cookie_auth_requires_csrf_and_api_does_not_accept_cookie_as_bearer(self):
        body = urllib.parse.urlencode({"token": "admin-token-for-testing-123456789012345"}).encode()
        req = urllib.request.Request(self.base + "/login", data=body, headers={"Origin": self.base})
        with self.opener.open(req) as response: page = response.read().decode()
        self.assertIn("SYNTHETIC FIXTURE", page)
        self.assertIn("Select a model", page)
        self.assertEqual(self.call("POST", "/jobs", {})[0], 403)
        self.assertEqual(self.call("GET", "/model-acquisitions")[0], 401)
        self.assertNotIn("admin-token-for-testing", page)

    def test_wrong_origin_and_forged_target_are_rejected(self):
        req = urllib.request.Request(self.base + "/login", data=b"token=x", headers={"Origin": "https://evil.example"})
        with self.assertRaises(urllib.error.HTTPError) as error: self.opener.open(req)
        self.assertEqual(error.exception.code, 403)
        error.exception.close()
        status, _ = self.call("POST", "/agent/claim", {"target_id": "other"}, "agent-token-for-testing-123456789012345")
        self.assertEqual(status, 403)

    def test_separate_host_agent_delivers_over_authenticated_http(self):
        # Disable embedded delivery: only the separately invoked agent can finish this job.
        self.server.embedded_agent = False
        token = "admin-token-for-testing-123456789012345"
        status, raw = self.call("POST", "/model-acquisitions", request(model_id="pocketmind-fixtures/tiny-gguf"), token, {"Idempotency-Key": "remote-agent"})
        self.assertEqual(status, 202)
        job_id = json.loads(raw)["job_id"]
        for _ in range(100):
            value = json.loads(self.call("GET", "/model-acquisitions/" + job_id, token=token)[1])
            if value["release_id"]: break
            time.sleep(0.03)
        root = Path(self.tmp.name)
        config = root / "client.json"
        config.write_text(json.dumps({"api_base": self.base, "test_loopback_http": True,
            "agent_token_env": "GOV_TEST_AGENT", "target_id": "local", "state_dir": str(root / "remote-agent")}))
        result = subprocess.run([sys.executable, "-X", "utf8", "-m", "governance", "agent", "--fixture", "--once", "--config", str(config)],
                                capture_output=True, text=True, env=dict(os.environ, GOV_TEST_AGENT="agent-token-for-testing-123456789012345"), timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(self.call("GET", "/model-acquisitions/" + job_id, token=token)[1])
        self.assertEqual(value["state"], "ready", value)

    def test_old_release_authorization_is_not_limited_by_recent_job_page(self):
        self.server.embedded_agent = False
        old = self.server.store.submit(request(model_id="pocketmind-fixtures/tiny-gguf"), "old-release")
        self.server.source.run_once("local")
        old = self.server.store.get(old["job_id"])
        for index in range(101):
            self.server.store.submit(request(alias=f"new-{index}", model_id="pocketmind-fixtures/tiny-gguf"), f"new-{index}")
        status, raw = self.call("GET", f"/model-releases/{old['release_id']}/manifest", token="agent-token-for-testing-123456789012345")
        self.assertEqual(status, 200, raw)


if __name__ == "__main__": unittest.main()
