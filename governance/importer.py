"""An approved manifest is independently checked before every local import."""
import hashlib
import json
import time
from pathlib import Path

from .contracts import GovernanceError, alias as validate_alias, canonical, identifier, manifest, physical_model_name, require, verify_bundle
from .files import atomic_json, file_lock, private_dir, stage_bundle


class Importer:
    def __init__(self, state, authority, runtime):
        self.state = private_dir(state)
        self.authority = authority
        self.runtime = runtime

    def approved(self, value):
        manifest(value)
        trusted = manifest(self.authority.manifest(value["release_id"]))
        require(canonical(trusted) == canonical(value), "approval_manifest_mismatch")

    def run(self, value, bundle, alias, group, *, check_only=False, report=None):
        validate_alias(alias)
        require(identifier(group), "invalid_group")
        self.approved(value)
        verify_bundle(value, bundle)
        self.runtime.preflight(value, alias, group)
        if check_only:
            return {"state": "validated", "release_id": value["release_id"]}
        key = hashlib.sha256(alias.encode()).hexdigest()
        with file_lock(self.state / (key + ".lock")):
            path = self.state / (key + ".json")
            identity = {"release_id": value["release_id"], "alias": alias, "access_group_id": group,
                        "manifest_sha256": hashlib.sha256(canonical(value).encode()).hexdigest(),
                        "physical_name": physical_model_name(value["release_id"], alias)}
            receipt = json.loads(path.read_text("utf-8")) if path.exists() else dict(
                identity, schema_version=1, state="pending", completed=[], created_at=time.time())
            require(all(receipt.get(k) == v for k, v in identity.items()), "receipt_conflict")
            atomic_json(path, receipt)  # Fail before side effects if receipts cannot be persisted.
            with stage_bundle(value, bundle, self.state) as staged:
                actions = {
                    "verify": lambda: self.approved(value),
                    "install": lambda: self.runtime.install(receipt["physical_name"], value, staged),
                    "smoke_test": lambda: self.runtime.smoke(receipt["physical_name"]),
                    "register": lambda: self.runtime.register(alias, receipt["physical_name"], value),
                    "grant_access": lambda: (self.runtime.grant(alias, group, value), self.runtime.verify(alias, group, value)),
                }
                try:
                    for name, action in actions.items():
                        if report: report(name, "running")  # Lease/cancellation gate before each side effect.
                        # A previously ready receipt must still verify actual access and current approval.
                        if name not in receipt["completed"] or name in {"verify", "install", "smoke_test", "grant_access"}:
                            action()
                        if name not in receipt["completed"]: receipt["completed"].append(name)
                        receipt.update(updated_at=time.time(), state="pending", error=None)
                        atomic_json(path, receipt)
                        if report: report(name, "succeeded")
                    receipt.update(state="ready", updated_at=time.time())
                    atomic_json(path, receipt)
                    return receipt
                except Exception as exc:
                    receipt.update(state="failed", error=exc.code if isinstance(exc, GovernanceError) else "import_failed", updated_at=time.time())
                    atomic_json(path, receipt)
                    raise
