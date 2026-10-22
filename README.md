# PocketMind - Cross-platform

Local OpenAI-compatible LLM stack for Windows 11, macOS Apple Silicon, and Ubuntu/Linux.

```mermaid
flowchart LR
    Browser[Browser] --> WebUI["Open WebUI<br/>localhost:3000"]
    WebUI --> LiteLLM["LiteLLM API<br/>localhost:4000"]
    LiteLLM --> Profile{Resolved inference profile}
    Profile -->|nvidia or cpu| ContainerOllama["Ollama container<br/>localhost:11434"]
    Profile -->|native| NativeOllama["Native Ollama<br/>host.docker.internal:11434"]
    LiteLLM -->|persistence| PostgreSQL["PostgreSQL<br/>localhost:5432"]
    LiteLLM -->|application metrics| Prometheus["Prometheus<br/>localhost:9090"]
    NvidiaExporter["NVIDIA exporter<br/>nvidia profile only"] -->|GPU metrics| Prometheus
    Prometheus --> Grafana["Grafana<br/>localhost:3001"]
    RemoteUsers["Other machines<br/>(optional)"] -.->|HTTP, only if the proxy is enabled| Nginx["nginx proxy<br/>8480 / 8481"]
    Nginx -->|Open WebUI| WebUI
    Nginx -->|only /v1 inference paths| LiteLLM
```

The default text model is `default-general` (`qwen3:4b-instruct-2507-q4_K_M`). It is a text-only Qwen 3 4B Instruct Q4 model selected for stronger Thai, reasoning, coding, and tool calling than the previous Llama 3.2 3B while remaining practical on a 4 GB laptop GPU through partial CPU/RAM offload. The stack also installs `default-ocr` (`scb10x/typhoon-ocr1.5-3b`), the Typhoon-recommended Ollama build for Thai and English document OCR.

For current architecture, operations, model decisions, security, backup/restore, and troubleshooting knowledge, start with the [Documentation index](docs/README.md). Files under `docs/superpowers/` are historical implementation plans and design snapshots, not the current operational source of truth.

## Support matrix

| Host | Architecture | Recommended profile | Acceleration | Status |
|---|---|---|---|---|
| Windows 11 + Docker Desktop/WSL2 | amd64 | `auto` or `nvidia` | NVIDIA CUDA | Runtime verified on RTX 3050 |
| macOS Sonoma 14+ | Apple Silicon arm64 | `auto` or `native` | Apple Metal via native Ollama | Static contract verified; physical Mac test required |
| Ubuntu 22.04/24.04 + Docker Compose v2 | amd64/arm64 | `auto`, `nvidia`, or `cpu` | NVIDIA or CPU | Static contract verified; physical Linux test required |
| Other current Linux distributions | amd64/arm64 | `cpu` or `native` | CPU or host runtime | Best effort |

The universal PostgreSQL, Ollama, LiteLLM, Open WebUI, Prometheus, and Grafana image digests include both `linux/amd64` and `linux/arm64`. The NVIDIA exporter is amd64-only and is used only by the NVIDIA profile.

## Profiles

| Profile | Inference runtime | GPU telemetry |
|---|---|---|
| `auto` | macOS selects native; Windows/Linux select NVIDIA after a Docker GPU probe, otherwise CPU | Matches selection |
| `nvidia` | Ollama container with NVIDIA GPU reservation | NVIDIA exporter |
| `native` | Ollama running on the host | No NVIDIA target |
| `cpu` | Portable Ollama container without GPU reservation | No NVIDIA target |

Plain `docker compose up -d` is intentionally the portable CPU-safe stack, but use it only after replacing every `CHANGE_ME` value in `.env`. The PowerShell setup path enforces this automatically.

## Common prerequisites

- Docker Desktop or Docker Engine with a current Compose v2 release that supports inline `configs.content`
- PowerShell 7 (`pwsh`) for the portable automation scripts
- At least 8 GB RAM; 16 GB or more is recommended when Docker Desktop and OCR run together
- Several GB of free disk space for images, model files, and volumes; the Typhoon Ollama model currently downloads about 3.2 GB

