"""Optional local POC coordinator/admin UI. Synthetic acquisition is explicit and isolated."""
from __future__ import annotations

import html
import json
import re
import secrets
import threading
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

from .contracts import GovernanceError, identifier, require, safe_path
from .delivery import Delivery, FixtureAcquisition, FixtureRuntime, LocalClient
from .files import private_dir
from .jobs import JobStore


def esc(value): return html.escape(str(value), quote=True)


def page(title, content, *, refresh=False):
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    {('<meta http-equiv="refresh" content="2">' if refresh else '')}<title>{esc(title)} · PocketMind</title>
    <style>body{{font:16px system-ui;margin:0;background:#f3f6fb;color:#172338}}main{{max-width:1000px;margin:36px auto;padding:0 24px}}
    header{{background:#14263f;color:white;padding:20px 28px}}header a{{color:white;text-decoration:none}}h1{{font-size:28px}}h2{{font-size:21px}}
    .banner{{background:#fff0ca;padding:14px;border-left:4px solid #ba7a00;border-radius:6px}}.card{{background:white;padding:24px;margin:20px 0;border:1px solid #dae2ee;border-radius:12px}}
    form.grid{{display:grid;grid-template-columns:1fr 1fr;gap:16px}}label{{display:block;font-size:14px;font-weight:600}}input,select,textarea{{box-sizing:border-box;width:100%;padding:10px;margin-top:6px;border:1px solid #a8b6c9;border-radius:5px;font:inherit}}
    button{{background:#245bb5;color:white;border:0;border-radius:6px;padding:11px 20px;font:inherit;cursor:pointer}}a{{color:#245bb5}}small,.muted{{color:#52637b}}table{{width:100%;border-collapse:collapse}}td,th{{text-align:left;border-bottom:1px solid #e2e7ef;padding:12px 8px}}.succeeded,.ready{{color:#116841}}.failed,.rejected{{color:#aa2531}}.running{{color:#245bb5}}.inline{{display:inline-block;margin-right:12px}}code{{overflow-wrap:anywhere}}@media(max-width:650px){{form.grid{{grid-template-columns:1fr}}td,th{{padding:8px 3px;font-size:13px}}}}</style></head><body>
    <header><a href="/jobs"><strong>PocketMind</strong> / Model governance POC</a></header><main>
    <div class="banner"><strong>SYNTHETIC FIXTURE MODE</strong> — No external download, real security scan or live model installation. Your serving stack is unchanged.</div>
    <h1>{esc(title)}</h1>{content}</main></body></html>'''


class Coordinator(ThreadingHTTPServer):
    daemon_threads = True
    def start_workers(self):
        def work():
            while not self.stopping.wait(0.25):
                for target in self.agents:
                    try:
                        self.source.run_once(target)
                        if self.embedded_agent:
                            Delivery(LocalClient(self.store), self.source, self.runtime,
                                     self.root / "agent" / target, target).run_once()
                    except Exception:
                        # No secrets/provider bodies on console. Durable failures are visible in job status.
                        self.worker_error = "worker_failed_check_job_status"
        worker = threading.Thread(target=work, daemon=True); self.workers.append(worker); worker.start()

    def server_close(self):
        self.stopping.set()
        for worker in self.workers: worker.join(timeout=5)
        super().server_close()


class Handler(BaseHTTPRequestHandler):
    server_version = "PocketMindGovernancePOC"
    def log_message(self, *args): pass  # Never log credentials, query strings or request bodies.

    def send(self, status, value, *, html_page=False, headers=None):
        raw = value.encode("utf-8") if html_page else json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8" if html_page else "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
        for key, value in (headers or {}).items(): self.send_header(key, value)
        self.end_headers(); self.wfile.write(raw)

    def redirect(self, path, cookie=None):
        self.send(303, {}, headers={"Location": path, **({"Set-Cookie": cookie} if cookie else {})})

    def token(self):
        return self.headers.get("Authorization", "").removeprefix("Bearer ") if self.headers.get("Authorization", "").startswith("Bearer ") else ""

    def admin(self):
        require(secrets.compare_digest(self.token(), self.server.admin_token), "unauthorized")

    def agent(self):
        token = self.token()
        target = next((name for name, secret in self.server.agents.items() if secrets.compare_digest(token, secret)), None)
        require(target is not None, "forbidden")
        return target

    def session(self):
        cookie = SimpleCookie()
        try: cookie.load(self.headers.get("Cookie", ""))
        except Exception: return None
        key = cookie.get("pm_governance")
        if not key: return None
        with self.server.sessions_lock:
            entry = self.server.sessions.get(key.value)
            return entry if entry and entry["expires"] > time.time() else None

    def origin(self):
        value = self.headers.get("Origin")
        require(value == "http://" + self.headers.get("Host", ""), "forbidden")

    def body(self, form=False):
        raw = self.raw_body
        try:
            if form:
                return {key: val[0] for key, val in parse_qs(raw.decode("utf-8"), max_num_fields=20).items()}
            require(self.headers.get("Content-Type", "").split(";")[0] == "application/json", "invalid_content_type")
            value = json.loads(raw)
            require(isinstance(value, dict), "invalid_body")
            return value
        except (ValueError, UnicodeDecodeError): raise GovernanceError("invalid_body") from None

    def read_body(self):
        try: size = int(self.headers.get("Content-Length", "-1"))
        except ValueError: raise GovernanceError("invalid_body") from None
        require(0 <= size <= 65536 and not self.headers.get("Transfer-Encoding"), "invalid_body")
        self.connection.settimeout(10)
        raw = self.rfile.read(size)
        require(len(raw) == size, "invalid_body")
        return raw

    def do_GET(self): self.dispatch("GET")
    def do_POST(self): self.dispatch("POST")

    def dispatch(self, method):
        try:
            require(self.headers.get("Host") in self.server.allowed_hosts, "forbidden")
            self.raw_body = self.read_body() if method == "POST" else b""
            path = urlsplit(self.path).path
            if method == "GET" and path == "/health":
                return self.send(200, {"status": "ok", "mode": "synthetic_fixture", "worker_error": self.server.worker_error})
            if path in {"/", "/login"}:
                if method == "GET":
                    return self.send(200, page("Sign in", '<section class="card"><p>Use the admin token configured for this POC. Tokens are never included in URLs.</p><form method="post" action="/login"><label>Admin token<input type="password" name="token" required autocomplete="off"></label><p><button>Sign in</button></p></form></section>'), html_page=True)
                self.origin(); body = self.body(form=True)
                require(secrets.compare_digest(body.get("token", ""), self.server.admin_token), "unauthorized")
                sid = secrets.token_urlsafe(32)
                with self.server.sessions_lock:
                    self.server.sessions = {k: v for k, v in self.server.sessions.items() if v["expires"] > time.time()}
                    require(len(self.server.sessions) < 100, "session_limit")
                    self.server.sessions[sid] = {"csrf": secrets.token_urlsafe(32), "expires": time.time() + 3600}
                return self.redirect("/jobs", f"pm_governance={sid}; HttpOnly; SameSite=Strict; Path=/; Max-Age=3600")
            if path.startswith("/jobs"):
                return self.browser(method, path)
            if path.startswith("/agent/"):
                target = self.agent(); body = self.body()
                if path == "/agent/claim":
                    require(body.get("target_id") == target, "forbidden")
                    return self.send(200, {"job": self.server.store.claim(target, phase="delivery")})
                match = re.fullmatch(r"/agent/jobs/([a-z0-9-]+)/(heartbeat|step|finish)", path)
                require(match is not None and method == "POST", "not_found")
                job_id, action = match.groups()
                job = self.server.store.get(job_id)
                require(job["request"]["target_id"] == target, "forbidden")
                lease = body.pop("lease", "")
                if action == "heartbeat": self.server.store.heartbeat(job_id, lease)
                elif action == "step":
                    require(set(body) <= {"name", "status", "error", "progress"}, "invalid_body")
                    self.server.store.step(job_id, lease, **body)
                else:
                    # A target agent cannot reject/approve releases through this endpoint.
                    require(body.get("state") in {"ready", "failed"}, "invalid_state")
                    self.server.store.finish(job_id, lease, body["state"])
                return self.send(200, {"ok": True})
            if path.startswith("/model-releases/"):
                require(method == "GET", "not_found")
                match = re.fullmatch(r"/model-releases/([A-Za-z0-9_.-]+)/(manifest|files/(.+))", path)
                require(match is not None, "not_found")
                release_id, route, name = match.groups()
                if not secrets.compare_digest(self.token(), self.server.admin_token):
                    target = self.agent()
                    require(self.server.store.permits_release(target, release_id), "forbidden")
                value = self.server.source.manifest(release_id)
                if route == "manifest": return self.send(200, value)
                name = safe_path(unquote(name))
                require(name in [f["path"] for f in value["files"]], "not_found")
                file = self.server.source.root / release_id / "bundle" / name
                size = file.stat().st_size; start = 0
                if self.headers.get("Range"):
                    found = re.fullmatch(r"bytes=(\d+)-", self.headers["Range"])
                    require(found is not None, "invalid_range")
                    start = int(found[1]); require(start < size, "invalid_range")
                self.send_response(206 if start else 200); self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(size - start)); self.send_header("Accept-Ranges", "bytes")
                if start: self.send_header("Content-Range", f"bytes {start}-{size-1}/{size}")
                self.end_headers()
                with file.open("rb") as stream:
                    stream.seek(start)
                    while chunk := stream.read(1024 * 1024): self.wfile.write(chunk)
                return
            self.admin()
            if path == "/model-acquisitions":
                if method == "GET": return self.send(200, {"jobs": self.server.store.list(), "mode": "synthetic_fixture"})
                return self.send(202, self.server.store.submit(self.body(), self.headers.get("Idempotency-Key")))
            match = re.fullmatch(r"/model-acquisitions/([a-z0-9-]+)(?:/(retry|cancel))?", path)
            require(match is not None, "not_found")
            job_id, action = match.groups()
            if method == "GET" and action is None: return self.send(200, self.server.store.get(job_id))
            require(method == "POST" and action in {"retry", "cancel"}, "not_found")
            return self.send(200, getattr(self.server.store, action)(job_id))
        except GovernanceError as exc:
            status = {"unauthorized": 401, "forbidden": 403, "not_found": 404, "job_not_found": 404,
                      "alias_reserved": 409, "idempotency_conflict": 409, "stale_or_cancelled_lease": 409}.get(exc.code, 400)
            self.send(status, {"error": exc.code})
        except (BrokenPipeError, ConnectionResetError): pass
        except Exception:
            self.send(500, {"error": "internal_error"})

    def browser(self, method, path):
        session = self.session()
        if session is None:
            require(method == "GET", "unauthorized")
            return self.redirect("/login")
        csrf = session["csrf"]
        hidden = f'<input type="hidden" name="csrf" value="{esc(csrf)}">'
        if method == "POST":
            self.origin(); body = self.body(form=True)
            require(secrets.compare_digest(body.pop("csrf", ""), csrf), "forbidden")
            if path == "/jobs":
                key = body.pop("idempotency_key", "")
                job = self.server.store.submit(body, key)
                return self.redirect("/jobs/" + job["job_id"])
            match = re.fullmatch(r"/jobs/([a-z0-9-]+)/(retry|cancel)", path)
            require(match is not None, "not_found")
            job_id, action = match.groups(); getattr(self.server.store, action)(job_id)
            return self.redirect("/jobs/" + job_id)
        if path == "/jobs":
            rows = "".join(f'<tr><td><a href="/jobs/{esc(j["job_id"])}">{esc(j["request"]["alias"])}</a></td><td>{esc(j["request"]["model_id"])}</td><td class="{esc(j["state"])}">{esc(j["state"])}</td></tr>' for j in self.server.store.list())
            content = f'''<section class="card"><h2>Select a model</h2><p class="muted">One request runs the complete fixture workflow. Approved delivery includes the selected group grant.</p>
            <form class="grid" method="post" action="/jobs">{hidden}<input type="hidden" name="idempotency_key" value="{secrets.token_urlsafe(24)}">
            <label>Source<select name="source"><option value="huggingface">Hugging Face</option><option value="ollama">Ollama</option></select></label>
            <label>Model identifier or provider link<input name="model_id" value="pocketmind-fixtures/tiny-gguf" required></label>
            <label>Revision / tag<select name="revision"><option>main</option><option>latest</option><option>review-required</option><option>scan-error</option></select></label>
            <label>Artifact / quantization<input name="artifact" value="model.gguf" required></label>
            <label>New model alias<input name="alias" value="fixture-general" required maxlength="128"></label>
            <label>Target<select name="target_id">{''.join(f'<option>{esc(t)}</option>' for t in self.server.agents)}</select></label>
            <label>User group<select name="access_group_id"><option>testers</option></select></label><label>Purpose<input name="purpose" value="Local governance POC" required></label>
            <button type="submit">Request model</button></form><p><small>Ollama fixture: <code>pocketmind-fixture:tiny</code>. Only these synthetic models are available here.</small></p></section>
            <section class="card"><h2>Requests</h2><table><thead><tr><th>Alias</th><th>Source model</th><th>State</th></tr></thead><tbody>{rows or '<tr><td colspan="3">No requests yet.</td></tr>'}</tbody></table></section>'''
            return self.send(200, page("Model requests", content), html_page=True)
        match = re.fullmatch(r"/jobs/([a-z0-9-]+)", path)
        require(match is not None, "not_found")
        job = self.server.store.get(match[1])
        rows = ""
        for index, step in enumerate(job["steps"], 1):
            progress = ""
            if step["bytes"] is not None:
                progress = f'{step["bytes"]} / {step["total_bytes"]} bytes' if step["total_bytes"] is not None else f'{step["bytes"]} bytes; total unknown'
            rows += f'<tr><td>{index}. {esc(step["name"].replace("_", " "))}</td><td class="{esc(step["status"])}">{esc(step["status"])}</td><td>{esc(step["error"] or progress)}</td><td>{step["attempts"]}</td></tr>'
        actions = ""
        if job["state"] == "failed": actions += f'<form class="inline" method="post" action="{path}/retry">{hidden}<button>Retry from checkpoint</button></form>'
        if job["state"] not in {"ready", "cancelled"}: actions += f'<form class="inline" method="post" action="{path}/cancel">{hidden}<button>Cancel</button></form>'
        retry_note = '<p>Transient failure: automatic retry is scheduled. No admin action is needed yet.</p>' if job.get("next_retry_at") else ''
        content = f'''<p><a href="/jobs">← All requests</a></p><section class="card"><h2>{esc(job["request"]["alias"])}</h2><p>State: <strong class="{esc(job["state"])}">{esc(job["state"])}</strong> · Target: {esc(job["request"]["target_id"])} · Group: {esc(job["request"]["access_group_id"])}</p><small>Job: <code>{esc(job["job_id"])}</code> · Attempt: {job["attempt"]}</small>{retry_note}<p>{actions}</p></section>
        <section class="card"><h2>Delivery checklist</h2><table><thead><tr><th>Step</th><th>Status</th><th>Progress / action</th><th>Runs</th></tr></thead><tbody>{rows}</tbody></table><p class="muted">Active jobs refresh every two seconds. Closing this page does not stop the job. Ready here means synthetic group availability only.</p></section>'''
        return self.send(200, page("Delivery progress", content, refresh=job["state"] in {"requested", "running"} or bool(job.get("next_retry_at"))), html_page=True)


def make_server(root, admin_token, agents, *, port=8787, host="127.0.0.1", embedded_agent=False):
    require(isinstance(admin_token, str) and len(admin_token) >= 32, "weak_admin_token")
    require(agents and all(identifier(k) and isinstance(v, str) and len(v) >= 32 and v != admin_token for k, v in agents.items())
            and len(set(agents.values())) == len(agents), "invalid_agent_tokens")
    server = Coordinator((host, port), Handler)
    server.root = private_dir(root)
    server.store = JobStore(server.root / "jobs.db")
    server.source = FixtureAcquisition(server.store, server.root / "releases", {t: ["testers"] for t in agents})
    server.runtime = FixtureRuntime(server.root / "fixture-runtime.json")
    server.admin_token, server.agents = admin_token, agents
    server.sessions = {}; server.sessions_lock = threading.Lock()
    server.allowed_hosts = {f"127.0.0.1:{server.server_port}", f"localhost:{server.server_port}"}
    server.embedded_agent = embedded_agent
    server.stopping = threading.Event(); server.workers = []; server.worker_error = None
    return server
