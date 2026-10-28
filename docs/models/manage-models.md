# Managing local models

For an optional automated acquisition/approval/import path, see [governed model delivery](../governance.md). Its current admin demo is synthetic and does not replace the direct Model Lab workflow below.

[Model catalog](catalog.md) records the initial models; [evaluation guide](evaluation-guide.md) covers choosing a model for a workload. Downloading weights and registering an API alias are separate operations. `ollama list` shows physical tags, while Model Lab and `/v1/models` show LiteLLM aliases.

## Model Lab: try another Ollama model without editing config

Model Lab downloads an exact Ollama model tag and registers a separate custom alias through LiteLLM's database-backed model-management API. Production aliases in `litellm/config.yaml` remain unchanged, aliases persist across LiteLLM restarts, and adding or removing an alias does not require a LiteLLM restart.

### Model Lab prerequisites

Before using Model Lab:

- Complete the normal PocketMind setup and keep Ollama, LiteLLM, and PostgreSQL running.
- Configure the private `.env`; the script reads the LiteLLM master key locally and never accepts it as a command-line argument.
- Verify the exact tag on the Ollama registry page. Check download size, quantization, context, modalities, tool support, and license.
- Check available disk, RAM, and VRAM. A successful download proves availability, not acceptable speed or memory fit.
- Use `-Profile auto` unless you intentionally run `cpu`, `native`, or `nvidia`. The profile controls whether the script calls native Ollama or the Ollama container.

### Model Lab command reference

| Action | Required input | Important options | Behavior |
|---|---|---|---|
| `add` | `-Model <exact-tag>` | `-Alias <name>`, `-Profile auto` | Pulls and inspects the model, creates a persistent LiteLLM alias, and verifies discovery. |
| `list` | none | `-Profile auto` | Lists Model Lab aliases, physical models, and deployment IDs. |
| `test` | `-Alias <name>` | `-Prompt`, `-MaxTokens` | Sends one deterministic text chat request and reports latency and output tokens. `-MaxTokens` defaults to `128` and accepts `8`–`2048`. |
| `remove` | `-Alias <name>` | `-DeleteWeights` | Removes the LiteLLM alias; weights are retained unless explicitly requested. |

`-Alias` is optional for `add`; if omitted, the exact physical model name/tag becomes the alias (for example `qwen3:8b`). No prefix is required. Explicit aliases preserve spelling and case, may contain Unicode letters/numbers, dot, underscore, colon, slash, and dash, and must start with a letter or number. Spaces, wildcards, and aliases longer than 128 characters are rejected. The initial aliases `default-general` and `default-ocr` are protected. Database-backed aliases are identified by storage metadata, so existing `lab-...` aliases remain manageable.

Add and download a model:

```powershell
pwsh ./scripts/model-lab.ps1 add -Model qwen3:8b -Alias Qwen3-8B -Profile auto
```

List registered lab aliases:

```powershell
pwsh ./scripts/model-lab.ps1 list -Profile auto
```

Run a timed text test with a larger output budget:

```powershell
pwsh ./scripts/model-lab.ps1 test -Alias Qwen3-8B `
  -Prompt 'อธิบายข้อดีข้อเสียของ local AI แบบสั้น ๆ' `
  -MaxTokens 256 `
  -Profile auto
```

The reported wall-clock rate includes request overhead and may include model load or warm-up time. Run the same test at least twice: treat the first run as cold-start behavior and later runs as warm behavior. Compare answer quality as well as latency.

The built-in `test` action exercises text chat only. It does not prove image input, OCR accuracy, thinking behavior, structured output, or tool calling. Test those capabilities separately with a known fixture and the model's declared capabilities before relying on them.

Remove only the LiteLLM alias and retain downloaded Ollama weights:

```powershell
pwsh ./scripts/model-lab.ps1 remove -Alias Qwen3-8B -Profile auto
```

Remove both the alias and downloaded weights:

```powershell
pwsh ./scripts/model-lab.ps1 remove -Alias Qwen3-8B -DeleteWeights -Profile auto
```

Without `-DeleteWeights`, adding the same physical model again can reuse the local weights. With `-DeleteWeights`, the script refuses to remove a production model or weights still referenced by any other alias.

Windows PowerShell 5.1 uses the same actions with the compatibility invocation form:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\model-lab.ps1 add -Model qwen3:8b -Alias Qwen3-8B -Profile auto
powershell -ExecutionPolicy Bypass -File .\scripts\model-lab.ps1 test -Alias Qwen3-8B -MaxTokens 256 -Profile auto
powershell -ExecutionPolicy Bypass -File .\scripts\model-lab.ps1 remove -Alias Qwen3-8B -Profile auto
```

### Recommended Model Lab workflow

