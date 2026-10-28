"""Strict runtime contracts shared by management clients and coordinator."""
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import unicodedata
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit


class GovernanceError(Exception):
    """Public, sanitized failure code. Never wrap provider error bodies in this."""
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def require(condition, code="invalid_contract"):
    if not condition:
        raise GovernanceError(code)


def text(value, maximum=256):
    return isinstance(value, str) and 0 < len(value) <= maximum and not any(ord(c) < 32 for c in value)


def identifier(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,95}", value) is not None


def alias(value):
    require(text(value, 128) and value[0].isalnum() and all(unicodedata.category(c)[0] in {"L", "M", "N"} or c in "._:/-" for c in value), "invalid_alias")
    require(value.casefold() not in {"default-general", "default-ocr"}, "protected_alias")
    return value


def safe_path(value):
    require(text(value) and "\\" not in value and ":" not in value, "unsafe_path")
    parts = value.split("/")
    require(not PurePosixPath(value).is_absolute() and all(p not in {"", ".", ".."} for p in parts), "unsafe_path")
    for part in parts:
        require(part == part.rstrip(" .") and re.fullmatch(r"[^<>\"|?*]+", part), "unsafe_path")
        require(part.split(".")[0].upper() not in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}, "unsafe_path")
    return value


def normalize_model(source, value):
    require(text(value), "invalid_model")
    if "://" in value:
        parsed = urlsplit(value)
        require(parsed.scheme == "https" and not parsed.username and not parsed.password and not parsed.port
                and not parsed.query and not parsed.fragment, "invalid_model_link")
        require(parsed.netloc == ({"huggingface": "huggingface.co", "ollama": "ollama.com"}.get(source)), "invalid_model_link")
        value = parsed.path.strip("/")
        if source == "ollama" and value.startswith("library/"):
            value = value[8:]
    pattern = r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*" if source == "huggingface" else r"[A-Za-z0-9][A-Za-z0-9_./-]*(?::[A-Za-z0-9][A-Za-z0-9_.-]*)?"
    require(re.fullmatch(pattern, value) is not None and ".." not in value and "//" not in value, "invalid_model")
    return value


def demand(value):
    require(isinstance(value, dict), "invalid_request")
    fields = {"source", "model_id", "revision", "artifact", "alias", "target_id", "access_group_id", "purpose"}
    require(set(value) == fields, "invalid_request_fields")
    result = dict(value)
    require(result["source"] in {"huggingface", "ollama"}, "unsupported_source")
    result["model_id"] = normalize_model(result["source"], result["model_id"])
    alias(result["alias"])
    require(identifier(result["target_id"]) and identifier(result["access_group_id"]), "invalid_target_or_group")
    require(text(result["purpose"], 1000) and text(result["revision"]), "invalid_request")
    safe_path(result["artifact"])
    require(result["artifact"].endswith(".gguf"), "unsupported_format")
    return result


