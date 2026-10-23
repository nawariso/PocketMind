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
        self.model_info = {"data": []}
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
        if path == "/model/info":
            if isinstance(self.model_info, Exception):
                raise self.model_info
            return self.model_info
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

    def test_renamed_alias_only_offers_new_name_and_preserves_existing_keys(self):
        self.pipe.catalog = {"data": [{"id": "old-name"}, {"id": "New-Name"}]}
        self.pipe.model_info = {"data": [
            {"model_name": "old-name", "model_info": {}},
            {"model_name": "New-Name", "model_info": {"pocketmind_rename_from": "old-name"}},
        ]}
        self.pipe.keys = [{"user_id": USER["id"], "models": ["old-name"], "key_alias": "legacy-key", "team_id": "team-1"}]
        models = self.pipe.command("models")
        self.assertIn("`New-Name`", models)
        self.assertIn("Legacy models used by your active keys", models)
        self.assertIn("`old-name`", models)
        self.assertIn("not available", self.pipe.command("new old-name"))
        self.assertEqual(self.generated(), [])
        self.assertIn("Your API key for `New-Name`", self.pipe.command("new New-Name"))
        self.assertEqual(self.generated()[0]["models"], ["New-Name"])
        self.assertIn("old-name", self.pipe.command("list"))
        self.assertEqual(self.pipe.keys[0]["models"], ["old-name"])
        self.assertFalse(any(path == "/key/delete" for _, path, _ in self.pipe.calls))

    def test_legacy_names_are_visible_only_to_their_active_key_owners(self):
        self.pipe.catalog = {"data": [{"id": "old-name"}, {"id": "New-Name"}]}
        self.pipe.model_info = {"data": [{"model_name": "New-Name", "model_info": {"pocketmind_rename_from": "old-name"}}]}
        self.pipe.keys = [
            {"user_id": "another-user", "models": ["old-name"], "key_alias": "someone-elses-key"},
            {"user_id": USER["id"], "models": ["New-Name"], "key_alias": "current-key"},
        ]
        result = self.pipe.command("models")
        self.assertIn("New-Name", result)
        self.assertNotIn("old-name", result)
        self.assertNotIn("someone-elses-key", result)
        self.pipe.keys.append({"user_id": USER["id"], "models": ["old-name"], "key_alias": "legacy-key", "expires": "2999-01-01T00:00:00Z"})
        self.assertIn("old-name", self.pipe.command("models"))
        self.assertIn("not available", self.pipe.command("new old-name"))
        self.assertEqual(self.generated(), [])
        self.pipe.keys.pop()
        self.assertNotIn("old-name", self.pipe.command("models"))

    def test_expired_blocked_or_invalid_expiry_keys_do_not_reveal_legacy_names(self):
        self.pipe.catalog = {"data": [{"id": "old-name"}, {"id": "New-Name"}]}
        self.pipe.model_info = {"data": [{"model_name": "New-Name", "model_info": {"pocketmind_rename_from": "old-name"}}]}
        for status in [{"expires": "2000-01-01T00:00:00Z"}, {"blocked": True}, {"expires": "invalid"}, {"expires": "2000-01-01T00:00:00"}]:
            with self.subTest(status=status):
                self.pipe.keys = [{"user_id": USER["id"], "models": ["old-name"], "key_alias": "inactive", **status}]
                self.assertNotIn("old-name", self.pipe.command("models"))
                self.assertIn("old-name", self.pipe.command("list"))

    def test_manual_current_allowlist_can_still_show_owned_legacy_keys_without_issuing_old_scopes(self):
        self.pipe.valves.auto_discover_models = False
        self.pipe.valves.allowed_models = "New-Name"
        self.pipe.model_info = {"data": [{"model_name": "New-Name", "model_info": {"pocketmind_rename_from": "old-name"}}]}
        self.pipe.keys = [{"user_id": USER["id"], "models": ["old-name"], "key_alias": "legacy"}]
        self.assertIn("old-name", self.pipe.command("models"))
        self.pipe.valves.allowed_models = ""
        self.assertIn("Legacy models", self.pipe.command("models"))
        self.assertIn("No models are enabled", self.pipe.command("new old-name"))
        self.assertEqual(self.generated(), [])

    def test_chained_renames_hide_all_ancestors_but_not_unrelated_aliases(self):
        self.pipe.catalog = {"data": [{"id": name} for name in ["A", "B", "C", "independent"]]}
        self.pipe.model_info = {"data": [
            {"model_name": "A", "model_info": {}},
            {"model_name": "B", "model_info": {"pocketmind_rename_from": "A"}},
            {"model_name": "C", "model_info": {"pocketmind_rename_from": "B"}},
            {"model_name": "independent", "model_info": {}},
        ]}
        self.assertEqual(self.pipe._models(), ["C", "independent"])
        self.pipe.catalog["data"] = [{"id": "A"}, {"id": "independent"}]
        self.assertEqual(self.pipe._models(), ["A", "independent"])

    def test_manual_allowlist_also_hides_legacy_names_without_expanding_permissions(self):
        self.pipe.valves.auto_discover_models = False
        self.pipe.valves.allowed_models = "old-name,New-Name"
        self.pipe.model_info = {"data": [{"model_name": "New-Name", "model_info": {"pocketmind_rename_from": "old-name"}}]}
        self.assertEqual(self.pipe._models(), ["New-Name"])
        self.pipe.valves.allowed_models = "old-name"
        self.assertEqual(self.pipe._models(), [])
        self.assertIn("No models are enabled", self.pipe.command("new old-name"))
        self.assertEqual(self.generated(), [])

    def test_rename_metadata_failure_never_exposes_legacy_names_or_issues_keys(self):
        for metadata in [RuntimeError("unavailable"), {}, {"data": None}, {"data": ["invalid"]},
                         {"data": [{"model_name": "new", "model_info": {"pocketmind_rename_from": 42}}]}]:
            with self.subTest(metadata=metadata):
                self.pipe.model_info = metadata
                self.assertIn("could not be completed", self.pipe.command("new default-general"))
                self.assertEqual(self.generated(), [])
        self.pipe.keys = [{"user_id": USER["id"], "models": ["old-name"], "key_alias": "legacy-key", "team_id": "team-1"}]
        self.assertIn("old-name", self.pipe.command("list"))
        self.assertIn("Revoked 1 key", self.pipe.command("revoke legacy-key"))

    def test_legacy_key_rotation_keeps_original_scope_without_discovery(self):
        self.pipe.catalog = RuntimeError("unavailable")
        self.pipe.model_info = RuntimeError("unavailable")
        self.pipe.keys = [{"user_id": USER["id"], "models": ["old-name"],
                           "key_alias": "legacy-key", "team_id": "team-1", "metadata": {"label": "editor"}}]
        self.assertIn("Your API key for `old-name`", self.pipe.command("rotate legacy-key"))
        self.assertEqual(self.generated()[0]["models"], ["old-name"])
        self.assertFalse(any(path in ("/v1/models", "/model/info") for _, path, _ in self.pipe.calls))

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

    def test_one_key_can_cover_several_listed_models(self):
        self.pipe.catalog = {"data": [{"id": "default-general"}, {"id": "default-ocr"}, {"id": "Pocket-Qwen"}]}
        result = self.pipe.command("new Pocket-Qwen DEFAULT-GENERAL default-ocr default-general as my-app")
        self.assertIn("Your API key for `Pocket-Qwen`, `default-general`, `default-ocr`", result)
        self.assertIn("cannot call other models", result)
        payload = self.generated()[0]
        self.assertEqual(payload["models"], ["Pocket-Qwen", "default-general", "default-ocr"])
        self.assertEqual(payload["metadata"]["label"], "my-app")
        self.assertEqual(payload["team_id"], "team-1")
        self.assertIn("my-app", payload["key_alias"])
        self.assertLessEqual(len(payload["key_alias"]), 90)

    def test_unavailable_model_in_a_list_never_widens_or_issues_a_key(self):
        self.pipe.catalog = {"data": [{"id": "default-general"}, {"id": "default-ocr"}]}
        self.pipe.model_info = {"data": [{"model_name": "default-ocr", "model_info": {"pocketmind_rename_from": "old-ocr"}}]}
        self.assertIn("not a member", self.pipe.command("new default-general old-ocr"))
        self.assertIn("not available", self.pipe.command("new old-ocr default-general"))
        self.assertEqual(self.generated(), [])

    def test_multi_model_keys_are_managed_by_alias_and_counted_per_model(self):
        self.pipe.catalog = {"data": [{"id": "default-general"}, {"id": "default-ocr"}]}
        self.pipe.keys = [{"user_id": USER["id"], "models": ["default-general", "default-ocr"],
                           "key_alias": "multi-key", "team_id": "team-1", "metadata": {"label": "app"}}]
        models = self.pipe.command("models")
        self.assertIn("| `default-general` | 1 |", models)
        self.assertIn("| `default-ocr` | 1 |", models)
        self.assertNotIn("earlier or unavailable", models)
        self.assertIn("`default-general, default-ocr`", self.pipe.command("list"))
        # A model name alone must not revoke or rotate a key that also covers other models.
        self.assertIn("No matching key", self.pipe.command("revoke default-general"))
        self.assertIn("Your API key for `default-general`, `default-ocr`", self.pipe.command("rotate multi-key"))
        self.assertEqual(self.generated()[0]["models"], ["default-general", "default-ocr"])
        self.assertEqual(self.generated()[0]["metadata"]["label"], "app")
        self.assertIn("Revoked 1 key", self.pipe.command("revoke multi-key"))

    def test_task_and_unapproved_user_never_discover_or_issue_keys(self):
        self.assertEqual(self.pipe.command("new default-general", task="title_generation"), "API Key Manager")
        self.assertIn("approved", self.pipe.command("new default-general", user={"id": "pending", "role": "pending"}))
        self.assertEqual(self.pipe.calls, [])


if __name__ == "__main__":
    unittest.main()
