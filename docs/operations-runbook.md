# PocketMind Operations Runbook

Use the root README for first-time setup. Use this runbook for a system that has already been configured with a private `.env`.

## Normal startup

```powershell
pwsh ./scripts/setup.ps1 -Profile auto
```

Add `-Pull` only when images or configured production model weights must be downloaded:

```powershell
pwsh ./scripts/setup.ps1 -Profile auto -Pull
```

## Full verification

```powershell
pwsh ./scripts/verify-stack.ps1 -Profile auto
```

The verifier checks container health, PostgreSQL authentication, `corp-general` inference, invalid-key rejection, service UIs, Prometheus targets/metrics, Grafana provisioning, configured model presence, and GPU placement for the NVIDIA profile.

## Service status

```powershell
docker ps --filter name=pocketmind-
```

For profile-aware Compose rendering or lifecycle operations, prefer the repository scripts. The effective NVIDIA files are `docker-compose.yml` plus `docker-compose.nvidia.yml`; native uses `docker-compose.native-ollama.yml`.

## Model inventory and placement

Container profiles:

```powershell
docker exec pocketmind-ollama ollama list
docker exec pocketmind-ollama ollama ps
```

Native profile:

```powershell
ollama list
ollama ps
```

`ollama ps` shows context and CPU/GPU placement. On the reference RTX 3050 laptop, partial CPU/RAM offload is normal. Avoid concurrent large-model requests.

## Model Lab lifecycle

```powershell
pwsh ./scripts/model-lab.ps1 add -Model <exact-tag> -Alias lab-<name> -Profile auto
pwsh ./scripts/model-lab.ps1 list -Profile auto
pwsh ./scripts/model-lab.ps1 test -Alias lab-<name> -Profile auto
pwsh ./scripts/model-lab.ps1 remove -Alias lab-<name> -Profile auto
```

Use `-DeleteWeights` only after confirming no other lab alias uses the physical model. Model Lab refuses to delete production or shared weights.

## Native Ollama on macOS

The native profile uses an Ollama process on the host. `.env` values such as `OLLAMA_CONTEXT_LENGTH` do not reach it. Start it with the intended settings and keep it running:

```bash
OLLAMA_CONTEXT_LENGTH=8192 OLLAMA_KEEP_ALIVE=10m ollama serve
```

Set the same variables in whichever launcher you use (desktop app, service manager, or script), then confirm `ollama list` shows `corp-general` and `corp-ocr` and that `ollama ps` shows context 8192. A process started by hand stops with its session, and LiteLLM then returns `Cannot connect to host host.docker.internal:11434`. Keep the default `127.0.0.1` bind; the profile never broadens it.

## Host monitoring on macOS

The `Local LLM - Host (macOS & CPU)` dashboard reads `node_exporter` on the host through `prometheus/prometheus.native.yml`. Install it bound to localhost only:

```bash
brew install node_exporter
echo "--web.listen-address=127.0.0.1:9100" > /opt/homebrew/etc/node_exporter.args
brew services start node_exporter
```

Verify `http://localhost:9090/targets` shows `host` and `litellm` as up. The default exporter arguments listen on every interface, so do not skip the bind option. Power, temperature, KV-cache, and prefix-cache panels are intentionally absent because those values are not exposed.

## Rotate the LiteLLM master key

The master key is stored in several places that are not refreshed together. Choose a long random value (the prerequisite check rejects only `CHANGE_ME` placeholders, so a weak value such as a common word is accepted; do not use one), then:

1. Update `LITELLM_MASTER_KEY` in the private `.env`.
2. Run `pwsh ./scripts/setup.ps1 -Profile <profile>`. This recreates the services whose definition changed, including Open WebUI, whose container environment (and the API Key Manager that reads it) then holds the new key.
3. Update the key stored in Open WebUI: Admin Panel → Settings → Connections → the LiteLLM connection. Open WebUI keeps the value from its first start and ignores `.env` afterwards. Direct database edits need a backup first.
4. Recreate Prometheus, which mounts the key as a runtime config: `docker compose <profile files> up -d --force-recreate prometheus`.
5. Reset the Grafana admin password in the same way if it changed: `docker exec pocketmind-grafana grafana cli admin reset-admin-password '<new>'`.
6. Run `pwsh ./scripts/verify-stack.ps1 -Profile <profile>`.

Do not change `LITELLM_SALT_KEY` as part of this; it encrypts database-held credentials. Behavior of already-issued virtual keys across a master-key change was not tested.

## Open WebUI settings stored in its database

Open WebUI persists most settings (connections, default user role, task model, sign-up) in its database after first start, so editing `.env` or the container environment later does not change them. Use Admin Panel → Settings. Any direct edit of `webui.db` requires a backup, a transaction, a restart, and verification.

Recommended settings for this stack: Task Model → External Models → `corp-general`; `corp-ocr` Built-in Tools off. Account creation is closed (`enable_signup` false) so administrators add users. Setting the default user role to `user` removes the `pending` wait, but it matters only if sign-up or SSO is later enabled, and then anyone who can reach Open WebUI would receive chat access and could create API keys. Password sign-up validates only the email format: it does not restrict domains and does not verify mailbox ownership. Domain restriction exists for SSO (`OAUTH_ALLOWED_DOMAINS`).

