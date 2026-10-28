"""Reject approval/source/path mistakes before any installation side effect."""
import copy
import hashlib
import tempfile
import unittest
from pathlib import Path

from governance.contracts import GovernanceError, demand, manifest, verify_bundle


def release(data=b"GGUF fixture only"):
    return {
        "schema_version": 1, "release_id": "release-test", "status": "approved",
        "source": {"provider": "huggingface", "model_id": "example/model",
                   "revision": "a" * 40},
        "license": "MIT", "runtime": {"name": "ollama", "version": "0.32.6"},
        "files": [{"path": "model.gguf", "size": len(data),
                   "sha256": hashlib.sha256(data).hexdigest(), "role": "weights"},
                  {"path": "LICENSE", "size": 3,
                   "sha256": hashlib.sha256(b"MIT").hexdigest(), "role": "license"}],
        "metadata": {"template": "{{ .Prompt }}", "parameters": {"temperature": 0.5}},
        "scans": [{"tool": "fixture-scanner", "version": "1", "format": "gguf",
                   "status": "passed", "covered_files": ["model.gguf", "LICENSE"]}],
        "evaluation": {"status": "passed", "evidence_id": "eval-test"},
        "approval": {"mode": "policy", "identity": "test-authority", "policy_version": "1",
                     "approved_at": "2026-10-28T00:00:00Z"},
    }


def request(**changes):
    value = dict(source="huggingface", model_id="example/model", revision="main",
                 artifact="model.gguf", alias="test-model", target_id="local",
                 access_group_id="testers", purpose="POC")
    value.update(changes)
    return value


class ContractTests(unittest.TestCase):
    def test_provider_links_are_normalized_but_arbitrary_urls_rejected(self):
        value = demand(request(model_id="https://huggingface.co/example/model"))
        self.assertEqual(value["model_id"], "example/model")
        self.assertEqual(demand(request(source="ollama", model_id="https://ollama.com/library/qwen3:4b"))["model_id"], "qwen3:4b")
        for url in ["http://169.254.169.254/latest", "https://huggingface.co.evil/x/y",
                    "https://huggingface.co/example/model?token=secret", "https://user@huggingface.co/x/y"]:
            with self.subTest(url=url), self.assertRaises(GovernanceError):
                demand(request(model_id=url))

    def test_protected_alias_and_unknown_request_fields_are_rejected(self):
        self.assertEqual(demand(request(alias="ผู้ช่วย-ไทย"))["alias"], "ผู้ช่วย-ไทย")
        for change in [{"alias": "default-general"}, {"alias": "default-ocr"},
                       {"alias": "--help"}, {"access_group_id": "*"}, {"target_id": "../x"},
                       {"source": "other"}, {"approved": True}, {"purpose": ""}]:
            with self.subTest(change=change), self.assertRaises(GovernanceError):
                demand(request(**change))

    def test_release_requires_complete_immutable_approval(self):
        self.assertEqual(manifest(release())["release_id"], "release-test")
        variants = []
        for field, value in [("status", "revoked"), ("schema_version", 2), ("schema_version", True), ("files", []), ("license", "")]:
            item = release(); item[field] = value; variants.append(item)
        for state in ["skipped", "error", "unsupported"]:
            item = release(); item["scans"][0]["status"] = state; variants.append(item)
        item = release(); item["source"]["revision"] = "main"; variants.append(item)
        item = release(); item["scans"][0]["covered_files"] = ["LICENSE"]; variants.append(item)
        item = release(); item["metadata"]["from"] = "public-model"; variants.append(item)
        item = release(); item["approval"]["policy_version"] = ""; variants.append(item)
        for item in variants:
            with self.subTest(item=item), self.assertRaises(GovernanceError): manifest(item)

    def test_unsafe_duplicate_and_case_colliding_paths_are_rejected(self):
        for path in ["../model.gguf", "/model.gguf", "C:/model.gguf", "a\\b.gguf", "a/../model.gguf", "a:stream", "CON", "a."]:
            item = release(); item["files"][0]["path"] = path
            with self.subTest(path=path), self.assertRaises(GovernanceError): manifest(item)
        item = release(); item["files"].append(dict(item["files"][0], path="MODEL.GGUF"))
        with self.assertRaises(GovernanceError): manifest(item)

    def test_bundle_hash_size_and_unlisted_file_are_enforced(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / "model.gguf").write_bytes(b"GGUF fixture only"); (root / "LICENSE").write_bytes(b"MIT")
            verify_bundle(release(), root)
            (root / "extra.py").write_text("untrusted")
            with self.assertRaises(GovernanceError): verify_bundle(release(), root)
            (root / "extra.py").unlink(); (root / "model.gguf").write_bytes(b"GGUF tampered!!!")
            with self.assertRaises(GovernanceError): verify_bundle(release(), root)

    def test_ollama_release_needs_manifest_and_blob_digests(self):
        item = release(); item["source"] = {"provider": "ollama", "model_id": "qwen3:4b", "revision": "sha256:" + "a" * 64,
                                          "blob_digests": ["sha256:" + item["files"][0]["sha256"]]}
        manifest(item)
        item["source"]["blob_digests"] = []
        with self.assertRaises(GovernanceError): manifest(item)


if __name__ == "__main__": unittest.main()
