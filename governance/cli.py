"""CLI/PowerShell entrypoint. Source credentials never appear in arguments."""
import argparse
import json
import secrets
import sys
import threading
from pathlib import Path

from .contracts import GovernanceError, demand, identifier, require
from .delivery import Delivery, FixtureRuntime, RemoteClient
from .http import AuthorityClient
from .importer import Importer
from .settings import api, load_settings, runtime, secret


def parser():
    root = argparse.ArgumentParser(description="Optional PocketMind governed model delivery (Python 3.11+).")
    commands = root.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="Start the explicitly synthetic POC UI/coordinator")
    serve.add_argument("--fixture", action="store_true", required=True)
    serve.add_argument("--embedded-agent", action="store_true")
    serve.add_argument("--host", default="127.0.0.1", choices=["127.0.0.1", "0.0.0.0"])
    serve.add_argument("--port", type=int, default=8787)
    serve.add_argument("--state", default=".governance-state/demo")
    serve.add_argument("--target", default="local")
    req = commands.add_parser("request")
    req.add_argument("--source", required=True, choices=["huggingface", "ollama"])
    req.add_argument("--model-id", required=True); req.add_argument("--revision", default="main")
    req.add_argument("--artifact", default="model.gguf"); req.add_argument("--alias", required=True)
    req.add_argument("--target-id", required=True); req.add_argument("--group", required=True)
    req.add_argument("--purpose", required=True); req.add_argument("--idempotency-key", default=None)
    req.add_argument("--config", required=True)
    for name in ("status", "retry", "cancel"):
        cmd = commands.add_parser(name); cmd.add_argument("--job-id", required=True); cmd.add_argument("--config", required=True)
    agent = commands.add_parser("agent")
    agent.add_argument("--config", required=True); agent.add_argument("--fixture", action="store_true")
    agent.add_argument("--once", action="store_true"); agent.add_argument("--profile", default="cpu")
    imp = commands.add_parser("import")
    imp.add_argument("--config", required=True); imp.add_argument("--manifest", required=True)
    imp.add_argument("--bundle", required=True); imp.add_argument("--alias", required=True)
    imp.add_argument("--group", required=True); imp.add_argument("--profile", default="cpu")
    imp.add_argument("--check-only", action="store_true")
    return root


def emit(value): print(json.dumps(value, ensure_ascii=False, indent=2))


def run(args):
    if args.command == "serve":
        from .server import make_server
        require(identifier(args.target), "invalid_target")
        server = make_server(args.state, secret("POCKETMIND_GOV_ADMIN_TOKEN"),
                             {args.target: secret("POCKETMIND_GOV_AGENT_TOKEN")}, port=args.port,
                             host=args.host, embedded_agent=args.embedded_agent)
        server.start_workers()
        print(f"SYNTHETIC FIXTURE POC: http://127.0.0.1:{server.server_port}/jobs", flush=True)
        print("No real downloads/scans/model installation. Stop with Ctrl+C; jobs persist.", flush=True)
        try: server.serve_forever()
        finally: server.server_close()
        return
    if args.command in {"agent", "import"}:
        require(args.profile in {"cpu", "nvidia"}, "unsupported_profile")
    settings = load_settings(args.config)
    if args.command == "request":
        value = demand({"source": args.source, "model_id": args.model_id, "revision": args.revision,
                        "artifact": args.artifact, "alias": args.alias, "target_id": args.target_id,
                        "access_group_id": args.group, "purpose": args.purpose})
        emit(api(settings, "admin").json("POST", "/model-acquisitions", value,
                                         {"Idempotency-Key": args.idempotency_key or secrets.token_urlsafe(24)}))
    elif args.command in {"status", "retry", "cancel"}:
        require(identifier(args.job_id), "invalid_job_id")
        path = "/model-acquisitions/" + args.job_id
        emit(api(settings, "admin").json("GET" if args.command == "status" else "POST",
                                          path if args.command == "status" else path + "/" + args.command))
    elif args.command == "import":
        client = api(settings, "admin")
        authority = AuthorityClient(client)
        value = json.loads(Path(args.manifest).read_text("utf-8"))
        importer = Importer(settings["state_dir"], authority, runtime(settings, args.group))
        emit(importer.run(value, args.bundle, args.alias, args.group, check_only=args.check_only))
    else:
        client = api(settings, "agent"); authority = AuthorityClient(client)
        target = settings.get("target_id"); require(identifier(target), "invalid_target")
        state = Path(settings.get("state_dir", ".governance-state/agent"))
        if args.fixture:
            local_runtime = FixtureRuntime(state / "fixture-runtime.json")
        else:
            # Authorization is checked against every job's requested group, not a UI supplied endpoint.
            class RuntimeProxy:
                wrapped = None
                def preflight(self, value, alias, group):
                    self.wrapped = runtime(settings, group); self.wrapped.preflight(value, alias, group)
                def __getattr__(self, name): return getattr(self.wrapped, name)
            local_runtime = RuntimeProxy()
        delivery = Delivery(RemoteClient(client), authority, local_runtime, state, target)
        stop = threading.Event()
        while True:
            delivery.run_once()
            if args.once: break
            stop.wait(2)


def main(argv=None):
    require(sys.version_info >= (3, 11), "python_311_required")
    args = parser().parse_args(argv)
    try:
        run(args)
        return 0
    except GovernanceError as exc:
        print("Governance: " + exc.code, file=sys.stderr); return 1
    except KeyboardInterrupt:
        return 130
    except Exception:
        print("Governance: command_failed (inspect private deployment configuration)", file=sys.stderr); return 1
