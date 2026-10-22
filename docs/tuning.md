# Tuning context, GPUs and concurrent workloads

Tune the ignored server `.env`, using the parameterized YAML in this repository. This keeps shared defaults portable and preserves machine-specific choices on Git updates. See [server updates](server-update.md) for the one-time migration from hard-coded YAML. Native Ollama requires equivalent settings in its host launcher, independently of `.env`.

## Settings and tradeoffs

| Variable | Repository default | Meaning and tradeoff |
|---|---|---|
| `OLLAMA_CONTEXT_LENGTH` | `8192` | Default context budget per request. Prompt/history, images, tools and generated output need room; callers/model settings can override it. Larger context increases KV-cache memory and prompt-processing work. |
| `OLLAMA_NUM_PARALLEL` | `1` | Parallel requests per loaded model, subject to runtime/model support and memory. More slots increase capacity but can reduce tokens/sec per user and increase memory use. |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | Maximum resident models, subject to memory. It is not a user count or a guarantee that this many models fit. |
| `OLLAMA_KEEP_ALIVE` | `10m` | Idle residency. Longer avoids repeated loading while occupying memory longer; request-level keep-alive may override it. |
| `OLLAMA_FLASH_ATTENTION` | `false` | Enable supported Flash Attention to improve memory/compute efficiency; verify the model/runtime actually enables it. |
| `OLLAMA_KV_CACHE_TYPE` | `f16` | Cache precision. Keep `f16` initially; quantized caches require compatibility/quality evaluation and can change results. |
| `OLLAMA_SCHED_SPREAD` | `false` | Keep ordinary GPU placement. Enabling spread is not automatically faster and may add communication overhead. |
| `NVIDIA_GPU_COUNT` | `1` | GPU reservation for Ollama and exporter. `all` makes both GPUs available; it does not force each request to use both. |
| `BACKEND_BIND_ADDRESS` | `0.0.0.0` | Exposure, not inference speed. Privacy overrides backend bindings to loopback. |

## Current two-L40S server baseline

The server has approximately 503 GiB host RAM and two 46 GiB L40S GPUs. Keep the configuration already exercised as a baseline, rather than increasing every limit:

```dotenv
OLLAMA_CONTEXT_LENGTH=16384
OLLAMA_KEEP_ALIVE=30m
OLLAMA_MAX_LOADED_MODELS=4
OLLAMA_NUM_PARALLEL=8
OLLAMA_FLASH_ATTENTION=true
OLLAMA_KV_CACHE_TYPE=f16
OLLAMA_SCHED_SPREAD=false
NVIDIA_GPU_COUNT=all
```

This is not a capacity guarantee for four large models at eight simultaneous requests each. Host RAM is not a replacement for GPU VRAM at the same speed. Model weights, KV cache and runtime buffers must fit the GPUs for full GPU placement. Context × concurrency is a major memory multiplier; architecture and cache format matter too.

Earlier server observations showed Qwen 4B fully on GPU at 8K context and later 16K context, with increased resident memory. Two loaded models were placed on different GPUs. Those snapshots demonstrate placement, not sustained multi-user throughput or a fairness guarantee. GPU utilization at 0% between requests is normal; filling idle VRAM does not make inference faster.

## Apply one change at a time

Edit `.env`, then recreate only Ollama using the active file set. Normal NVIDIA + proxy:

```bash
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml up -d --no-deps ollama
docker exec pocketmind-ollama printenv OLLAMA_CONTEXT_LENGTH OLLAMA_NUM_PARALLEL OLLAMA_FLASH_ATTENTION
docker exec pocketmind-ollama nvidia-smi -L
```

When privacy is active, add `-f docker-compose.privacy.yml` last. A plain `restart` does not apply changed environment definitions. Changing GPU exporter reservation also requires recreating `nvidia-exporter`. Recreating Ollama interrupts in-flight work and unloads models.

Send a request for each model you actually use, then inspect:

```bash
docker exec pocketmind-ollama ollama ps
nvidia-smi
docker logs --since 5m --tail 100 pocketmind-ollama
```

An empty `ollama ps` immediately after restart means no model is loaded. Environment inspection confirms the configured default; `ollama ps` after an actual request confirms loaded context/placement for that model. A request-level `num_ctx` or WebUI model parameter can differ from the global default. Test every important alias, not only `default-general`.

## Evaluate capacity

1. Fix a representative prompt/document, output budget, model tag and context. Measure cold load separately from warm requests.
2. Test 1, 2, 4 and 8 simultaneous requests with synthetic data. Record time to first token, completion time, tokens/sec per request, errors and GPU placement/memory. Use [monitoring](monitoring.md) and the [evaluation guide](models/evaluation-guide.md).
3. If queueing dominates while GPU memory has headroom, compare a higher parallel setting. If per-user latency worsens, reduce concurrency or limit admission. Stop increasing on OOM, CPU offload or sustained unacceptable latency.
4. For long chats/Excel, inspect the actual tokens sent. Increase context only after checking prompt size, output/thinking budget and memory under intended concurrency. Use document parsing, selective retrieval or aggregation rather than sending entire workbooks repeatedly.
5. Use API Key Manager/LiteLLM policy for API rates and concurrency; GPU settings do not assign equal resources per user. Check WebUI's shared-credential path separately.

## Privacy and performance

Base telemetry/reporting restrictions do not change model weights, context, parallelism or quantization. The privacy overlay also leaves the Ollama tuning above intact. No before/after benchmark has established an exact performance difference.

Offline mode can fail when embedding/tokenizer/audio caches are missing. Disabling WebUI code execution/interpreter changes tool-based workloads, including some spreadsheet analysis. Ignoring persisted Admin configuration can change task/RAG/provider behavior. These are application behavior changes to validate, not evidence that the model itself is slower. See [privacy preparation](privacy.md), and diagnose response/UI problems in [troubleshooting](troubleshooting.md).
