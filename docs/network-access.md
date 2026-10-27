# Network access, ports and proxy

## Service URLs and credentials

| Service | Address |
|---|---|
| Open WebUI | http://localhost:3000 |
| LiteLLM API | http://localhost:4000/v1 |
| LiteLLM Admin | http://localhost:4000/ui |
| Ollama container/host | http://localhost:11434 when applicable (this host only by default) |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3001 |
| PostgreSQL | `127.0.0.1:5432` |
| nginx proxy, Open WebUI (optional) | http://localhost:8480, or `http://<host-ip>:8480` when shared |
| nginx proxy, LiteLLM API (optional) | http://localhost:8481/v1, or `http://<host-ip>:8481/v1` when shared |

Repository scripts start the nginx proxy when `PROXY_ENABLED=true` in `.env` (see "Shared pilot access with the nginx proxy"). The Docker CPU/NVIDIA base file publishes the Postgres, LiteLLM, Open WebUI, Prometheus and Grafana ports on `${BACKEND_BIND_ADDRESS:-0.0.0.0}`, so with the default those URLs also work with the server IP (subject to firewall rules). **Ollama (11434) is the exception:** it has no authentication, so its host port follows `${OLLAMA_BIND_ADDRESS:-127.0.0.1}` and stays on loopback; LiteLLM reaches it over the internal Docker network, and `docker exec pocketmind-ollama ollama ...` needs no published port. The native profile keeps backend ports on `127.0.0.1`. Privacy mode replaces backend bindings with loopback-only bindings; the proxy listens on `0.0.0.0` unless `PROXY_BIND_ADDRESS` says otherwise.

Credentials are the private values you set in `.env` after copying `.env.example`:

```text
LiteLLM admin username: admin
LiteLLM password/API master key: LITELLM_MASTER_KEY from .env
Grafana username: GRAFANA_ADMIN_USER from .env (admin in the example)
Grafana password: GRAFANA_ADMIN_PASSWORD from .env
```

The prerequisite checker refuses to start while any secret still has a `CHANGE_ME` placeholder. Never commit `.env`.

## PostgreSQL and DBeaver

```text
Host: server IP for approved direct access, or 127.0.0.1 on the server
Port: 5432
Database: value of POSTGRES_DB in .env
Username: value of POSTGRES_USER in .env
Password: value of POSTGRES_PASSWORD in .env
```

Another local PostgreSQL instance, including OpenMetadata PostgreSQL, must not occupy port `5432`.

## Shared pilot access with the nginx proxy

The Docker CPU/NVIDIA base file permits direct access to every published backend port; restrict those ports to approved admin clients. For user access through limited inference routes, or with native/Privacy mode where backend ports bind to loopback, use the optional nginx container (`docker-compose.proxy.yml`):

| Host port (default) | Goes to | What is reachable |
|---|---|---|
| `8480` | Open WebUI | everything Open WebUI serves, including websockets |
| `8481` | LiteLLM | only `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/responses`, and `/v1/models`; every other path (`/ui`, `/key`, `/model`, `/team`, `/user`, `/openapi.json`, `/metrics`) is a 404 |

It uses plain HTTP, so no certificate or DNS name is needed; users open `http://<host-ip>:8480` and call `http://<host-ip>:8481/v1`. Enable it in the private `.env`:

```text
PROXY_ENABLED=true
PROXY_BIND_ADDRESS=0.0.0.0
```

`PROXY_BIND_ADDRESS` defaults to `0.0.0.0`, so the proxy is reachable from every machine that can route to this host. Set it to the host's LAN IP to use one interface only, or to `127.0.0.1` to keep it on this host. Once `PROXY_ENABLED=true` is in `.env`, every script (`setup`, `verify-stack`, and so on) adds the overlay automatically, so a later run cannot remove the proxy as an orphan. Then run `pwsh ./scripts/setup.ps1 -Profile <profile>` and `pwsh ./scripts/verify-stack.ps1 -Profile <profile>`; the verifier creates a short-lived scoped key, chats through the API port, and checks that the administration paths return 404. Set the API Key Manager Valve `public_base_url` to `http://<host-ip>:8481/v1`.

Limit who may connect with a git-ignored `nginx/local/*.conf` (`allow <cidr>;` lines and `deny all;`), and coordinate Docker-aware firewall rules with Infra: on Linux, ports published by Docker Engine are typically handled by Docker's own iptables rules and can bypass `ufw`, and on Docker Desktop (observed on macOS) nginx sees every client as the VM gateway address, so address rules and per-address rate limits cannot tell clients apart there. The steps and how to see the real client address are in the [operations runbook](operations-runbook.md#shared-pilot-proxy-nginx).

