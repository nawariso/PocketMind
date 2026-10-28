"""SQLite job journal. Lease secrets are never included in public status."""
from __future__ import annotations

import json
import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from .contracts import GovernanceError, canonical, demand, identifier, require

STEPS = ("preflight", "resolve", "download", "scan", "policy", "publish", "transfer",
         "verify", "install", "smoke_test", "register", "grant_access")


class JobStore:
    def __init__(self, path):
        self.path = str(path)
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self.connection() as conn:
            conn.execute("""CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY, idem TEXT UNIQUE NOT NULL, demand TEXT NOT NULL,
                target TEXT NOT NULL, alias TEXT NOT NULL, state TEXT NOT NULL,
                data TEXT NOT NULL, lease TEXT, expires REAL NOT NULL DEFAULT 0,
                UNIQUE(target, alias))""")

    @contextmanager
    def connection(self):
        conn = sqlite3.connect(self.path, timeout=10)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("BEGIN IMMEDIATE")
            yield conn
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
        finally:
            conn.close()

    @staticmethod
    def row(conn, job_id):
        row = conn.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        require(row is not None, "job_not_found")
        return row

    @staticmethod
    def save(conn, job, **extra):
        conn.execute("UPDATE jobs SET data=?,state=? WHERE id=?", (canonical(job), job["state"], job["job_id"]))
        if extra:
            # Column names are internal constants, never request input.
            require(set(extra) <= {"lease", "expires"})
            conn.execute("UPDATE jobs SET " + ",".join(f"{k}=?" for k in extra) + " WHERE id=?", (*extra.values(), job["job_id"]))

    def submit(self, value, key):
        value = demand(value)
        require(isinstance(key, str) and 1 <= len(key) <= 128 and key.isascii() and key.isprintable(), "invalid_idempotency_key")
        encoded = canonical(value)
        with self.connection() as conn:
            prior = conn.execute("SELECT * FROM jobs WHERE idem=?", (key,)).fetchone()
            if prior:
                require(prior["demand"] == encoded, "idempotency_conflict")
                return json.loads(prior["data"])
            job = {"schema_version": 1, "job_id": str(uuid.uuid4()), "request": value,
                   "state": "requested", "attempt": 0, "release_id": None,
                   "created_at": time.time(), "updated_at": time.time(), "history": [],
                   "retry_count": 0, "next_retry_at": None,
                   "steps": [{"name": name, "status": "pending", "attempts": 0,
                              "started_at": None, "finished_at": None, "error": None,
                              "bytes": None, "total_bytes": None} for name in STEPS]}
            try:
                conn.execute("INSERT INTO jobs(id,idem,demand,target,alias,state,data) VALUES(?,?,?,?,?,?,?)",
                             (job["job_id"], key, encoded, value["target_id"], value["alias"], "requested", canonical(job)))
            except sqlite3.IntegrityError:
                raise GovernanceError("alias_reserved") from None
            return job

    def get(self, job_id):
        with self.connection() as conn:
            return json.loads(self.row(conn, job_id)["data"])

    def list(self):
        with self.connection() as conn:
            return [json.loads(row["data"]) for row in conn.execute("SELECT data FROM jobs ORDER BY rowid DESC LIMIT 100")]

    def permits_release(self, target, release_id):
        with self.connection() as conn:
            rows = conn.execute("SELECT data FROM jobs WHERE target=?", (target,))
            return any(json.loads(row["data"]).get("release_id") == release_id for row in rows)

    def claim(self, target, *, now=None, ttl=60, phase=None):
        now = time.time() if now is None else now
        require(identifier(target), "invalid_target")
        with self.connection() as conn:
            # Requeue only known transient failures after bounded backoff; never requeue rejection/review.
            for failed_row in conn.execute("SELECT * FROM jobs WHERE target=? AND state='failed'", (target,)).fetchall():
                failed = json.loads(failed_row["data"])
                due = failed.get("next_retry_at")
                if due is not None and due <= now:
                    self.reset_retry(failed)
                    self.save(conn, failed, lease=None, expires=0)
            rows = conn.execute("SELECT * FROM jobs WHERE target=? AND (state='requested' OR (state='running' AND expires<=?)) ORDER BY rowid", (target, now)).fetchall()
            row = next((r for r in rows if phase is None or
                        (json.loads(r["data"])["steps"][5]["status"] == "succeeded") == (phase == "delivery")), None)
            if not row:
                return None
            job = json.loads(row["data"])
            job.update(state="running", attempt=job["attempt"] + 1, updated_at=now)
            token = secrets.token_urlsafe(32)
            self.save(conn, job, lease=token, expires=now + ttl)
            return dict(job, lease=token)

    def handoff(self, job_id, token):
        with self.connection() as conn:
            job = self.owned(conn, job_id, token, time.time())
            require(all(s["status"] == "succeeded" for s in job["steps"][:6]) and job["release_id"], "release_not_ready")
            job.update(state="requested", updated_at=time.time())
            self.save(conn, job, lease=None, expires=0)

    def owned(self, conn, job_id, token, now):
        row = self.row(conn, job_id)
        require(row["state"] == "running" and row["lease"] is not None
                and isinstance(token, str) and secrets.compare_digest(row["lease"], token)
                and row["expires"] > now, "stale_or_cancelled_lease")
        return json.loads(row["data"])

    def heartbeat(self, job_id, token, *, now=None, ttl=60):
        now = time.time() if now is None else now
        with self.connection() as conn:
            job = self.owned(conn, job_id, token, now)
            self.save(conn, job, expires=now + ttl)

    def step(self, job_id, token, name, status, *, error=None, release_id=None, progress=None, now=None):
        now = time.time() if now is None else now
        require(name in STEPS and status in {"running", "succeeded", "failed", "blocked"}, "invalid_step")
        require(error is None or (isinstance(error, str) and error.replace("_", "").isalnum() and len(error) <= 80), "invalid_error")
        with self.connection() as conn:
            job = self.owned(conn, job_id, token, now)
            index = STEPS.index(name)
            require(all(s["status"] == "succeeded" for s in job["steps"][:index]), "step_out_of_order")
            step = job["steps"][index]
            if status == "running" and step["status"] != "running":
                step.update(started_at=now, attempts=step["attempts"] + 1)
            step.update(status=status, error=error)
            if status in {"succeeded", "failed", "blocked"}: step["finished_at"] = now
            if progress is not None:
                done, total = progress
                require(type(done) is int and done >= 0 and (total is None or (type(total) is int and total >= done)), "invalid_progress")
                step.update(bytes=done, total_bytes=total)
            if release_id is not None:
                require(identifier(release_id), "invalid_release")
                job["release_id"] = release_id
            job["updated_at"] = now
            self.save(conn, job)

    def finish(self, job_id, token, state):
        require(state in {"ready", "failed", "rejected", "awaiting_approval"}, "invalid_state")
        with self.connection() as conn:
            job = self.owned(conn, job_id, token, time.time())
            require(state != "ready" or all(s["status"] == "succeeded" for s in job["steps"]), "not_ready")
            job.update(state=state, updated_at=time.time())
            errors = [{"step": s["name"], "code": s["error"]} for s in job["steps"] if s["error"]]
            job["history"].append({"attempt": job["attempt"], "state": state, "at": time.time(), "errors": errors})
            transient = {"upstream_unavailable", "upstream_408", "upstream_429", "upstream_500", "upstream_502", "upstream_503", "upstream_504", "grant_unavailable"}
            if state == "failed" and errors and errors[-1]["code"] in transient and job.get("retry_count", 0) < 3:
                job["next_retry_at"] = time.time() + 2 ** (job.get("retry_count", 0) + 1)
            self.save(conn, job, lease=None, expires=0)

    @staticmethod
    def reset_retry(job):
        require(job.get("retry_count", 0) < 3, "retry_limit")
        for step in job["steps"]:
            if step["status"] != "succeeded":
                step.update(status="pending", error=None, finished_at=None)
        job.update(state="requested", updated_at=time.time(), next_retry_at=None, retry_count=job.get("retry_count", 0) + 1)

    def retry(self, job_id):
        with self.connection() as conn:
            job = json.loads(self.row(conn, job_id)["data"])
            require(job["state"] == "failed", "not_retryable")
            self.reset_retry(job)
            self.save(conn, job, lease=None, expires=0)
            return job

    def cancel(self, job_id):
        with self.connection() as conn:
            job = json.loads(self.row(conn, job_id)["data"])
            require(job["state"] not in {"ready", "cancelled"}, "not_cancellable")
            job.update(state="cancelled", updated_at=time.time(), next_retry_at=None)
            job["history"].append({"attempt": job["attempt"], "state": "cancelled", "at": time.time()})
            self.save(conn, job, lease=None, expires=0)
            return job
