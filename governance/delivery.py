"""Unattended delivery and deliberately synthetic acquisition/runtime adapters."""
from __future__ import annotations

import hashlib
import json
import shutil
import threading
from pathlib import Path

from .contracts import GovernanceError, canonical, digest, manifest, require, verify_bundle
from .files import atomic_json, file_lock, private_dir
from .importer import Importer


class LocalClient:
    def __init__(self, store): self.store = store
    def claim(self, target): return self.store.claim(target, phase="delivery")
    def heartbeat(self, job, lease): self.store.heartbeat(job, lease)
    def step(self, job, lease, name, status, **extra): self.store.step(job, lease, name, status, **extra)
    def finish(self, job, lease, state): self.store.finish(job, lease, state)


class RemoteClient:
    def __init__(self, api): self.api = api
    def claim(self, target): return self.api.json("POST", "/agent/claim", {"target_id": target}).get("job")
    def heartbeat(self, job, lease): self.api.json("POST", f"/agent/jobs/{job}/heartbeat", {"lease": lease})
    def step(self, job, lease, name, status, **extra): self.api.json("POST", f"/agent/jobs/{job}/step", dict(extra, lease=lease, name=name, status=status))
    def finish(self, job, lease, state): self.api.json("POST", f"/agent/jobs/{job}/finish", {"lease": lease, "state": state})


class Delivery:
    def __init__(self, client, authority, runtime, state, target):
        self.client, self.authority, self.runtime = client, authority, runtime
        self.state, self.target = private_dir(state), target

    def run_once(self):
        # All agents for one target must share this host-managed state directory.
        with file_lock(self.state / "delivery.lock"):
            job = self.client.claim(self.target)
            if not job: return False
            require(job["request"]["target_id"] == self.target, "target_mismatch")
            job_id, lease = job["job_id"], job["lease"]
            stopped = threading.Event(); lease_failed = threading.Event()
            current = ["transfer"]

            def heartbeat():
                while not stopped.wait(10):
                    try: self.client.heartbeat(job_id, lease)
                    except Exception:
                        lease_failed.set(); return

            thread = threading.Thread(target=heartbeat, daemon=True); thread.start()
            def report(name, status, **extra):
                require(not lease_failed.is_set(), "lease_lost")
                self.client.heartbeat(job_id, lease)
                current[0] = name
                self.client.step(job_id, lease, name, status, **extra)
            try:
                value = self.authority.manifest(job["release_id"])
                # Re-check current runtime/group and space before any internal transfer.
                self.runtime.preflight(value, job["request"]["alias"], job["request"]["access_group_id"])
                size = sum(f["size"] for f in value["files"])
                require(shutil.disk_usage(self.state).free >= size * 3 + 16 * 1024 * 1024, "insufficient_disk")
                report("transfer", "running")
                bundle = private_dir(self.state / value["release_id"])
                self.authority.download(value, bundle, lambda done, total: report("transfer", "running", progress=(done, total)))
                # A failed transfer leaves .partial files only. Fully completed transfers are validated before use.
                verify_bundle(value, bundle)
                report("transfer", "succeeded")
                importer = Importer(self.state / "receipts", self.authority, self.runtime)
                importer.run(value, bundle, job["request"]["alias"], job["request"]["access_group_id"], report=report)
                self.client.finish(job_id, lease, "ready")
            except Exception as exc:
                code = exc.code if isinstance(exc, GovernanceError) else "delivery_failed"
                try:
                    report(current[0], "failed", error=code)
                    self.client.finish(job_id, lease, "failed")
                except Exception:
                    pass  # Cancelled/stale workers cannot change the new owner's state.
            finally:
                stopped.set(); thread.join(timeout=1)
            return True