The API port limits each client address to 30 requests per second (burst 60), Open WebUI's sign-in and session endpoints to 2 per second (burst 10) to slow password guessing, and the proxy accepts bodies up to 50 MB, enough for base64 OCR images. Browsers may call the API cross-origin (OPTIONS preflight is allowed). Traffic is not encrypted: passwords and API keys can be read on the network, so use it only on a trusted internal network with test data, never on the internet, and move to HTTPS before real use. Use strong secrets in `.env`, keep sign-up closed, and see ADR 0005 and the security guidance.

When the proxy is enabled, include the overlay in manual commands, for example `docker compose -f docker-compose.native-ollama.yml -f docker-compose.proxy.yml down`.

## Temporary public test with Cloudflare Quick Tunnel

Use a [Cloudflare Quick Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/) to test Open WebUI from another network without buying a public IP, forwarding router ports, or changing PocketMind's backend port bindings. Quick Tunnels are temporary, have no uptime guarantee, and are not suitable for production.

Before starting, verify that Open WebUI is healthy with the same Compose file arguments used to start the active profile. For example, for the NVIDIA profile:

```text
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml ps open-webui
curl http://127.0.0.1:3000/api/config
```

For the CPU profile use plain `docker compose ps open-webui`; for native Ollama use `docker compose -f docker-compose.native-ollama.yml ps open-webui`. The returned configuration should show authentication enabled and signup disabled. Then start a tunnel on Windows or macOS with Docker Desktop:

```text
docker pull cloudflare/cloudflared:latest
docker run --detach \
  --name pocketmind-cloudflared-quick \
  --restart no \
  cloudflare/cloudflared:latest \
  tunnel --no-autoupdate --url http://host.docker.internal:3000
```

On Linux, add Docker's host-gateway mapping:

```text
docker run --detach \
  --name pocketmind-cloudflared-quick \
  --restart no \
  --add-host host.docker.internal:host-gateway \
  cloudflare/cloudflared:latest \
  tunnel --no-autoupdate --url http://host.docker.internal:3000
```

Read the generated public HTTPS URL from the logs:

```text
docker logs pocketmind-cloudflared-quick
```

Look for a URL ending in `.trycloudflare.com`, open it from a device on another network, sign in with an existing Open WebUI account, select `default-general`, and send a test message. Do not publish the temporary URL or any credentials in the repository.

Only Open WebUI port `3000` is proxied by this command. Do not create public tunnels to LiteLLM, PostgreSQL, Ollama, Prometheus, Grafana, or the NVIDIA exporter. In particular, never expose or distribute `LITELLM_MASTER_KEY` as a client API key.

Manage the test tunnel with:

```text
# Show status and logs
docker ps --filter name=pocketmind-cloudflared-quick
docker logs pocketmind-cloudflared-quick

# Stop or resume the existing container
docker stop pocketmind-cloudflared-quick
docker start pocketmind-cloudflared-quick

# Remove it when testing is finished
docker rm -f pocketmind-cloudflared-quick
```

The `--restart no` policy prevents this temporary public endpoint from silently returning after a Docker or host restart. Restarting the tunnel process can produce a different public URL. If the container name already exists and you intentionally want a fresh tunnel, remove the old container before running `docker run` again. For a stable hostname and access policies, replace Quick Tunnel with a named Cloudflare Tunnel tied to a domain managed in Cloudflare.

## Manual NVIDIA commands and firewall handoff

From the repository root, with the proxy enabled:

```bash
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml up -d
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
curl --noproxy '*' http://127.0.0.1:8481/nginx-health
```

Raw Compose does not interpret `PROXY_ENABLED` or `PRIVACY_MODE` as file-selection switches. List the proxy file explicitly; if privacy is active, append `-f docker-compose.privacy.yml` last to lifecycle commands. Repository scripts handle those flags automatically.

Ask Infra for TCP access from approved client networks to `8480` (WebUI, including WebSocket Upgrade) and `8481` (inference API), or the organization's HTTPS ingress. Direct admin/diagnostic access uses TCP `3000`, `3001`, `4000`, `9090`, `5432` only where deliberately permitted (`11434` is loopback-only by default and should stay closed); PostgreSQL is not a web page. Port `9835` is internal and needs no client firewall opening. Port `9100` is optional host-exporter traffic, not a browser endpoint. SSH/PAM follows the organization's management policy.

`0.0.0.0` is a listen address, not a browser destination. Use the server's IP/name. Opening a firewall cannot expose a port bound only to `127.0.0.1`, and cannot create an nginx listener that has not been started. See [connection troubleshooting](troubleshooting.md) and [privacy](privacy.md) before broadening access.

Temporary Cloudflare tunnels are for synthetic public tests only, require external connectivity, and conflict with the isolated-serving policy. They are not an enterprise ingress configuration. A backend bound to loopback may be unreachable through a bridge container's host-gateway address on Linux; use an approved ingress path rather than broadening private bindings to make this test work.
