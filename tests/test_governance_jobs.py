"""Durable jobs must survive retries/restarts without giving stale workers authority."""
import tempfile
import unittest
from pathlib import Path

from governance.contracts import GovernanceError
from governance.jobs import JobStore, STEPS
from test_governance_contracts import request


class JobTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.path = Path(self.tmp.name) / "jobs.db"
        self.store = JobStore(self.path)
    def tearDown(self): self.tmp.cleanup()

    def test_idempotency_persists_and_rejects_different_demand(self):
        one = self.store.submit(request(), "key-1")
        two = JobStore(self.path).submit(request(), "key-1")
        self.assertEqual(one["job_id"], two["job_id"])
        with self.assertRaises(GovernanceError): self.store.submit(request(alias="other"), "key-1")
        self.assertEqual([s["name"] for s in one["steps"]], list(STEPS))

    def test_expired_lease_is_reclaimed_and_stale_worker_is_fenced(self):
        job = self.store.submit(request(), "key-1")
        a = self.store.claim("local", now=100, ttl=10)
        self.assertIsNone(self.store.claim("local", now=105))
        b = self.store.claim("local", now=111)
        self.assertEqual(a["job_id"], b["job_id"])
        self.assertNotEqual(a["lease"], b["lease"])
        with self.assertRaises(GovernanceError): self.store.step(job["job_id"], a["lease"], "preflight", "succeeded", now=112)
        self.store.step(job["job_id"], b["lease"], "preflight", "succeeded", now=112)
        self.assertEqual(self.store.get(job["job_id"])["steps"][0]["status"], "succeeded")
        self.assertNotIn("lease", self.store.get(job["job_id"]))

    def test_ready_requires_all_steps_and_retry_preserves_completed_steps(self):
        job = self.store.submit(request(), "key-1"); claim = self.store.claim("local")
        with self.assertRaises(GovernanceError): self.store.finish(job["job_id"], claim["lease"], "ready")
        self.store.step(job["job_id"], claim["lease"], "preflight", "succeeded")
        self.store.step(job["job_id"], claim["lease"], "resolve", "failed", error="provider_unavailable")
        self.store.finish(job["job_id"], claim["lease"], "failed")
        self.store.retry(job["job_id"])
        again = self.store.claim("local")
        self.assertEqual(again["steps"][0]["status"], "succeeded")
        self.assertEqual(again["steps"][1]["status"], "pending")
        self.assertEqual(again["attempt"], 2)

    def test_cancelled_job_cannot_be_claimed_or_finish_ready(self):
        job = self.store.submit(request(), "key-1"); claim = self.store.claim("local")
        self.store.cancel(job["job_id"])
        with self.assertRaises(GovernanceError): self.store.step(job["job_id"], claim["lease"], "install", "succeeded")
        self.assertIsNone(self.store.claim("local"))
        self.assertEqual(self.store.get(job["job_id"])["state"], "cancelled")

    def test_target_and_alias_conflicts_cannot_create_duplicate_deliveries(self):
        self.store.submit(request(), "key-1")
        with self.assertRaises(GovernanceError): self.store.submit(request(), "key-2")
        self.assertIsNone(self.store.claim("different-target"))

    def test_transient_failure_schedules_bounded_retry_without_admin_click(self):
        job = self.store.submit(request(), "key-1")
        lease = self.store.claim("local")["lease"]
        self.store.step(job["job_id"], lease, "preflight", "failed", error="upstream_unavailable")
        self.store.finish(job["job_id"], lease, "failed")
        failed = self.store.get(job["job_id"])
        self.assertIsNotNone(failed["next_retry_at"])
        self.assertIsNone(self.store.claim("local", now=failed["next_retry_at"] - 1))
        retried = self.store.claim("local", now=failed["next_retry_at"] + 1)
        self.assertEqual(retried["steps"][0]["status"], "pending")
        self.assertEqual(retried["retry_count"], 1)
        self.assertEqual(retried["history"][0]["errors"], [{"step": "preflight", "code": "upstream_unavailable"}])


if __name__ == "__main__": unittest.main()