1. Verify the exact Ollama tag and estimate whether its quantized weights plus the configured context and concurrency fit this machine.
2. Run `add` with a unique custom alias. Never reuse `default-general` or `default-ocr` for an experiment.
3. Run `list` to confirm the alias-to-physical-model mapping.
4. Run the same `test` prompt at least twice and record cold and warm latency.
5. Test the actual workload separately: Thai, reasoning, coding, tools, vision, or OCR as applicable.
6. Inspect placement with `docker exec pocketmind-ollama ollama ps` for container profiles or `ollama ps` for the native profile. Avoid concurrent large-model requests on memory-constrained hardware.
7. If the model is not useful, run `remove`; add `-DeleteWeights` only when no other alias needs the same weights.
8. If the model should replace a production alias, update the version-controlled config and normal contracts in a separate reviewed change. Model Lab does not promote a model automatically.

### Open WebUI access

The local CLI can test a custom alias immediately. Open WebUI administrators also see the alias after refreshing the browser. Regular Open WebUI users do not receive access automatically: an administrator must create a Workspace Model that uses the custom alias as its base model, then grant the intended users or `user:*` read access. This separation prevents newly downloaded experimental models from becoming available to every tester without review.

### Model Lab troubleshooting

- **Alias already exists:** run `list`, choose another custom alias, or remove the old alias first.
- **Alias is absent in Open WebUI:** hard-refresh or sign out/in. Admins should see the base alias; regular users need a Workspace Model and explicit read grant.
- **Download succeeds but inference is slow:** inspect `ollama ps` placement, shorten context/history, close other GPU workloads, and compare warm runs. Models larger than VRAM will offload to CPU/RAM.
- **Test times out:** each Model Lab text test has a 300-second request timeout. A timeout usually means the model is too slow, still loading, or under memory pressure; inspect `ollama ps` and runtime logs before retrying.
- **Out of memory or context errors:** stop other model requests, start a new chat, reduce prompt/history, or remove the candidate. Do not raise context blindly because KV-cache memory also grows.
- **Tool or image errors:** confirm the model advertises the capability. Do not send tools to a completion/vision-only model, and do not assume a text model accepts images.
- **Remove keeps disk usage:** this is expected without `-DeleteWeights`; run the explicit deletion form only after confirming the physical model is not shared.
- **Partial add failure:** the script attempts to roll back the database deployment. Run `list` afterward and remove any remaining custom alias before retrying.

The default-alias and deletion guards are protections implemented by `model-lab.ps1`, not server-side LiteLLM authorization rules. Treat the LiteLLM master key as an administrator credential: anyone holding it can call model-management endpoints directly and bypass the script. Never expose that key through Open WebUI, a public tunnel, Postman collections, logs, or source control.


## API and WebUI access after registration

1. Run `list` and `test` above to verify the registered alias.
2. In API Key Manager type `models`, then `new <alias>`. Automatic discovery must be enabled; a key created for another model does not gain access to this alias.
3. In an IDE, use that exact alias and its scoped key with the configured LiteLLM base URL. Some IDEs cache their model list; refresh or enter the alias explicitly.
4. For regular Open WebUI users, create a Workspace Model and grant read access as described above. API discovery and WebUI visibility have separate policies.

See [API access](../api-access.md). On isolated servers, use the [Privacy maintenance procedure](../privacy.md#temporarily-disable-privacy-to-download-and-register-a-model); `add` includes a pull and is not an offline registration command.

## Hugging Face models

A Hugging Face repository is a source of artifacts, not automatically an Ollama-compatible model or a cloud service. Check the model card, license, original publisher, architecture, modalities, tool support, required memory, and exact artifact revision. Prefer the original publisher or an approved conversion with documented provenance; downloads and popularity do not certify safety.

Use an approved GGUF build only when its architecture and required files are supported by the installed Ollama version. An arbitrary Transformers/safetensors checkpoint cannot be loaded by this stack just by changing an alias. Unsupported architectures require a separately reviewed serving backend and LiteLLM route, outside the current Ollama-only deployment.

For a compatible Hugging Face GGUF repository, Ollama supports tags of the form `hf.co/<publisher>/<repository>:<quantization>`. Verify the exact repository and quantization before using that string as Model Lab's `-Model`; use `-Alias` for the API name. This still downloads artifacts, so prepare them during the approved online window. Confirm inference is local with `ollama ps` and the privacy verifier, and record artifact hashes/revisions in the approval record.

Model scans are supplementary: verify a scanner supports the actual file format (do not assume a pickle/safetensors scanner inspects GGUF), scan images/dependencies, and avoid unreviewed remote code, Functions and Tools. See [security](../security.md) and [privacy boundaries](../privacy.md).

References: [Ollama GGUF integration](https://huggingface.co/docs/hub/ollama), [Ollama import formats](https://docs.ollama.com/import).

## Rename an existing model

Use the [compatibility rename script](rename-models.md) to add a new API alias and update WebUI display names while keeping existing model IDs, client aliases and key scopes. Do not delete/recreate a model simply to change its display name.
