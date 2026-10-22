"""Read-only runtime checks for Docker privacy mode. Does not certify host/client isolation."""

import json
import subprocess
import sys


BACKENDS = (
    "pocketmind-postgres", "pocketmind-ollama", "pocketmind-litellm",
    "pocketmind-open-webui", "pocketmind-prometheus", "pocketmind-grafana",
)


def docker(*args, stdin=None):
    result = subprocess.run(
        ["docker", *args], input=stdin, text=True, capture_output=True, timeout=60,
    )
    if result.returncode:
        # Docker errors/inspect output can contain secrets. Do not echo them.
        raise RuntimeError("Docker check failed; confirm the stack is running and Docker is accessible.")
    return result.stdout


def validate_backend(container, networks):
    if not container.get("State", {}).get("Running"):
        raise RuntimeError("A required backend is not running.")
    if container["HostConfig"].get("NetworkMode") == "host":
        raise RuntimeError("A backend uses host networking.")
    attached = container["NetworkSettings"].get("Networks", {})
    if not attached or any(not networks[name].get("Internal") for name in attached):
        raise RuntimeError("A backend is attached to a non-internal network.")
    for bindings in (container["HostConfig"].get("PortBindings") or {}).values():
        if any(binding.get("HostIp") != "127.0.0.1" for binding in (bindings or [])):
            raise RuntimeError("A backend port is published beyond loopback.")


# Run inside LiteLLM, where Python and the service master key already exist.
# Never return the environment, credentials, prompts or model configuration to the host.
PROBE = r'''
import json, os, socket, urllib.request
from urllib.parse import urlparse

def connect(host, port):
    with socket.create_connection((host, port), timeout=4):
        pass

connect("postgres", 5432)
connect("ollama", 11434)
for address in ("1.1.1.1", "2606:4700:4700::1111"):
    try:
        connect(address, 443)
    except OSError:
        pass
    else:
        raise RuntimeError("Unexpected external TCP connectivity")

request = urllib.request.Request(
    "http://127.0.0.1:4000/model/info",
    headers={"Authorization": "Bearer " + os.environ["LITELLM_MASTER_KEY"]},
)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(request, timeout=15) as response:
    catalog = json.load(response)
models = catalog.get("data")
if not isinstance(models, list) or not models:
    raise RuntimeError("Cannot validate model routing")
for item in models:
    params = item.get("litellm_params") or {}
    base = params.get("api_base", "")
    if base.startswith("os.environ/"):
        base = os.environ.get(base[len("os.environ/"):], "")
    parsed = urlparse(base)
    if (not params.get("model", "").startswith("ollama_chat/")
        or parsed.scheme != "http" or parsed.hostname != "ollama" or parsed.port != 11434):
        raise RuntimeError("Non-local model route found")
print("PASS: internal services reachable; external TCP probes blocked; model routes point to local Ollama.")
'''


def main():
    inspected = json.loads(docker("inspect", *BACKENDS))
    network_names = sorted({name for c in inspected for name in c["NetworkSettings"]["Networks"]})
    networks = {n["Name"]: n for n in json.loads(docker("network", "inspect", *network_names))}
    for container in inspected:
        validate_backend(container, networks)
    print("PASS: required backend containers use internal networks and loopback-only published ports.")
    webui = next(c for c in inspected if c["Name"] == "/pocketmind-open-webui")
    env = dict(value.split("=", 1) for value in webui["Config"]["Env"] if "=" in value)
    if env.get("OFFLINE_MODE") != "true" or env.get("ENABLE_PERSISTENT_CONFIG") != "false":
        raise RuntimeError("Open WebUI privacy settings are not active.")
    ollama = next(c for c in inspected if c["Name"] == "/pocketmind-ollama")
    if "OLLAMA_NO_CLOUD=1" not in ollama["Config"]["Env"]:
        raise RuntimeError("Ollama cloud-disable setting is missing.")
    print("PASS: Open WebUI offline settings and Ollama cloud-disable flag are present.")
    output = docker("exec", "-i", "pocketmind-litellm", "python", "-", stdin=PROBE)
    print(output.strip())
    print("LIMIT: probes do not prove all egress paths are closed. Verify host, nginx, DNS, IPv6, browser/IDE, tools and firewall logs separately.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError, ValueError, KeyError, OSError, TypeError, AttributeError):
        print("FAIL: privacy checks did not pass. Check network attachment, loopback ports, environment settings and local model routes. No secrets were printed.", file=sys.stderr)
        sys.exit(1)