def manifest(value):
    require(isinstance(value, dict) and type(value.get("schema_version")) is int and value["schema_version"] == 1, "unsupported_schema")
    require(identifier(value.get("release_id")) and value.get("status") == "approved", "release_not_approved")
    source = value.get("source", {})
    require(source.get("provider") in {"huggingface", "ollama"}, "unsupported_source")
    normalize_model(source["provider"], source.get("model_id"))
    if source["provider"] == "huggingface":
        require(isinstance(source.get("revision"), str) and re.fullmatch(r"[a-f0-9]{40}", source["revision"]), "unresolved_revision")
    else:
        digests = [source.get("revision"), *source.get("blob_digests", [])]
        require(len(digests) > 1 and all(isinstance(d, str) and re.fullmatch(r"sha256:[a-f0-9]{64}", d) for d in digests), "unresolved_revision")
    require(text(value.get("license")), "missing_license")
    runtime = value.get("runtime", {})
    require(runtime.get("name") == "ollama" and isinstance(runtime.get("version"), str)
            and re.fullmatch(r"\d+\.\d+\.\d+", runtime["version"]), "unsupported_runtime")
    files = value.get("files")
    require(isinstance(files, list) and 2 <= len(files) <= 100, "invalid_files")
    paths = []
    for file in files:
        require(isinstance(file, dict) and set(file) == {"path", "size", "sha256", "role"}, "invalid_file")
        paths.append(safe_path(file["path"]))
        require(type(file["size"]) is int and file["size"] > 0 and isinstance(file["sha256"], str)
                and re.fullmatch(r"[a-f0-9]{64}", file["sha256"]), "invalid_file")
        require(file["role"] in {"weights", "license"}, "unsupported_file")
    require(len({p.casefold() for p in paths}) == len(paths), "duplicate_file")
    weights = [f for f in files if f["role"] == "weights"]
    require(len(weights) == 1 and weights[0]["path"].endswith(".gguf") and any(f["role"] == "license" for f in files), "unsupported_bundle")
    if source["provider"] == "ollama":
        require("sha256:" + weights[0]["sha256"] in source["blob_digests"], "missing_weight_provenance")
    scans = value.get("scans")
    require(isinstance(scans, list) and bool(scans), "missing_scan")
    covered = set()
    for scan in scans:
        require(scan.get("status") == "passed" and text(scan.get("tool")) and text(scan.get("version"))
                and scan.get("format") == "gguf" and isinstance(scan.get("covered_files"), list), "incomplete_scan")
        covered.update(scan["covered_files"])
    require(covered == set(paths), "incomplete_scan")
    approval = value.get("approval", {})
    require(approval.get("mode") in {"policy", "review"} and text(approval.get("identity"))
            and text(approval.get("policy_version")) and text(approval.get("approved_at")), "missing_approval")
    if approval["mode"] == "review":
        require(text(approval.get("requester")) and approval["requester"] != approval["identity"], "self_approval")
    evaluation = value.get("evaluation", {})
    require(evaluation.get("status") == "passed" and text(evaluation.get("evidence_id")), "missing_evaluation")
    metadata = value.get("metadata", {})
    require(isinstance(metadata, dict) and set(metadata) <= {"template", "system", "parameters"}, "unsafe_metadata")
    for key in ("template", "system"):
        if key in metadata:
            require(isinstance(metadata[key], str) and len(metadata[key]) <= 32768, "unsafe_metadata")
    parameters = metadata.get("parameters", {})
    require(isinstance(parameters, dict) and set(parameters) <= {"temperature", "top_p", "top_k", "num_ctx", "repeat_penalty", "stop"}, "unsafe_parameters")
    for key, val in parameters.items():
        if key == "stop":
            require(isinstance(val, list) and len(val) <= 16 and all(text(s) for s in val), "unsafe_parameters")
        else:
            require(type(val) in {int, float} and 0 <= val <= (1048576 if key == "num_ctx" else 1000), "unsafe_parameters")
    return value


def digest(path):
    with Path(path).open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def verify_bundle(value, root):
    manifest(value)
    root = Path(root)
    require(root.is_dir() and not root.is_symlink() and not getattr(root, "is_junction", lambda: False)(), "unsafe_bundle")
    expected = {f["path"]: f for f in value["files"]}
    found = set()
    for path in root.rglob("*"):
        info = path.lstat()
        require(not path.is_symlink() and not getattr(path, "is_junction", lambda: False)() and not (getattr(info, "st_file_attributes", 0) & 0x400), "unsafe_bundle")
        if path.is_dir():
            continue
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "unsafe_bundle")
        relative = path.relative_to(root).as_posix()
        require(relative in expected, "unlisted_file")
        wanted = expected[relative]
        require(info.st_size == wanted["size"] and digest(path) == wanted["sha256"], "artifact_mismatch")
        found.add(relative)
    require(found == set(expected), "missing_file")
    return value


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def physical_model_name(release_id, alias):
    return "pm-" + hashlib.sha256((release_id + ":" + alias).encode()).hexdigest()[:32]