class FixtureAcquisition:
    """No Internet downloads or security claims. Only these two fixed synthetic models exist."""
    MODELS = {"huggingface": "pocketmind-fixtures/tiny-gguf", "ollama": "pocketmind-fixture:tiny"}
    WEIGHTS = b"GGUF\x00PocketMind synthetic governance fixture - NOT A USABLE MODEL\n"
    LICENSE = b"Synthetic test fixture. No external model weights.\n"

    def __init__(self, store, root, targets):
        self.store, self.root, self.targets = store, private_dir(root), targets

    def run_once(self, target):
        job = self.store.claim(target, phase="acquisition")
        if not job: return False
        job_id, lease = job["job_id"], job["lease"]
        current = "preflight"
        try:
            request = job["request"]
            for step in ("preflight", "resolve", "download", "scan", "policy", "publish"):
                current = step
                self.store.step(job_id, lease, step, "running")
                if step == "preflight":
                    require(request["target_id"] in self.targets and request["access_group_id"] in self.targets[request["target_id"]], "target_group_denied")
                    require(request["model_id"] == self.MODELS[request["source"]] and request["artifact"] == "model.gguf", "fixture_model_not_available")
                    require(request["revision"] in {"main", "latest", "review-required", "scan-error"}, "fixture_revision_not_available")
                if step == "scan":
                    require(request["revision"] != "scan-error", "mandatory_scan_failed")
                if step == "policy" and request["revision"] == "review-required":
                    self.store.step(job_id, lease, step, "blocked", error="policy_exception_review_required")
                    self.store.finish(job_id, lease, "awaiting_approval")
                    return True
                if step == "publish":
                    # Release identity is immutable and independent of alias/group/target.
                    release_id = "fixture-" + hashlib.sha256(canonical({k: request[k] for k in ("source", "model_id", "revision", "artifact")}).encode()).hexdigest()[:32]
                    path = private_dir(self.root / release_id)
                    if not (path / "manifest.json").exists():
                        bundle = private_dir(path / "bundle")
                        (bundle / "model.gguf").write_bytes(self.WEIGHTS)
                        (bundle / "LICENSE").write_bytes(self.LICENSE)
                        files = [{"path": name, "size": (bundle / name).stat().st_size, "sha256": digest(bundle / name), "role": role}
                                 for name, role in [("model.gguf", "weights"), ("LICENSE", "license")]]
                        source = {"provider": request["source"], "model_id": request["model_id"],
                                  "revision": hashlib.sha1(self.WEIGHTS).hexdigest()}
                        if request["source"] == "ollama":
                            source.update(revision="sha256:" + "0" * 64, blob_digests=["sha256:" + files[0]["sha256"]])
                        value = {"schema_version": 1, "release_id": release_id, "status": "approved", "fixture": True,
                                 "source": source, "license": "Synthetic-fixture", "files": files,
                                 "runtime": {"name": "ollama", "version": "0.32.6"}, "metadata": {},
                                 "scans": [{"tool": "SYNTHETIC-NOT-A-SCANNER", "version": "1", "format": "gguf", "status": "passed", "covered_files": ["model.gguf", "LICENSE"]}],
                                 "evaluation": {"status": "passed", "evidence_id": "SYNTHETIC-NOT-A-MODEL-EVALUATION"},
                                 "approval": {"mode": "policy", "identity": "fixture-authority", "policy_version": "fixture-policy-v1", "approved_at": "2026-10-28T00:00:00Z"}}
                        atomic_json(path / "manifest.json", value)
                    self.manifest(release_id)  # Never un-revoke a reused release.
                    self.store.step(job_id, lease, step, "succeeded", release_id=release_id)
                else:
                    progress = (len(self.WEIGHTS), len(self.WEIGHTS)) if step == "download" else None
                    self.store.step(job_id, lease, step, "succeeded", progress=progress)
            self.store.handoff(job_id, lease)
        except Exception as exc:
            code = exc.code if isinstance(exc, GovernanceError) else "acquisition_failed"
            self.store.step(job_id, lease, current, "failed", error=code)
            self.store.finish(job_id, lease, "rejected" if code in {"target_group_denied", "fixture_model_not_available", "fixture_revision_not_available", "mandatory_scan_failed"} else "failed")
        return True

    def manifest(self, release_id):
        from .contracts import identifier
        require(identifier(release_id), "invalid_release")
        path = self.root / release_id / "manifest.json"
        require(path.is_file(), "release_not_found")
        return manifest(json.loads(path.read_text("utf-8")))

    def download(self, value, destination, report=None):
        self.manifest(value["release_id"])
        for file in value["files"]:
            shutil.copyfile(self.root / value["release_id"] / "bundle" / file["path"], Path(destination) / file["path"])
            if report: report(file["size"], file["size"])

    def revoke(self, release_id):
        value = self.manifest(release_id); value["status"] = "revoked"
        atomic_json(self.root / release_id / "manifest.json", value)


class FixtureRuntime:
    """Records synthetic installation in a private JSON file; never calls a serving API."""
    def __init__(self, path):
        self.path = Path(path); private_dir(self.path.parent)
        if not self.path.exists(): atomic_json(self.path, {"models": {}, "aliases": {}, "groups": {}})
    def read(self): return json.loads(self.path.read_text("utf-8"))
    def preflight(self, value, alias, group):
        require(value.get("fixture") is True, "fixture_runtime_only")
        data = self.read()
        if alias in data["aliases"]:
            require(data["aliases"][alias]["release_id"] == value["release_id"], "alias_conflict")
    def install(self, name, value, path):
        data = self.read()
        if name in data["models"]:
            require(data["models"][name] == value["release_id"], "model_conflict")
            return
        data["models"][name] = value["release_id"]; atomic_json(self.path, data)
    def smoke(self, name): require(name in self.read()["models"], "smoke_failed")
    def register(self, alias, name, value):
        data = self.read(); data["aliases"][alias] = {"physical_name": name, "release_id": value["release_id"]}; atomic_json(self.path, data)
    def grant(self, alias, group, value):
        data = self.read(); data["groups"][alias] = group; atomic_json(self.path, data)
    def verify(self, alias, group, value):
        data = self.read()
        require(data["groups"].get(alias) == group and data["aliases"].get(alias, {}).get("release_id") == value["release_id"], "grant_not_verified")
