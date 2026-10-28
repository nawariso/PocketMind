"""One demand reaches ready, including grants, using isolated synthetic fixtures."""
import tempfile
import unittest
from pathlib import Path

from governance.contracts import GovernanceError
from governance.delivery import FixtureAcquisition, FixtureRuntime, Delivery, LocalClient
from governance.jobs import JobStore
from test_governance_contracts import request


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.store = JobStore(self.root / "jobs.db")
        self.source = FixtureAcquisition(self.store, self.root / "releases", {"local": ["testers"]})
        self.runtime = FixtureRuntime(self.root / "runtime.json")
        self.client = LocalClient(self.store)
    def tearDown(self): self.tmp.cleanup()
    def submit(self, **change):
        return self.store.submit(request(model_id="pocketmind-fixtures/tiny-gguf", **change), "key-1")

    def test_single_request_runs_to_group_availability_and_all_checkpoints(self):
        job = self.submit()
        self.source.run_once("local")
        Delivery(self.client, self.source, self.runtime, self.root / "agent", "local").run_once()
        result = self.store.get(job["job_id"])
        self.assertEqual(result["state"], "ready")
        self.assertTrue(all(s["status"] == "succeeded" for s in result["steps"]))
        self.assertEqual(self.runtime.read()["groups"], {"test-model": "testers"})
        self.assertEqual(len(self.runtime.read()["models"]), 1)

    def test_restart_after_grant_failure_resumes_without_duplicate_install(self):
        job = self.submit(); self.source.run_once("local")
        class FailedGrant(FixtureRuntime):
            def grant(self, *args): raise GovernanceError("grant_unavailable")
        Delivery(self.client, self.source, FailedGrant(self.root / "runtime.json"), self.root / "agent", "local").run_once()
        failed = self.store.get(job["job_id"])
        self.assertEqual(failed["state"], "failed")
        self.assertEqual(failed["steps"][-1]["error"], "grant_unavailable")
        self.store.retry(job["job_id"])
        restarted = Delivery(LocalClient(JobStore(self.root / "jobs.db")), self.source,
                             FixtureRuntime(self.root / "runtime.json"), self.root / "agent", "local")
        restarted.run_once()
        self.assertEqual(self.store.get(job["job_id"])["state"], "ready")
        self.assertEqual(len(self.runtime.read()["models"]), 1)

    def test_unapproved_policy_and_unsupported_models_never_install(self):
        job = self.submit(revision="review-required"); self.source.run_once("local")
        self.assertEqual(self.store.get(job["job_id"])["state"], "awaiting_approval")
        self.assertFalse(Delivery(self.client, self.source, self.runtime, self.root / "agent", "local").run_once())
        self.assertEqual(self.runtime.read()["models"], {})

    def test_target_group_authorization_fails_before_download(self):
        job = self.submit(access_group_id="unauthorized"); self.source.run_once("local")
        result = self.store.get(job["job_id"])
        self.assertEqual(result["state"], "rejected")
        self.assertEqual(result["steps"][2]["status"], "pending")
        self.assertEqual(self.runtime.read()["groups"], {})

    def test_revocation_after_publication_stops_install(self):
        job = self.submit(); self.source.run_once("local")
        release_id = self.store.get(job["job_id"])["release_id"]
        self.source.revoke(release_id)
        Delivery(self.client, self.source, self.runtime, self.root / "agent", "local").run_once()
        self.assertEqual(self.store.get(job["job_id"])["state"], "failed")
        self.assertEqual(self.runtime.read()["models"], {})

    def test_lost_install_response_recovers_from_persisted_model_provenance(self):
        job = self.submit(); self.source.run_once("local")
        class LostCreateResponse(FixtureRuntime):
            def install(self, *args):
                super().install(*args)
                raise GovernanceError("upstream_unavailable")
        Delivery(self.client, self.source, LostCreateResponse(self.root / "runtime.json"), self.root / "agent", "local").run_once()
        self.assertEqual(self.store.get(job["job_id"])["state"], "failed")
        self.store.retry(job["job_id"])
        Delivery(self.client, self.source, self.runtime, self.root / "agent", "local").run_once()
        self.assertEqual(self.store.get(job["job_id"])["state"], "ready")
        self.assertEqual(len(self.runtime.read()["models"]), 1)


if __name__ == "__main__": unittest.main()
