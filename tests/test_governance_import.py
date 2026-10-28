"""Real verification/orchestration; runtime double replaces only model/server side effects."""
import copy
import tempfile
import unittest
from pathlib import Path

from governance.contracts import GovernanceError
from governance.importer import Importer
from test_governance_contracts import release


class Authority:
    def __init__(self): self.value = release()
    def manifest(self, release_id): return copy.deepcopy(self.value)


class Runtime:
    def __init__(self):
        self.models = {}; self.aliases = {}; self.groups = {}; self.creates = 0; self.fail_grant = False
    def preflight(self, value, alias, group): pass
    def install(self, name, value, path):
        if name in self.models:
            if self.models[name] != value["release_id"]: raise GovernanceError("model_conflict")
            return
        self.models[name] = value["release_id"]; self.creates += 1
    def smoke(self, name): return "synthetic response"
    def register(self, alias, name, value): self.aliases[alias] = name
    def grant(self, alias, group, value):
        if self.fail_grant: raise GovernanceError("grant_failed")
        self.groups[alias] = group
    def verify(self, alias, group, value):
        if self.groups.get(alias) != group: raise GovernanceError("grant_not_verified")


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.bundle = self.root / "bundle"; self.bundle.mkdir()
        (self.bundle / "model.gguf").write_bytes(b"GGUF fixture only"); (self.bundle / "LICENSE").write_bytes(b"MIT")
        self.auth = Authority(); self.runtime = Runtime()
        self.importer = Importer(self.root / "state", self.auth, self.runtime)
    def tearDown(self): self.tmp.cleanup()

    def test_trusted_release_installs_and_retry_reconciles_without_duplicate_create(self):
        result = self.importer.run(release(), self.bundle, "test-alias", "testers")
        self.assertEqual(result["state"], "ready")
        self.assertEqual(self.runtime.groups, {"test-alias": "testers"})
        result2 = self.importer.run(release(), self.bundle, "test-alias", "testers")
        self.assertEqual(self.runtime.creates, 1)
        self.assertEqual(result2["release_id"], "release-test")

    def test_untrusted_manifest_or_current_revocation_prevents_install(self):
        for mode in ["tampered", "revoked"]:
            value = release()
            if mode == "tampered": value["metadata"]["system"] = "changed after approval"
            else: self.auth.value["status"] = "revoked"
            with self.subTest(mode=mode), self.assertRaises(GovernanceError):
                self.importer.run(value, self.bundle, "test-alias", "testers")
        self.assertEqual(self.runtime.creates, 0)

    def test_check_only_validates_without_runtime_mutation(self):
        result = self.importer.run(release(), self.bundle, "test-alias", "testers", check_only=True)
        self.assertEqual(result["state"], "validated")
        self.assertEqual(self.runtime.models, {})

    def test_grant_failure_is_not_ready_and_resume_does_not_reinstall(self):
        self.runtime.fail_grant = True
        with self.assertRaises(GovernanceError): self.importer.run(release(), self.bundle, "test-alias", "testers")
        self.assertEqual(self.runtime.groups, {})
        self.runtime.fail_grant = False
        result = self.importer.run(release(), self.bundle, "test-alias", "testers")
        self.assertEqual(result["state"], "ready")
        self.assertEqual(self.runtime.creates, 1)

    def test_modified_staging_and_bundle_symlinks_cannot_reach_runtime(self):
        (self.bundle / "model.gguf").write_bytes(b"tampered")
        with self.assertRaises(GovernanceError): self.importer.run(release(), self.bundle, "test-alias", "testers")
        self.assertEqual(self.runtime.creates, 0)

    def test_existing_receipt_cannot_be_reused_for_other_group(self):
        self.importer.run(release(), self.bundle, "test-alias", "testers")
        with self.assertRaises(GovernanceError): self.importer.run(release(), self.bundle, "test-alias", "everyone")

    def test_modified_receipt_cannot_redirect_recovery_to_another_physical_model(self):
        import json
        self.importer.run(release(), self.bundle, "test-alias", "testers")
        path = next((self.root / "state").glob("*.json"))
        saved = json.loads(path.read_text()); saved["physical_name"] = "pm-unrelated"
        path.write_text(json.dumps(saved))
        with self.assertRaisesRegex(GovernanceError, "receipt_conflict"):
            self.importer.run(release(), self.bundle, "test-alias", "testers")


if __name__ == "__main__": unittest.main()
