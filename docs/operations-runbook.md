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
