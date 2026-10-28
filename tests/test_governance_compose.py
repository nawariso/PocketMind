"""Rendered opt-in project cannot join serving networks or mount privileged resources."""
import json
import os
import shutil
import subprocess
import unittest


@unittest.skipUnless(shutil.which("docker"), "Docker CLI needed for Compose rendering")
class ComposeTests(unittest.TestCase):
    def test_governance_project_remains_separate_and_loopback_only(self):
        result = subprocess.run(["docker", "compose", "--env-file", ".env.governance.example", "-f", "compose.governance.yml", "config", "--format", "json"],
            capture_output=True, text=True, encoding="utf-8", env=dict(os.environ,
                POCKETMIND_GOV_ADMIN_TOKEN="test-admin-not-a-real-secret-12345678",
                POCKETMIND_GOV_AGENT_TOKEN="test-agent-not-a-real-secret-12345678"))
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout)
        self.assertEqual(config["name"], "pocketmind-governance")
        self.assertEqual(set(config["networks"]), {"governance-net"})
        self.assertTrue(config["networks"]["governance-net"]["internal"])
        service = config["services"]["coordinator"]
        self.assertTrue(service["read_only"])
        self.assertTrue(all(p["host_ip"] == "127.0.0.1" for p in service["ports"]))
        self.assertEqual([(v["type"], v["source"]) for v in service["volumes"]], [("volume", "governance_state")])
        self.assertNotIn("container_name", service)


if __name__ == "__main__": unittest.main()