PowerShell 7 installation: [Microsoft documentation](https://learn.microsoft.com/powershell/scripting/install/installing-powershell). The scripts also remain compatible with Windows PowerShell 5.1.

## Provision a server with one command

On a new host, clone the repository and run one script. It checks the host first, then does every step in the right order, so nothing depends on you running scripts in the correct sequence:

```text
# Linux or macOS
./scripts/provision.sh --AdminEmail you@example.com

# Windows (PowerShell 5.1 or 7)
powershell -ExecutionPolicy Bypass -File .\scripts\provision.ps1 -AdminEmail you@example.com
```

Add `-CheckOnly` (`--CheckOnly` with the shell wrapper) to see what is missing without changing anything. In short it runs the host checks, creates a private `.env` when none exists, then `check-prerequisites.ps1`, `setup.ps1 -Pull`, `verify-stack.ps1`, `configure-open-webui.ps1`, and `install-key-manager.ps1`. Running it again keeps `.env` and the data and changes only what differs. The decisions to make first, the options, the same steps by hand, how to check the result, what to do afterwards, and a checklist are in [docs/provisioning-guide.md](docs/provisioning-guide.md).

**Who may register.** The administrator created from `.env` closes sign-up, so by default only accounts an administrator adds exist, and they get the `user` role at once (`DEFAULT_USER_ROLE=user`). `-EnableSignup` turns self-registration on; with the `user` role that means anyone who can reach Open WebUI can chat and create API keys, there is no email-domain limit, email addresses are not verified, and team attribution by email can be claimed by anyone. Use it only on a network you trust, or put SSO in front instead.

By default it installs nothing: a failed check prints what to install for that operating system. `--InstallPrerequisites` (`-InstallPrerequisites` in PowerShell) installs PowerShell 7 (macOS through Homebrew; Ubuntu, Debian, and RHEL-family Linux through Microsoft's package repository) and Ollama on macOS (Homebrew, kept running by a launchd agent), after showing the commands and asking; it never upgrades what is already installed and never installs Docker or the NVIDIA toolkit. The full run was exercised on macOS only, and the Linux package installs were not run for real; see [docs/server-deployment-checklist.md](docs/server-deployment-checklist.md) for what was and was not verified.

The manual steps below (First-time repository setup and Quick start) do the same thing one script at a time.

## First-time repository setup

Clone the repository, create a private local environment file, and replace every `CHANGE_ME` value before starting the stack:

```powershell
git clone https://github.com/nawariso/PocketMind.git
cd PocketMind
Copy-Item .env.example .env
notepad .env
```

On macOS or Linux, use `cp .env.example .env` and edit the file with your preferred editor. For a new installation also set `WEBUI_ADMIN_EMAIL` and `WEBUI_ADMIN_PASSWORD` before the first start: Open WebUI then creates that administrator and closes sign-up, whereas otherwise the first person who opens it becomes the administrator. `DEFAULT_USER_ROLE=user` (the default) approves other accounts at once; Open WebUI keeps the stored role after the first start, so change it later in Admin Panel -> Settings -> General. The `.env` file is intentionally excluded from Git because it contains credentials. Compose supplies the LiteLLM key to Prometheus as a runtime config without creating a tracked secret file. Docker named volumes hold runtime state and are also local to each Docker host.

## Quick start: start the stack

After installing the common prerequisites and creating `.env`, this command starts the complete stack (`provision.ps1` runs it for you):

```powershell
pwsh ./scripts/setup.ps1 -Profile auto -Pull
```

`setup.ps1` performs the complete startup workflow:

- checks the prerequisites required by the selected profile
- resolves `auto` to `native`, `nvidia`, or `cpu` for the current host
- supplies the LiteLLM Prometheus token as a runtime Compose config
- pulls Docker images and the configured Ollama model when `-Pull` is supplied
- starts the correct Compose services and removes orphaned containers
- waits until every required container reports healthy

The script does not install Docker, PowerShell, GPU drivers, NVIDIA Container Toolkit, or native Ollama. Those host dependencies must be installed first. On macOS Apple Silicon, `auto` selects the `native` profile, so Ollama must already be installed and running; `-Pull` downloads the configured model if it is missing. On Windows and Linux, `auto` selects NVIDIA only after a successful Docker GPU probe and otherwise falls back to CPU.

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

1. Verify the exact Ollama tag and estimate whether its quantized weights plus an 8192-token context fit this machine.
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

For the normal stack setup on Windows PowerShell 5.1, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -Profile auto -Pull
```

After setup finishes, this is the recommended end-to-end validation; it is not required to start the stack:

```powershell
pwsh ./scripts/verify-stack.ps1 -Profile auto
```

On Windows PowerShell 5.1, run the validation with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-stack.ps1 -Profile auto
```

Automatic selection runs a bounded Docker GPU probe. Seeing `nvidia-smi` on the host alone is not considered proof that containers can use the GPU.

## Windows or Linux with NVIDIA

Windows requires Docker Desktop with the WSL2 backend. Ubuntu/Linux requires a working NVIDIA driver and NVIDIA Container Toolkit.

```powershell
pwsh ./scripts/check-prerequisites.ps1 -Profile nvidia
pwsh ./scripts/setup.ps1 -Profile nvidia -Pull
pwsh ./scripts/verify-stack.ps1 -Profile nvidia
```

The effective Compose command is:

```text
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml up -d
```

The NVIDIA exporter listens on port `9835` only inside the Compose network. It is never published to the host.

## macOS Apple Silicon

Docker Desktop for macOS cannot pass the Apple GPU into an ordinary Linux container. Install Ollama natively so it can use Metal:

```powershell
ollama pull qwen3:4b-instruct-2507-q4_K_M
pwsh ./scripts/setup.ps1 -Profile native
pwsh ./scripts/verify-stack.ps1 -Profile native
```

The native profile connects LiteLLM to `http://host.docker.internal:11434`. Setup checks both host access and container-to-host access. It never changes `OLLAMA_HOST` or broadens the Ollama bind address automatically. If the container check fails, review the Ollama and host firewall configuration before exposing any interface.

**Context length and keeping Ollama running.** `OLLAMA_CONTEXT_LENGTH` in `.env` applies only to the Ollama container, so a host Ollama started without it uses a 4096-token default and rejects prompts Open WebUI builds for OCR or longer chats. Start it with the intended values and keep it running, then confirm the CONTEXT column of `ollama ps` shows 8192:

```text
OLLAMA_CONTEXT_LENGTH=8192 OLLAMA_KEEP_ALIVE=10m ollama serve
```

A process started by hand stops with its session; set the same variables in whichever launcher you use. Details are in the operations runbook.

**Recommended Open WebUI setting.** Set Admin Panel → Settings → Interface → Task Model → External Models to `default-general`. Without it, follow-up suggestions, titles, and tags are generated by the model of the current chat; `default-ocr` cannot do that and Open WebUI shows its suggestions one character per line.

The compatibility form still works:

```powershell
pwsh ./scripts/setup.ps1 -NativeOllama
```

## Portable CPU mode

```powershell
pwsh ./scripts/setup.ps1 -Profile cpu -Pull
pwsh ./scripts/verify-stack.ps1 -Profile cpu
```

CPU inference is slower but requires no host GPU tooling. It is also the behavior of plain `docker compose up -d`.

## Service URLs and credentials

| Service | Address |
|---|---|
| Open WebUI | http://localhost:3000 |
| LiteLLM API | http://localhost:4000/v1 |
| LiteLLM Admin | http://localhost:4000/ui |
| Ollama container/host | http://localhost:11434 when applicable |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3001 |
| PostgreSQL | `127.0.0.1:5432` |
| nginx proxy, Open WebUI (optional) | http://localhost:8480, or `http://<host-ip>:8480` when shared |
| nginx proxy, LiteLLM API (optional) | http://localhost:8481/v1, or `http://<host-ip>:8481/v1` when shared |

The nginx proxy exists only when `PROXY_ENABLED=true` in `.env` (see "Shared pilot access with the nginx proxy"). Every other address above binds to `127.0.0.1`; the proxy listens on `0.0.0.0` unless `PROXY_BIND_ADDRESS` says otherwise.

Credentials are the private values you set in `.env` after copying `.env.example`:

```text
LiteLLM admin username: admin
LiteLLM password/API master key: LITELLM_MASTER_KEY from .env
Grafana username: GRAFANA_ADMIN_USER from .env (admin in the example)
Grafana password: GRAFANA_ADMIN_PASSWORD from .env
```

The prerequisite checker refuses to start while any secret still has a `CHANGE_ME` placeholder. Never commit `.env`.

## Open WebUI login

Open `http://localhost:3000`. On a fresh volume, create the first local account and select `default-general` for general text work or `default-ocr` for document images. Open WebUI connects only to LiteLLM; direct Ollama access is disabled.

## Thai and English OCR with Typhoon

`default-ocr` routes to `scb10x/typhoon-ocr1.5-3b`, the on-device Ollama build recommended by the Typhoon OCR 1.5 authors. The exact Hugging Face checkpoint `typhoon-ai/typhoon-ocr1.5-2b` uses Qwen3-VL 2B; the recommended Ollama build uses a quantized Qwen2.5-VL 3B model. This distinction is intentional because the authors warn that third-party GGUF conversions may reduce OCR accuracy.

This is a task-specific OCR model, not a general chat or VQA model. Its Ollama build supports completion and vision but not tool calling. In Open WebUI, keep `Built-in Tools: Off` for `default-ocr`; otherwise Open WebUI can attach a `tools` payload and Ollama will reject the request. Start a new chat, select `default-ocr`, attach one document image, set temperature to `0.1`, and use the model's required prompt:

```text
Extract all text from the image.

Instructions:
- Only return the clean Markdown.
- Do not include any explanation or extra text.
- You must include all information on the page.

Formatting Rules:
- Tables: Render tables using <table>...</table> in clean HTML format.
- Equations: Render equations using LaTeX syntax with inline ($...$) and block ($$...$$).
- Page Numbers: Wrap page numbers in <page_number>...</page_number>.
- Checkboxes: Use ☐ for unchecked and ☑ for checked boxes.
```

Use `default-general` for complex reasoning or ordinary chat. Typhoon OCR can still hallucinate, so compare important output with the source document. Image inputs consume context tokens; if Ollama reports `exceeds the available context size`, increase `OLLAMA_CONTEXT_LENGTH` in the private `.env` and recreate the Ollama container. Larger contexts consume more RAM and KV-cache memory.

## Self-service API keys for Open WebUI users

Pilot users can create their own scoped LiteLLM key without leaving Open WebUI. An administrator installs the "API Key Manager" model once:

```text
pwsh ./scripts/install-key-manager.ps1 -AdminEmail <admin email>
```

The script prompts for the admin password (or reads `OPENWEBUI_ADMIN_PASSWORD`) and registers the model for every signed-in user; add `-GroupId <id>` to limit it to groups. Add `-PublicModels default-general,default-ocr` (comma-separated is fine) to make those models visible to every signed-in user (a model that already has an Open WebUI entry is skipped, so check its access in Admin → Settings → Models). Users select "API Key Manager" and type `models`, `new <model>` (optionally `new <model> as <label>`), `list`, `rotate <alias>`, `revoke <alias>`, or `help`. Each key works for one model, a user may create several keys for the same model (up to 20 in total by default), each key expires, is limited in rate and concurrency by the function's Valves, is shown only once, and is attributed to the LiteLLM team the user belongs to (add members by email in the LiteLLM UI). Teams are managed only in LiteLLM and are mirrored to Open WebUI groups automatically, or immediately when an administrator types `sync`. Users call LiteLLM directly, so a shared pilot should reach it only through the nginx proxy described below, which forwards just the inference paths. See [ADR 0004](docs/decisions/0004-self-service-virtual-keys.md) and [security guidance](docs/security.md).

The function discovers the current LiteLLM model aliases automatically, including new custom models: users can type `models`, then `new <alias>` without an administrator editing `allowed_models`. This offers the master-key catalog for self-service API keys, independently of Open WebUI model visibility; LiteLLM team restrictions still apply. To use a restricted manual list instead, set `auto_discover_models=false` in the function's Valves and maintain `allowed_models`. Existing keys remain limited to their original model. To update a server, copy the updated function source and rerun the installer above; existing Valves are preserved and the new discovery setting defaults to true. No container restart is needed.

## Test the API key

Postman configuration:

```text
POST http://localhost:4000/v1/chat/completions
Authorization: Bearer <LITELLM_MASTER_KEY from .env>
Content-Type: application/json
```

Body:

```json
{
  "model": "default-general",
  "messages": [
    { "role": "user", "content": "Reply with exactly: API_OK" }
  ],
  "max_tokens": 16,
  "temperature": 0
}
```

Create a restricted 30-day virtual key:

```powershell
pwsh ./scripts/create-virtual-key.ps1
```

## PostgreSQL and DBeaver

```text
Host: 127.0.0.1
Port: 5432
Database: litellm
Username: litellm
Password: value of POSTGRES_PASSWORD in .env
```

Another local PostgreSQL instance, including OpenMetadata PostgreSQL, must not occupy port `5432`.

## Monitoring dashboards

Open `http://localhost:3001` and browse the `PocketMind` folder:

- `PocketMind - LiteLLM`: requests, failures, token counters, latency, and provider results
- `Local LLM - GPU & Engine`: NVIDIA hardware plus Ollama/LiteLLM engine metrics
- `Local LLM - Host (macOS & CPU)`: host CPU, unified memory, swap, and load from `node_exporter`, plus LiteLLM engine panels

The NVIDIA row receives data only with the `nvidia` profile. On CPU/native profiles it shows no data rather than fabricated zeros. Fan speed is `N/A` when the GPU driver does not expose it.

Ollama/LiteLLM provides running requests, token throughput, TTFT, and inter-token latency. KV-cache usage, a waiting-request gauge, and prefix-cache hit rate remain explicitly `N/A` because they are vLLM-only semantics. TTFT requires streaming requests (`"stream": true`).

Apple GPU hardware telemetry is not part of this release because Metal counters do not map directly to `nvidia-smi` metrics. For the `native` profile, the host dashboard reads Mac CPU, memory, swap, and load from `node_exporter` running on the host. Install and bind it to localhost only:

```text
brew install node_exporter
echo "--web.listen-address=127.0.0.1:9100" > /opt/homebrew/etc/node_exporter.args
brew services start node_exporter
```

Prometheus scrapes it at `host.docker.internal:9100` (`prometheus/prometheus.native.yml`). Without `node_exporter`, only the host panels are empty; the rest of the stack is unaffected. On Apple Silicon, memory is unified, so sustained swap growth while a model runs indicates memory pressure.

## Operations

Check status using the selected profile:

```powershell
pwsh ./scripts/verify-stack.ps1 -Profile auto
```

Run a benchmark:

```powershell
pwsh ./scripts/benchmark.ps1 -Runs 5
```

Compare measured usage with commercial prices:

```powershell
pwsh ./scripts/usage-report.ps1 -Days 30
```

The report reads token counts recorded by LiteLLM and prices the same tokens with commercial prices from LiteLLM's price table. Local models have no price, so LiteLLM's own cost views stay at zero; add `-HardwareCost`, `-LifetimeMonths`, `-AvgWatts`, and `-ElectricityPerKwh` (USD) to include a local cost computed from your own values. It compares cost only, not quality or latency.

Rotating `LITELLM_MASTER_KEY` or other secrets needs more than editing `.env` because Open WebUI, Prometheus, and Grafana keep their own copies; follow the operations runbook. Choose long random values: the prerequisite check rejects only `CHANGE_ME` placeholders and accepts weak ones.

Stop the CPU/default stack:

```text
docker compose down
```

Stop the NVIDIA stack:

```text
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml down
```

Stop the native stack:

```text
docker compose -f docker-compose.native-ollama.yml down
```

Do not add `-v` unless you intentionally want to delete PostgreSQL, Grafana, Prometheus, Open WebUI, and container Ollama volumes.

## Shared pilot access with the nginx proxy

Every service port binds to `127.0.0.1`, so nobody else on the network can reach the stack directly. For a shared pilot, an optional nginx container (`docker-compose.proxy.yml`) is the single door:

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

Limit who may connect with a git-ignored `nginx/local/*.conf` (`allow <cidr>;` lines and `deny all;`), not with the host firewall: on Linux, ports published by Docker Engine are typically handled by Docker's own iptables rules and can bypass `ufw`, and on Docker Desktop (observed on macOS) nginx sees every client as the VM gateway address, so address rules and per-address rate limits cannot tell clients apart there. The steps and how to see the real client address are in the [operations runbook](docs/operations-runbook.md#shared-pilot-proxy-nginx).

The API port limits each client address to 30 requests per second (burst 60), Open WebUI's sign-in and session endpoints to 2 per second (burst 10) to slow password guessing, and the proxy accepts bodies up to 50 MB, enough for base64 OCR images. Browsers may call the API cross-origin (OPTIONS preflight is allowed). Traffic is not encrypted: passwords and API keys can be read on the network, so use it only on a trusted internal network with test data, never on the internet, and move to HTTPS before real use. Use strong secrets in `.env`, keep sign-up closed, and see ADR 0005 and the security guidance.

When the proxy is enabled, include the overlay in manual commands, for example `docker compose -f docker-compose.native-ollama.yml -f docker-compose.proxy.yml down`.

## Temporary public test with Cloudflare Quick Tunnel

Use a [Cloudflare Quick Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/) to test Open WebUI from another network without buying a public IP, forwarding router ports, or changing PocketMind's localhost-only port bindings. Quick Tunnels are temporary, have no uptime guarantee, and are not suitable for production.

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

## State portability

Configuration is portable; runtime state is host-local:

- named Docker volumes remain on the Docker host where they were created
- native Ollama models remain in that host's Ollama model directory
- a new machine pulls images/models and creates fresh volumes
- migrate PostgreSQL with `pg_dump`/restore, not by copying raw volume directories across operating systems

## Troubleshooting

```powershell
pwsh ./scripts/check-prerequisites.ps1 -Profile auto
docker compose ps
docker compose logs litellm
docker compose logs open-webui
docker compose logs prometheus
```

NVIDIA only:

```powershell
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml logs nvidia-exporter
nvidia-smi
```

Native Ollama:

```powershell
ollama list
ollama ps
```

All published Compose ports bind to `127.0.0.1` only, except the optional nginx proxy, which listens on `0.0.0.0` by default (change `PROXY_BIND_ADDRESS`). Do not expose this POC directly to the Internet; it intentionally omits TLS, SSO, network segmentation, HA, and enterprise secret management. The proxy speaks plain HTTP.

If `PROXY_ENABLED=true` is in `.env`, manual `docker compose` commands need `-f docker-compose.proxy.yml` as well. If PowerShell calls to `localhost` fail with HTTP 500 or 503 while `curl` works, a system proxy agent is intercepting them; see `docs/troubleshooting.md`.

## Validation scope

The repository contains static contracts for Windows, macOS, Linux, amd64, arm64, all Compose profiles, dashboards, and script portability. A platform is described as runtime-verified only after the full verifier runs on physical hardware or an appropriate self-hosted runner. CI configuration rendering does not certify GPU acceleration.

The nginx proxy was exercised on one host (Docker Desktop on macOS, native profile), including binding to `0.0.0.0` and reaching it through the host's own LAN address. It was not tested from another machine, on Linux or Windows, or with the `cpu` and `nvidia` profiles beyond configuration rendering in `tests/proxy-contract.ps1`.

Run the network-dependent multi-architecture image check before changing pinned image digests:

```powershell
pwsh ./tests/image-manifest.ps1
```
