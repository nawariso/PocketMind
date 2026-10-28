"""Bounded authenticated internal API client. Redirects and ambient proxies are disabled."""
import json
import socket
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote, urlsplit

from .contracts import GovernanceError, identifier, manifest, require


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise GovernanceError("redirect_refused")


class Api:
    def __init__(self, base, token="", *, allow_loopback=False, timeout=30):
        parsed = urlsplit(base)
        require(parsed.scheme in {"http", "https"} and parsed.hostname and not parsed.username
                and not parsed.password and not parsed.query and not parsed.fragment, "invalid_api_base")
        require(parsed.scheme == "https" or (allow_loopback and parsed.hostname in {"127.0.0.1", "::1", "localhost"}), "https_required")
        self.base = base.rstrip("/"); self.token = token; self.timeout = timeout
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def open(self, method, path, body=None, headers=None):
        require(path.startswith("/") and not path.startswith("//") and "://" not in path, "unsafe_api_path")
        all_headers = dict(headers or {})
        if self.token: all_headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(self.base + path, data=body, method=method, headers=all_headers)
        try:
            return self.opener.open(request, timeout=self.timeout)
        except urllib.error.HTTPError as exc:
            code = exc.code; exc.close()
            raise GovernanceError(f"upstream_{code}") from None
        except (urllib.error.URLError, TimeoutError, socket.timeout, OSError):
            raise GovernanceError("upstream_unavailable") from None

    def json(self, method, path, body=None, headers=None):
        headers = dict(headers or {})
        if body is not None:
            body = json.dumps(body, allow_nan=False).encode(); headers["Content-Type"] = "application/json"
        with self.open(method, path, body, headers) as response:
            raw = response.read(2 * 1024 * 1024 + 1)
            require(len(raw) <= 2 * 1024 * 1024, "response_too_large")
            try:
                return json.loads(raw) if raw else {}
            except (ValueError, UnicodeDecodeError):
                raise GovernanceError("invalid_api_response") from None


class AuthorityClient:
    def __init__(self, api): self.api = api
    def manifest(self, release_id):
        require(identifier(release_id), "invalid_release")
        value = manifest(self.api.json("GET", f"/model-releases/{release_id}/manifest"))
        require(value["release_id"] == release_id, "release_identity_mismatch")
        return value

    def download(self, value, destination, report=None):
        """Approved artifacts only; cap bytes to signed manifest size and resume via Range."""
        from .contracts import digest, safe_path
        from .files import private_dir
        self.manifest(value["release_id"])
        destination = private_dir(destination)
        for item in value["files"]:
            path = destination / safe_path(item["path"])
            private_dir(path.parent)
            require(not path.is_symlink() and not getattr(path, "is_junction", lambda: False)(), "unsafe_path")
            if path.exists() and path.stat().st_size == item["size"] and digest(path) == item["sha256"]:
                continue
            partial = path.with_name(path.name + ".partial")
            require(not partial.is_symlink() and (not partial.exists() or partial.stat().st_nlink == 1), "unsafe_path")
            offset = partial.stat().st_size if partial.exists() else 0
            if offset >= item["size"]: partial.unlink(); offset = 0
            route = f"/model-releases/{value['release_id']}/files/" + quote(item["path"], safe="/")
            with self.api.open("GET", route, headers={"Range": f"bytes={offset}-"} if offset else {}) as response:
                if response.status != 206: offset = 0
                else:
                    require(response.headers.get("Content-Range", "").startswith(f"bytes {offset}-"), "invalid_content_range")
                with partial.open("ab" if offset else "wb") as out:
                    while chunk := response.read(min(1024 * 1024, item["size"] - offset + 1)):
                        offset += len(chunk)
                        require(offset <= item["size"], "artifact_oversized")
                        out.write(chunk)
                        if report: report(offset, item["size"])
            require(offset == item["size"] and digest(partial) == item["sha256"], "artifact_mismatch")
            partial.replace(path)


def optional_get(api, path):
    try: return api.json("GET", path)
    except GovernanceError as exc:
        if exc.code == "upstream_404": return None
        raise
