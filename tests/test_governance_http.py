"""Exercise management protocol boundaries against actual loopback HTTP."""
import json
import hashlib
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from governance.contracts import GovernanceError
from governance.http import Api, AuthorityClient
from governance.runtime import OllamaRuntime
from test_governance_contracts import release


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self): self.respond()
    def do_POST(self): self.respond()
    def do_HEAD(self): self.respond()
    def respond(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.server.calls.append((self.command, self.path, dict(self.headers), raw))
        status, value = self.server.responses.get((self.command, self.path), (404, {"error": "not found"}))
        raw = json.dumps(value).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw))); self.end_headers()
        if self.command != "HEAD": self.wfile.write(raw)


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.calls = []; self.server.responses = {}
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.api = Api(self.base, "test-token", allow_loopback=True)
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()

    def test_tls_required_except_explicit_loopback_and_errors_do_not_echo_secrets(self):
        for url in ["http://example.com", "https://token@example.com", "https://example.com?x=1"]:
            with self.assertRaises(GovernanceError): Api(url, "secret")
        self.server.responses[("GET", "/secret")] = (403, {"token": "secret-do-not-leak"})
        with self.assertRaisesRegex(GovernanceError, "upstream_403") as error: self.api.json("GET", "/secret")
        self.assertNotIn("secret-do-not-leak", str(error.exception))

    def test_authority_fetches_manifest_by_id_and_never_uses_bundle_as_authority(self):
        self.server.responses[("GET", "/model-releases/release-test/manifest")] = (200, release())
        value = AuthorityClient(self.api).manifest("release-test")
        self.assertEqual(value["release_id"], "release-test")
        with self.assertRaises(GovernanceError): AuthorityClient(self.api).manifest("../escape")

    def test_local_creation_uploads_bytes_and_has_no_remote_from(self):
        self.server.responses[("GET", "/api/tags")] = (200, {"models": []})
        self.server.responses[("POST", "/api/create")] = (200, {"status": "success"})
        value = release(); weight = value["files"][0]
        self.server.responses[("POST", "/api/blobs/sha256:" + weight["sha256"])] = (201, {})
        runtime = OllamaRuntime(self.api, self.api, self.api)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / "model.gguf").write_bytes(b"GGUF fixture only"); (root / "LICENSE").write_text("MIT")
            runtime.install("pm-test", value, root)
        create = json.loads(next(c[3] for c in self.server.calls if c[1] == "/api/create"))
        self.assertNotIn("from", create)
        self.assertEqual(create["files"], {"model.gguf": "sha256:" + weight["sha256"]})
        self.assertEqual(create["stream"], False)
        blob = next(c for c in self.server.calls if c[0] == "POST" and c[1].startswith("/api/blobs/"))
        self.assertEqual(blob[3], b"GGUF fixture only")

    def test_existing_physical_name_is_never_overwritten(self):
        self.server.responses[("GET", "/api/tags")] = (200, {"models": [{"name": "pm-test:latest"}]})
        self.server.responses[("POST", "/api/show")] = (200, {"license": "unowned", "modelfile": "FROM other"})
        with self.assertRaisesRegex(GovernanceError, "model_conflict"):
            OllamaRuntime(self.api, self.api, self.api).install("pm-test", release(), Path("unused"))
        self.assertFalse(any(c[1] == "/api/create" for c in self.server.calls))

    def test_uncertain_create_recovers_only_when_existing_blob_and_provenance_match(self):
        from governance.contracts import canonical
        value = release()
        marker = "PocketMind approved manifest SHA256: " + hashlib.sha256(canonical(value).encode()).hexdigest()
        self.server.responses[("GET", "/api/tags")] = (200, {"models": [{"name": "pm-test:latest"}]})
        self.server.responses[("POST", "/api/show")] = (200, {"license": "MIT\n" + marker,
            "modelfile": "FROM /models/blobs/sha256-" + value["files"][0]["sha256"] + "\n"})
        runtime = OllamaRuntime(self.api, self.api, self.api)
        runtime.install("pm-test", value, Path("unused"))
        self.assertFalse(any(c[1] == "/api/create" for c in self.server.calls))
        self.server.responses[("POST", "/api/show")][1]["modelfile"] = "FROM /models/blobs/sha256-" + "0" * 64
        with self.assertRaisesRegex(GovernanceError, "model_conflict"): runtime.install("pm-test", value, Path("unused"))

    def test_workspace_grant_is_explicit_group_only_and_existing_unowned_record_conflicts(self):
        self.server.responses[("GET", "/api/v1/models/model?id=custom")] = (404, {})
        self.server.responses[("POST", "/api/v1/models/create")] = (200, {})
        runtime = OllamaRuntime(self.api, self.api, self.api)
        runtime.grant("custom", "testers", release())
        body = json.loads(next(c[3] for c in self.server.calls if c[0] == "POST"))
        self.assertEqual(body["access_grants"], [{"principal_type": "group", "principal_id": "testers", "permission": "read"}])
        self.server.responses[("GET", "/api/v1/models/model?id=custom")] = (200, {"id": "custom", "meta": {}})
        with self.assertRaisesRegex(GovernanceError, "workspace_conflict"): runtime.grant("custom", "testers", release())


if __name__ == "__main__": unittest.main()
