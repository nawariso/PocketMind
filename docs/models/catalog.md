# PocketMind Model Catalog

This is the current internal registry of production and materially evaluated models. Exact identifiers are contracts; do not silently substitute similarly named tags.

## Production

| Alias | Exact physical model | Role | Declared capabilities | Configured context | Quantization | Status |
|---|---|---|---|---:|---|---|
| `corp-general` | `qwen3:4b-instruct-2507-q4_K_M` | General Thai/text, reasoning, coding, tools | completion, tools, thinking | 8192 | Q4_K_M | Production |
| `corp-ocr` | `scb10x/typhoon-ocr1.5-3b` | Thai/English document OCR | completion, vision; no tools | 8192 | Q4_K_M | Production |

## `corp-general`

- Physical model: `qwen3:4b-instruct-2507-q4_K_M`
- Parameters observed: 4.0B
- Download size observed: about 2.5 GB
- Installed-model `ollama show` reports native context 262144; PocketMind intentionally configures 8192.
- Reference placement at 8192 on RTX 3050 Laptop 4 GB: approximately 37% CPU / 63% GPU.
- Observed generation: approximately 13.5–17.7 eval tokens/s in the benchmark session.
- Tool call and Thai reasoning passed through the `corp-general` LiteLLM alias.
- Use Thinking selectively; ordinary requests should prioritize latency.

## `corp-ocr`

- Physical model: `scb10x/typhoon-ocr1.5-3b`
- Ollama architecture observed: qwen25vl; parameters 3.8B; quantization Q4_K_M.
- Purpose: constrained document transcription, not general chat or free-form VQA.
- Required Open WebUI capability metadata: `vision=true`, `builtin_tools=false`.
- Recommended temperature: 0.1.
- Use the extraction prompt documented in the root README.
- Human-review important output. A successful fixture does not make generative OCR deterministic.

## Evaluated and Removed

| Model | Status | Material observations | Decision |
|---|---|---|---|
| `llama3.2:3b` | Removed | Fast at roughly 35–40 tokens/s; weaker/less reliable explanation quality in the coding comparison | Replaced by Qwen 3 4B |
| `qwen3.5:4b` | Removed after benchmark | Strong output but multimodal weight overhead; observed about 54% CPU / 46% GPU and 8.9–12.1 tokens/s | Qwen 3 text-only was faster/better fit |
| `gemma4:12b` | Removed | Exact tag is preserved in repository history and still resolves in the Ollama registry; about 7.6 GB; heavy CPU/RAM offload; one text run about 82.2 s; OCR quality did not meet user needs | Replaced with dedicated Typhoon OCR |
| `gemma3:12b` | Removed before adoption | Different model from requested `gemma4:12b` | Exact-ID correction |

## Experimental models

Model Lab aliases use `lab-*` and live in LiteLLM's database. They do not become cataloged production models until benchmarked, reviewed, and promoted through version-controlled config. Temporary experiments do not belong in this catalog unless their result prevents repeated work or informs a decision.

## Update checklist

When changing production models, update together:

1. `litellm/config.yaml` exact physical mapping;
2. `.env.example`/setup pull behavior;
3. configuration contracts and smoke/runtime tests;
4. Open WebUI capability/access metadata when relevant;
5. this catalog and benchmark log;
6. the relevant ADR if the decision changes materially.
