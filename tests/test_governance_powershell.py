"""Opt-in wrapper test: a real PowerShell demand uses the same durable HTTP workflow."""
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

from governance.server import make_server


@unittest.skipUnless(os.environ.get("GOV_RUN_PWSH_TESTS") == "1" and shutil.which("pwsh"), "Set GOV_RUN_PWSH_TESTS=1 with accessible PowerShell 7")
class PowerShellTests(unittest.TestCase):
    def test_request_and_status_wrappers_complete_one_demand(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            token = "wrapper-test-admin-token-123456789012345"
            server = make_server(root / "server", token, {"local": "wrapper-test-agent-token-123456789012345"}, port=0, embedded_agent=True)
            worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start(); server.start_workers()
            try:
                config = root / "config.json"
                config.write_text(json.dumps({"api_base": f"http://127.0.0.1:{server.server_port}", "test_loopback_http": True, "admin_token_env": "GOV_WRAPPER_TOKEN"}))
                env = dict(os.environ, GOV_WRAPPER_TOKEN=token)
                def invoke(*args):
                    result = subprocess.run([shutil.which("pwsh"), "-NoProfile", "-File", "scripts/model-acquisition.ps1", *args],
                        capture_output=True, text=True, encoding="utf-8", env=env, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn(token, result.stdout + result.stderr)
                    return json.loads(result.stdout)
                job = invoke("request", "-ConfigPath", str(config), "-ModelId", "pocketmind-fixtures/tiny-gguf", "-Alias", "wrapper-test")
                for _ in range(100):
                    latest = server.store.get(job["job_id"])
                    if latest["state"] in {"ready", "failed", "rejected"}: break
                    time.sleep(0.03)
                self.assertEqual(latest["state"], "ready")
                status = invoke("status", "-ConfigPath", str(config), "-JobId", job["job_id"])
                self.assertEqual(status["state"], "ready")
            finally:
                server.shutdown(); server.server_close(); worker.join()


if __name__ == "__main__": unittest.main()
