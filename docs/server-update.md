# Updating a server without losing configuration

Use this procedure for an existing installation. New hosts use the [provisioning guide](provisioning-guide.md). Commands below target Linux/NVIDIA with nginx; CPU omits `docker-compose.nvidia.yml`, and native uses `docker-compose.native-ollama.yml` instead of the Docker inference files.

## What changes and what stays

- Git updates tracked scripts, Compose files, LiteLLM defaults and documentation. Uncommitted server YAML edits can conflict with incoming changes.
- The ignored `.env` stays local. Never copy `.env.example` over it. Add only missing variables, keeping credentials, image pins and machine-specific values.
- `ollama_data` holds downloaded container model weights; `openwebui_data` holds accounts, chats, uploads and installed Functions; `postgres_data` holds LiteLLM keys, teams and DB-backed custom aliases. Monitoring has its own volumes. Native weights stay on the host.
- `up -d` keeps these volumes but can recreate changed containers. Restarting Ollama unloads models; the next request pays a cold-load cost. Changing an image or schema can require migration, so back up first.
- Keep the Compose project name (`pocketmind`) and volume mappings. Do not use `down -v`, volume deletion or a new project name to resolve an update problem.

## 1. Back up and inspect

Schedule a maintenance window. Follow [Backup and restore](backup-and-restore.md) for PostgreSQL and Open WebUI, including quiescing writers. Keep a protected copy of `.env`, local nginx rules and any tracked YAML edits outside the repository. The commands below inspect tracked changes without printing `.env`:

```bash
git status --short
git branch --show-current
git diff --stat
git rev-parse HEAD
```

Record the previous revision, image pins and volume names for rollback. A backup of YAML is not a database backup. Do not paste raw `docker compose config` or `.env` output into tickets: they include secrets.

## 2. Move existing YAML tuning into .env once

On this server, retain the values already tested (example for two L40S GPUs):

```dotenv
OLLAMA_CONTEXT_LENGTH=16384
OLLAMA_KEEP_ALIVE=30m
OLLAMA_MAX_LOADED_MODELS=4
OLLAMA_NUM_PARALLEL=8
OLLAMA_FLASH_ATTENTION=true
OLLAMA_KV_CACHE_TYPE=f16
OLLAMA_SCHED_SPREAD=false
NVIDIA_GPU_COUNT=all
BACKEND_BIND_ADDRESS=0.0.0.0
PROXY_ENABLED=true
PROXY_WEBUI_PORT=8480
PROXY_API_PORT=8481
PRIVACY_MODE=false
```

Edit the existing `.env`, leaving secrets and image overrides intact. These are server choices, not universal defaults; see [Tuning](tuning.md). A variable works only when the deployed YAML references it. Old hard-coded YAML will ignore a new `.env` value.

## 3. Pull and review

From `main`, with a clean tracked working tree:

```bash
git pull --ff-only origin main
git diff --stat ORIG_HEAD HEAD
```

If YAML has local changes, first save a protected copy and resolve them deliberately against the incoming parameterized files. Stop on conflicts; do not run `git reset --hard` or restore the old whole YAML over the new one. Preserve unrelated local changes. If the server is on another deployment branch, update that branch through the approved workflow instead of switching blindly.

Compare variable **names and documented defaults** in `.env.example` with your private settings. Keep `.env` unchanged except for reviewed additions. An existing `OPEN_WEBUI_IMAGE` or other image override keeps its previous version; update image pins only after reviewing compatibility. Shell-exported variables take precedence over `.env`, so remove stale deployment-shell overrides. Changes made only in a developer's working tree are unavailable to the server until published to the branch being pulled.

## 4. Apply the correct file set

For normal serving (`PRIVACY_MODE=false`):

```bash
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml config --quiet
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml up -d
```

For an **already private** deployment, append the privacy file last to both commands:

```bash
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml -f docker-compose.privacy.yml config --quiet
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml -f docker-compose.privacy.yml up -d
```

Raw Compose does not select files from `PRIVACY_MODE` or `PROXY_ENABLED`. Repository `setup.ps1` does. Changing between ordinary and private networking requires stopping/recreating the network with the previous full file set; follow [Privacy activation and maintenance](privacy.md). Do not add the privacy overlay for the first time as a routine update without preparing caches and policy.

Normal model-init pulls the configured initial models when it runs. This may contact the registry even if weights exist. Private model-init checks local weights only. Do not use image `pull`/setup `-Pull` on a disconnected serving host; stage approved images beforehand.

## 5. Apply application changes when required

Git and Compose do not automatically replace an installed Open WebUI Function or every saved Admin setting. For the API Key Manager update:

```powershell
pwsh ./scripts/install-key-manager.ps1 -AdminEmail <admin-email>
```

This preserves existing Valves. Verify `auto_discover_models=true` if new aliases should appear automatically. Keys already issued remain scoped to their original model.

For the initial `corp-general`/`corp-ocr` → `default-general`/`default-ocr` migration, update clients, Task Model and Workspace Models, manual allowlists and key scopes. Configure the initial WebUI defaults with:

```powershell
pwsh ./scripts/configure-open-webui.ps1 -AdminEmail <admin-email>
```

Issue replacement keys for renamed aliases and test them before retiring old entries. Existing custom `lab-*` aliases keep their names. Chat deletion is unnecessary. Review saved model access entries separately: installers may skip entries already present. See [Open WebUI](open-webui.md) and [API access](api-access.md).

## 6. Verify and recover

```bash
docker exec pocketmind-ollama printenv OLLAMA_CONTEXT_LENGTH OLLAMA_KEEP_ALIVE OLLAMA_MAX_LOADED_MODELS OLLAMA_NUM_PARALLEL OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE OLLAMA_SCHED_SPREAD
docker exec pocketmind-ollama nvidia-smi -L
docker ps --filter name=pocketmind-
pwsh ./scripts/verify-stack.ps1 -Profile nvidia
```

On a private deployment also run `python3 ./scripts/verify-privacy.py`. Send a representative chat/API request, then inspect `docker exec pocketmind-ollama ollama ps` to check loaded context and placement. An empty list before the first request is normal. Test one regular user, streaming, and a scoped IDE key; a healthy container alone does not establish these work.

If verification fails, keep incoming traffic paused. Restore the recorded config/image revision and compatible data backup when schema changes require it; see [rollback principles](operations-runbook.md#rollback-principles). Do not delete volumes. Reverting Git alone does not reverse a database migration or a changed Function.
