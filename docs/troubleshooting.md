# PocketMind Troubleshooting

Diagnose from the user-facing symptom through Open WebUI → LiteLLM → Ollama. Preserve logs and state before destructive actions.

## First checks

```powershell
docker ps --filter name=pocketmind-
pwsh ./scripts/smoke-test.ps1 -Profile auto
docker exec pocketmind-ollama ollama list
docker exec pocketmind-ollama ollama ps
```

Then inspect timestamp-matched logs:

```powershell
docker logs --since 15m pocketmind-open-webui
docker logs --since 15m pocketmind-litellm
docker logs --since 15m pocketmind-ollama
```

## Open WebUI does not show a production model

Likely causes: stale browser session/cache, user role is pending, model inactive, or missing read grant.

1. Confirm LiteLLM `/v1/models` lists the alias.
2. Confirm the Open WebUI account role is `user` or `admin`.
3. Confirm the Workspace Model is active and has the intended read grant (`user:*` only when appropriate).
4. Sign out/in and hard-refresh.

## Regular user does not see a Model Lab alias

This is expected. Admins see the DB-backed base alias; regular users need an administrator-created Workspace Model using the `lab-*` base and an explicit read grant.

## Typhoon reports `does not support tools`

Cause: a request included tool definitions, but `scb10x/typhoon-ocr1.5-3b` supports completion and vision, not tools.

Resolution:

- keep `corp-ocr` metadata at `vision=true` and `builtin_tools=false`;
- disable attached/global tools for that OCR chat;
- start a new chat and retry;
- verify a no-tools image request independently.

Do not enable broad parameter dropping as a substitute for correct per-model capabilities.

## `request ... exceeds the available context size`

Image tokens, system prompt, history, and tool schemas count toward context. The configured default is 8192 because a real Open WebUI OCR request exceeded 4096.

- start a new chat;
- remove unnecessary history/tools/files;
- resize/compress the image;
- keep Thinking off for OCR;
- increase context only after checking RAM/KV-cache pressure and recreating Ollama.

**Native profile:** `OLLAMA_CONTEXT_LENGTH` in `.env` is applied only to the Ollama container. A host Ollama started without it uses its own default of 4096 and fails with `n_ctx: 4096` even though `.env` says 8192. Start it as `OLLAMA_CONTEXT_LENGTH=8192 OLLAMA_KEEP_ALIVE=10m ollama serve` (or set the same variables in whichever launcher you use) and confirm the CONTEXT column of `ollama ps` shows 8192.

## OCR output is wrong or incomplete

- Confirm `corp-ocr`, not `corp-general`, is selected.
- Use the documented Typhoon extraction prompt and temperature 0.1.
- Attach one clear document image.
- Keep Built-in Tools off.
- Compare output to the source; generative OCR can hallucinate.
- Test a known fixture to separate model quality from image quality.

## LiteLLM returns 500/APIConnectionError

Read the nested provider message. Common causes include Ollama 400 responses, unsupported tools, unavailable model weights, context overflow, or Ollama startup/OOM. Confirm the exact alias mapping and physical tag before treating it as networking.

## Inference is slow

```powershell
docker exec pocketmind-ollama ollama ps
nvidia-smi
```

Partial CPU/GPU placement is expected on 4 GB VRAM. Compare cold and warm runs, close competing GPU workloads, avoid concurrent heavy requests, and reduce output/context when appropriate. A larger model may technically load but remain operationally unsuitable.

## Follow-up suggestions appear one character per line

Cause: Open WebUI had no Task Model, so follow-up, title, and tag generation used the model of the current chat. `corp-ocr` is an OCR model and cannot follow general instructions; it returned one string where Open WebUI expects a list, so each character became its own suggestion. Chats made before the fix stored `followUps` as a string; chats made after it stored a list of 4–5 questions.

Fix: Admin Panel → Settings → Interface → Task Model → External Models → `corp-general`, or turn off Follow Up Generation. The task model is loaded in addition to the chat model, which costs memory on a small host. The change affects new messages only.

## Open WebUI shows no models, or LiteLLM logs `Invalid proxy server token`, after changing `LITELLM_MASTER_KEY`

Cause: Open WebUI stores its connection settings in its database on first start and ignores a changed value in `.env`. Prometheus holds the key in a mounted runtime config and is not recreated by `setup.ps1` when its definition is unchanged. Grafana reads its admin password only when its volume is first created.

