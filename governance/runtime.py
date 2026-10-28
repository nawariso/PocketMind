"""Local management adapter. No registry pulls, Docker socket or shell commands."""
import hashlib
import re
from pathlib import Path
from urllib.parse import quote

from .contracts import GovernanceError, canonical, physical_model_name, require
from .http import optional_get


class OllamaRuntime:
    def __init__(self, ollama, litellm, webui):
        self.ollama, self.litellm, self.webui = ollama, litellm, webui

    def preflight(self, value, alias, group):
        require(value.get("fixture") is not True, "fixture_not_installable")
        version = self.ollama.json("GET", "/api/version")
        require(version.get("version") == value["runtime"]["version"], "unqualified_runtime_version")
        found = self.webui.json("GET", "/api/v1/groups/id/" + quote(group, safe=""))
        require(found.get("id") == group, "group_not_found")
        self._route(alias, value)
        entry = optional_get(self.webui, "/api/v1/models/model?id=" + quote(alias, safe=""))
        if entry: self._workspace(entry, value, group)

    def install(self, name, value, path):
        models = self.ollama.json("GET", "/api/tags")["models"]
        weight = next(f for f in value["files"] if f["role"] == "weights")
        marker = "PocketMind approved manifest SHA256: " + hashlib.sha256(canonical(value).encode()).hexdigest()
        if any(m.get("name", "").removesuffix(":latest") == name for m in models):
            shown = self.ollama.json("POST", "/api/show", {"model": name})
            sources = re.findall(r'^FROM\s+(.+)$', shown.get("modelfile", ""), re.MULTILINE)
            require(marker in shown.get("license", "").splitlines() and len(sources) == 1 and
                    sources[0].strip().strip('"').replace("\\", "/").split("/")[-1] == "sha256-" + weight["sha256"], "model_conflict")
            return  # Reconcile a completed create whose response/receipt was lost; never overwrite.
        digest = "sha256:" + weight["sha256"]
        try:
            self.ollama.json("HEAD", "/api/blobs/" + digest)
        except GovernanceError as exc:
            if exc.code != "upstream_404": raise
            with (Path(path) / weight["path"]).open("rb") as data:
                with self.ollama.open("POST", "/api/blobs/" + digest, data,
                                      {"Content-Type": "application/octet-stream", "Content-Length": str(weight["size"])}) as response:
                    response.read(1024)
        licenses = [(Path(path) / f["path"]).read_text("utf-8") for f in value["files"] if f["role"] == "license"]
        licenses.append(marker)
        body = {"model": name, "files": {weight["path"]: digest}, "stream": False,
                "license": licenses, **value.get("metadata", {})}
        result = self.ollama.json("POST", "/api/create", body)
        require(result.get("status") == "success", "model_create_failed")

    def smoke(self, name):
        result = self.ollama.json("POST", "/api/chat", {"model": name, "messages": [{"role": "user", "content": "Reply briefly: ready"}],
                                                      "stream": False, "options": {"num_predict": 16}})
        require(bool(result.get("message", {}).get("content")) and result.get("done") is True, "smoke_test_failed")

    def _route(self, alias, value):
        routes = self.litellm.json("GET", "/model/info").get("data", [])
        matches = [r for r in routes if r.get("model_name") == alias]
        if matches:
            require(len(matches) == 1 and matches[0].get("model_info", {}).get("pocketmind_release_id") == value["release_id"], "alias_conflict")
            params = matches[0].get("litellm_params", {})
            require(params.get("model") == "ollama_chat/" + physical_model_name(value["release_id"], alias)
                    and params.get("api_base") in {"os.environ/OLLAMA_API_BASE", "http://ollama:11434"}, "alias_conflict")
            return matches[0]
        return None

    def register(self, alias, name, value):
        old = self._route(alias, value)
        if old:
            require(old["litellm_params"]["model"] == "ollama_chat/" + name, "alias_conflict")
            return
        self.litellm.json("POST", "/model/new", {"model_name": alias,
            "litellm_params": {"model": "ollama_chat/" + name, "api_base": "os.environ/OLLAMA_API_BASE"},
            "model_info": {"db_model": True, "pocketmind_release_id": value["release_id"]}})
        self._route(alias, value)
        catalog = self.litellm.json("GET", "/v1/models")
        require(alias in [m.get("id") for m in catalog.get("data", [])], "alias_not_verified")

    @staticmethod
    def _workspace(entry, value, group):
        require(entry.get("meta", {}).get("pocketmind_release_id") == value["release_id"], "workspace_conflict")
        expected = [{"principal_type": "group", "principal_id": group, "permission": "read"}]
        grants = [{k: grant.get(k) for k in expected[0]} for grant in entry.get("access_grants", [])]
        require(grants == expected and entry.get("is_active") is True, "workspace_grant_conflict")

    def grant(self, alias, group, value):
        old = optional_get(self.webui, "/api/v1/models/model?id=" + quote(alias, safe=""))
        if old:
            self._workspace(old, value, group)
            return
        self.webui.json("POST", "/api/v1/models/create", {"id": alias, "name": alias, "base_model_id": None,
            "meta": {"pocketmind_release_id": value["release_id"], "capabilities": {"vision": False, "builtin_tools": False}},
            "params": {}, "is_active": True,
            "access_grants": [{"principal_type": "group", "principal_id": group, "permission": "read"}]})

    def verify(self, alias, group, value):
        require(self._route(alias, value) is not None, "alias_not_verified")
        entry = self.webui.json("GET", "/api/v1/models/model?id=" + quote(alias, safe=""))
        require(entry.get("id") == alias and entry.get("base_model_id") is None, "workspace_conflict")
        self._workspace(entry, value, group)
