"""Management commands load optional settings only when invoked and fail without leaking secrets."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from governance.settings import load_settings
from governance.contracts import GovernanceError


class CliTests(unittest.TestCase):
    def test_config_is_optional_to_serving_but_governed_commands_require_it(self):
        result = subprocess.run([sys.executable, "-m", "governance", "status", "--job-id", "unknown", "--config", "does-not-exist.json"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config_not_found", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_config_rejects_plaintext_credentials_and_nonlocal_http(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            for config in [{"api_base": "http://example.com", "admin_token_env": "GOV_TEST_TOKEN"},
                           {"api_base": "https://example.com", "token": "secret-never-print"}]:
                path.write_text(json.dumps(config))
                with self.assertRaises(GovernanceError): load_settings(path)

    def test_native_import_rejected_without_creating_state(self):
        result = subprocess.run([sys.executable, "-m", "governance", "import", "--profile", "native", "--config", "missing.json",
                                 "--manifest", "missing.json", "--bundle", "missing", "--alias", "custom", "--group", "testers"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported_profile", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__": unittest.main()