## API Key Manager

Users create their own API keys in Open WebUI with the "API Key Manager" model (see ADR 0004). An administrator installs or updates it:

```powershell
pwsh ./scripts/install-key-manager.ps1 -AdminEmail <admin email> -PublicModels corp-general
```

The script prompts for the admin password (or reads `OPENWEBUI_ADMIN_PASSWORD`), registers the Pipe, and keeps existing Valves when updating. `-PublicModels` grants selected models to every signed-in user and skips models that already have an entry; `-GroupId` limits who sees the key manager. Adjust model list, expiry, rate limits, concurrency, key count, and sync interval in Admin Panel → Functions → API Key Manager → Valves.

Operations:

- A user revokes with `revoke <model>`; an administrator can also delete the key in LiteLLM → Virtual Keys.
- Teams are managed only in LiteLLM (add members by email). `sync` as an administrator mirrors teams to Open WebUI groups and lists keys whose owner left the team; those users run `rotate <model>`.
- Deleting a LiteLLM team deletes its keys, including the `unassigned` team that holds keys of users in no team.
- After every Open WebUI upgrade, create a key in a test chat and confirm it does not appear in the chat title, tags, or follow-ups.
- Users call LiteLLM directly. Before anyone off this host uses a key, publish only `/v1/*` through a TLS proxy and never `/ui`, `/key`, or `/model`.

## Usage and cost comparison

```powershell
pwsh ./scripts/usage-report.ps1 -Days 30
pwsh ./scripts/usage-report.ps1 -Days 30 -HardwareCost <usd> -LifetimeMonths 36 -AvgWatts <watts> -ElectricityPerKwh <usd>
```

The report reads measured token counts from LiteLLM's spend logs and prices the same tokens with commercial prices from LiteLLM's bundled table. Local models have no price, so LiteLLM's own cost views show zero; local cost is computed only from the hardware and power values you supply. Treat the result as a cost comparison, not a quality or latency comparison, and check commercial prices against the provider before deciding.

## Focused restarts

A restart does not apply a changed Compose image/environment definition; use `up -d --no-deps --force-recreate <service>` with the correct profile files for that. For an unchanged running definition:

```powershell
docker restart pocketmind-open-webui
docker restart pocketmind-litellm
docker restart pocketmind-ollama
```

Restart only the affected service. Afterward, wait for health and run at least the smoke test:

```powershell
pwsh ./scripts/smoke-test.ps1 -Profile auto
```

## Logs

```powershell
docker logs --since 15m pocketmind-open-webui
docker logs --since 15m pocketmind-litellm
docker logs --since 15m pocketmind-ollama
docker logs --since 15m pocketmind-postgres
```

Use the error timestamp and inspect the whole request path. A LiteLLM `APIConnectionError` may contain an Ollama 400 response and is not automatically a network failure.

## Resource checks

Windows/NVIDIA host:

```powershell
nvidia-smi
docker system df
```

Container model placement:

```powershell
docker exec pocketmind-ollama ollama ps
```

If memory pressure is high, stop sending requests, wait for `OLLAMA_KEEP_ALIVE`, or stop an unused model with `ollama stop <exact-tag>`. Keep the configured one-model/one-parallel-request limits.

## Temporary public UI

Follow the Quick Tunnel section in the root README. Confirm the tunnel targets Open WebUI only, obtain the current URL from container logs, verify authentication, and remove the tunnel after testing. A Quick Tunnel URL is temporary and must not be treated as production ingress.

## Routine operational checklist

1. Confirm Git working tree and active profile.
2. Run setup without `-Pull`.
3. Run full verification.
4. Check `ollama ps` during a representative request.
5. Check Grafana/Prometheus if latency or GPU placement is unexpected.
6. Confirm no unwanted `lab-*` aliases remain.
7. Check disk use before pulling another model.
8. Keep a recent PostgreSQL/Open WebUI backup before upgrades.
9. On macOS, confirm native Ollama and `node_exporter` are running and `ollama ps` shows context 8192.
10. After an Open WebUI upgrade, repeat the API Key Manager title/follow-up check.

## Rollback principles

- Production model rollback: revert the version-controlled alias/environment documentation, re-pull the previous exact tag, recreate LiteLLM if config changed, and rerun contracts plus smoke/runtime tests.
- Model Lab rollback: remove the `lab-*` alias; omit `-DeleteWeights` until the alias removal is verified.
- Open WebUI metadata rollback: restore from a verified Open WebUI backup or use supported admin APIs/UI. Direct SQLite edits require a backup, schema inspection, transaction, and post-restart verification.
- Image rollback: restore previously tested image pins in `.env`/`.env.example`, recreate the affected services, and verify.

## Emergency shutdown

If public exposure, credential leakage, runaway memory use, or unsafe behavior is suspected:

1. Stop/remove the Quick Tunnel first.
2. Stop request-generating clients.
3. Stop the affected service or the stack with the correct Compose profile.
4. Preserve logs and database/UI backups before destructive cleanup.
5. Rotate leaked credentials and revoke temporary keys.
6. Rebuild and verify locally before restoring access.

Do not delete named volumes as a troubleshooting shortcut. Do not run `docker compose down -v` unless a verified backup exists and permanent state deletion is explicitly intended.
