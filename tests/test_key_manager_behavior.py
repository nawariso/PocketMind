"""Behavior checks for model discovery and scoped key issuance; no live services required."""

import asyncio
import importlib.util
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "openwebui/functions/api_key_manager.py"
SPEC = importlib.util.spec_from_file_location("api_key_manager", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

USER = {"id": "user-1", "email": "person@example.test", "role": "user"}


class FakePipe(MODULE.Pipe):
    def __init__(self):
        super().__init__()
        self.valves.auto_sync_minutes = 0
        self.valves.cooldown_seconds = 0
        self.catalog = {"data": [{"id": "default-general"}]}
        self.keys = []
        self.calls = []

    def _master_key(self):
        return "test-only-master"

    def _litellm(self, method, path, body=None, tolerate=()):
        self.calls.append((method, path, body))
        if path == "/v1/models":
            if isinstance(self.catalog, Exception):
                raise self.catalog
            return self.catalog
        if path.startswith("/key/list?"):
            return {"keys": self.keys}
        if path == "/team/list":
            return [{"team_id": "team-1", "team_alias": "Engineering",
                     "members_with_roles": [{"user_email": USER["email"]}]}]
        if path == "/key/generate":
            return {"key": "test-only-generated", "expires": "tomorrow"}
        if path == "/key/delete":
            return {}
        raise AssertionError(f"Unexpected request: {method} {path}")

    def command(self, text, user=None, task=None):
        return asyncio.run(self.pipe(
            {"messages": [{"role": "user", "content": text}]},
            __user__=USER if user is None else user,
            __task__=task,
        ))


class ModelDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.pipe = FakePipe()

    def generated(self):
        return [body for method, path, body in self.pipe.calls if path == "/key/generate"]

    def test_new_model_becomes_available_without_changing_saved_valves(self):
        self.pipe.valves.allowed_models = "default-general,default-ocr"
        self.assertNotIn("analysis-35b", self.pipe.command("models"))
        self.pipe.catalog["data"].append({"id": "analysis-35b"})
        self.assertIn("analysis-35b", self.pipe.command("models"))
        result = self.pipe.command("new ANALYSIS-35B as editor")
        self.assertIn("Your API key for `analysis-35b`", result)
        self.assertEqual(len(self.generated()), 1)
        payload = self.generated()[0]
        self.assertEqual(payload["models"], ["analysis-35b"])
        self.assertEqual(payload["user_id"], USER["id"])
        self.assertEqual(payload["team_id"], "team-1")
        self.assertEqual(payload["metadata"]["label"], "editor")
        self.assertEqual(payload["duration"], "30d")
        self.assertEqual(payload["max_parallel_requests"], 1)
        self.assertEqual(payload["rpm_limit"], 20)
        self.assertEqual(payload["tpm_limit"], 30000)
        self.assertEqual(sum(path == "/v1/models" for _, path, _ in self.pipe.calls), 3)

    def test_removed_model_cannot_receive_new_key(self):
        self.pipe.catalog = {"data": [{"id": "custom-other"}]}
        self.assertIn("not available", self.pipe.command("new default-general"))
        self.assertEqual(self.generated(), [])

    def test_custom_aliases_need_no_prefix_and_preserve_registered_name(self):
        for alias in ["Qwen3.6-35B", "namespace/model:tag", "โมเดลภาษาไทย"]:
            with self.subTest(alias=alias):
                self.pipe.catalog = {"data": [{"id": alias}]}
                self.assertIn("Your API key", self.pipe.command(f"new {alias}"))
                self.assertEqual(self.generated()[-1]["models"], [alias])

    def test_manual_allowlist_remains_available(self):
        self.pipe.valves.auto_discover_models = False
        self.pipe.valves.allowed_models = " default-general, default-general "
        self.pipe.catalog = RuntimeError("Catalog unavailable")
        self.assertIn("not available", self.pipe.command("new analysis-35b"))
        self.assertIn("Your API key", self.pipe.command("new default-general"))
        self.assertFalse(any(path == "/v1/models" for _, path, _ in self.pipe.calls))

    def test_empty_catalog_and_empty_manual_list_never_issue_unrestricted_key(self):
        self.pipe.catalog = {"data": []}
        self.assertIn("No models are enabled", self.pipe.command("new default-general"))
        self.pipe.valves.auto_discover_models = False
        self.pipe.valves.allowed_models = ""
        self.assertIn("No models are enabled", self.pipe.command("new default-general"))
        self.assertEqual(self.generated(), [])

    def test_failed_or_malformed_discovery_does_not_fall_back_to_saved_allowlist(self):
        for catalog in [RuntimeError("Catalog unavailable"), {}, {"data": None}, []]:
            with self.subTest(catalog=catalog):
                self.pipe.catalog = catalog
                self.assertIn("could not be completed", self.pipe.command("new default-general"))
                self.assertEqual(self.generated(), [])

    def test_catalog_filters_wildcards_and_invalid_entries_and_deduplicates(self):
        self.pipe.catalog = {"data": [
            {"id": "default-general"}, {"id": "default-general"}, {"id": "*"},
            {"id": "lab-*"}, {"id": ""}, {"id": None}, {"id": 42},
            {"id": "bad alias"}, {}, "invalid",
        ]}
        self.assertEqual(self.pipe._models(), ["default-general"])
        self.assertIn("not available", self.pipe.command("new *"))
        self.assertEqual(self.generated(), [])

    def test_list_and_revoke_work_without_model_discovery(self):
        self.pipe.catalog = RuntimeError("Catalog unavailable")
        self.pipe.keys = [{"user_id": USER["id"], "models": ["removed-model"],
                           "key_alias": "own-key"},
                          {"user_id": "another-user", "models": ["default-general"],
                           "key_alias": "other-key"}]
        result = self.pipe.command("list")
        self.assertIn("own-key", result)
        self.assertNotIn("other-key", result)
        self.assertIn("Revoked 1 key", self.pipe.command("revoke own-key"))
        self.assertFalse(any(path == "/v1/models" for _, path, _ in self.pipe.calls))
        deleted = [body for _, path, body in self.pipe.calls if path == "/key/delete"]
        self.assertEqual(deleted, [{"key_aliases": ["own-key"]}])

    def test_empty_new_command_shows_discovered_example(self):
        self.pipe.catalog = {"data": [{"id": "analysis-35b"}]}
        self.assertIn("new analysis-35b", self.pipe.command("new"))
        self.assertEqual(self.generated(), [])

    def test_key_cap_and_cooldown_are_preserved(self):
        self.pipe.valves.max_keys_per_user = 1
        self.pipe.keys = [{"user_id": USER["id"], "models": ["default-general"],
                           "key_alias": "own-key"}]
        self.assertIn("maximum is 1", self.pipe.command("new default-general"))
        self.assertEqual(self.generated(), [])
        self.pipe.keys = []
        self.pipe.valves.cooldown_seconds = 20
        self.assertIn("Your API key", self.pipe.command("new default-general"))
        self.assertIn("Please wait", self.pipe.command("new default-general"))
        self.assertEqual(len(self.generated()), 1)

    def test_task_and_unapproved_user_never_discover_or_issue_keys(self):
        self.assertEqual(self.pipe.command("new default-general", task="title_generation"), "API Key Manager")
        self.assertIn("approved", self.pipe.command("new default-general", user={"id": "pending", "role": "pending"}))
        self.assertEqual(self.pipe.calls, [])


if __name__ == "__main__":
    unittest.main()