Follow "Rotate the LiteLLM master key" in the operations runbook. To confirm, compare the failing token hash in the LiteLLM log with the hash of the current key; they differ.

## A Grafana dashboard shows "An unexpected error happened"

Cause seen in practice: a panel used a field color mode that Grafana 12.1 does not know (`continuous-YlOrRd`; the valid name is `continuous-YlRd`). The error appears only once the panel has data, so a dashboard that looked fine without data can fail when data arrives. The browser console reports `"continuous-YlOrRd" not found`.

Use `palette-classic` or a valid continuous mode. The host dashboard has a contract-test guard. The NVIDIA `Power Draw` panel in `gpu-engine-overview.json` still uses the invalid mode; this was found but not tested on an NVIDIA host.

## Host dashboard has no data

The `Local LLM - Host (macOS & CPU)` dashboard reads `node_exporter` on the host.

```bash
curl -s http://127.0.0.1:9100/metrics | head -3
brew services list | grep node_exporter
```

Also check that the Prometheus target `host` is `up` at `http://localhost:9090/targets`. The exporter must listen on `127.0.0.1:9100`; Docker Desktop reaches it as `host.docker.internal:9100`. Engine panels need requests in the last minutes and stay empty while the stack is idle. Power and temperature have no panel because macOS does not expose them to `node_exporter`.

## LiteLLM returns `Cannot connect to host host.docker.internal:11434`

The native Ollama process is not running. Start it with the context and keep-alive settings from the runbook, then confirm `ollama list` shows both production models; pull any that are missing. A process started by hand ends when its terminal or session ends.

## API Key Manager problems

- **Users do not see "API Key Manager" or `corp-general`:** Open WebUI hides models from non-admin users until an access grant exists. Re-run `scripts/install-key-manager.ps1` with `-PublicModels`, and check each model's access in Admin Panel → Settings → Models.
- **"Please wait N seconds":** the per-user cooldown on create, rotate, and revoke; wait and retry.
- **A key returns 401 after a team was deleted:** deleting a LiteLLM team deletes every key attributed to it. Ask the user to run `new <model>` again.
- **Title or follow-up errors in the Open WebUI log while using the Pipe:** expected on Open WebUI 0.11.4; those tasks do not run for a Pipe, which also keeps the key out of titles.
- **A user is not in the expected team:** teams come from LiteLLM and match on the account email. Add the member by email in LiteLLM, then run `sync` as an administrator; existing keys keep their team until `rotate`.

## NVIDIA profile does not use GPU

- Run `nvidia-smi` on the host.
- Verify Docker GPU access, not only host access.
- Run `pwsh ./scripts/check-prerequisites.ps1 -Profile nvidia`.
- Confirm the NVIDIA Compose overlay is active.
- Run a representative inference, then inspect `ollama ps`.
- Check the exporter and Prometheus target if dashboards have no data.

## Model Lab alias already exists or remains after failure

```powershell
pwsh ./scripts/model-lab.ps1 list -Profile auto
pwsh ./scripts/model-lab.ps1 remove -Alias lab-<name> -Profile auto
```

The add flow attempts rollback if discovery verification fails, but always run `list` after an interrupted operation. Do not use production aliases for experiments.

## Model Lab test times out

The text test timeout is 300 seconds. Inspect model loading and memory placement. Retry once after warm-up only if the system is healthy; otherwise remove the candidate or choose a smaller quant/model.

## Removing a lab alias does not free disk

Default `remove` preserves Ollama weights. Use `-DeleteWeights` only when the model is not production and no other lab alias shares it. Confirm with `ollama list` and `docker system df`.

## Quick Tunnel URL fails

Quick Tunnel URLs are temporary. Confirm the container is running, inspect current logs for the active URL, verify Open WebUI locally, and create a new temporary tunnel if needed. Never assume an old URL remains valid.

## Disk pressure

Check Docker and model storage before pulls. Remove unused Model Lab aliases/weights deliberately, prune only known-safe Docker cache, and preserve named volumes. Do not use `docker compose down -v` as cleanup.

## When to restore

Restore only for confirmed state corruption, accidental deletion, or migration—not as the first troubleshooting step. Follow `backup-and-restore.md`; restore operations can permanently replace current users, chats, grants, models, or keys.
