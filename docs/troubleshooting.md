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
