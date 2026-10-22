# Getting started

For a new organization server, start with the [provisioning guide](provisioning-guide.md). For an existing server use [Updating a server](server-update.md); do not repeat first-install environment copying.

## Support matrix

For organizational data, see [local data and privacy controls](privacy.md). Base defaults disable Ollama cloud features, optional reporting and remote integrations; they still allow bootstrap downloads. After preparing approved models/caches, `PRIVACY_MODE=true` (Docker CPU/NVIDIA, with the proxy enabled) adds offline settings and an internal backend network. Activation requires network recreation/downtime. Host/nginx/client egress policy and HTTPS remain infrastructure requirements; this is not a no-leak guarantee.

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

Add `-CheckOnly` (`--CheckOnly` with the shell wrapper) to see what is missing without changing anything. In short it runs the host checks, creates a private `.env` when none exists, then `check-prerequisites.ps1`, `setup.ps1 -Pull`, `verify-stack.ps1`, `configure-open-webui.ps1`, and `install-key-manager.ps1`. Running it again keeps `.env` and the data and changes only what differs. The decisions to make first, the options, the same steps by hand, how to check the result, what to do afterwards, and a checklist are in [docs/provisioning-guide.md](provisioning-guide.md).

**Who may register.** The administrator created from `.env` closes sign-up, so by default only accounts an administrator adds exist, and they get the `user` role at once (`DEFAULT_USER_ROLE=user`). `-EnableSignup` turns self-registration on; with the `user` role that means anyone who can reach Open WebUI can chat and create API keys, there is no email-domain limit, email addresses are not verified, and team attribution by email can be claimed by anyone. Use it only on a network you trust, or put SSO in front instead.

By default it installs nothing: a failed check prints what to install for that operating system. `--InstallPrerequisites` (`-InstallPrerequisites` in PowerShell) installs PowerShell 7 (macOS through Homebrew; Ubuntu, Debian, and RHEL-family Linux through Microsoft's package repository) and Ollama on macOS (Homebrew, kept running by a launchd agent), after showing the commands and asking; it never upgrades what is already installed and never installs Docker or the NVIDIA toolkit. The full run was exercised on macOS only, and the Linux package installs were not run for real; see [docs/server-deployment-checklist.md](server-deployment-checklist.md) for what was and was not verified.

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
ollama pull scb10x/typhoon-ocr1.5-3b
pwsh ./scripts/setup.ps1 -Profile native
pwsh ./scripts/verify-stack.ps1 -Profile native
```

The native profile connects LiteLLM to `http://host.docker.internal:11434`. Setup checks both host access and container-to-host access. It never changes `OLLAMA_HOST` or broadens the Ollama bind address automatically. If the container check fails, review the Ollama and host firewall configuration before exposing any interface.

**Context length and keeping Ollama running.** `OLLAMA_CONTEXT_LENGTH` in `.env` applies only to the Ollama container, so a host Ollama started without it uses its runtime/model default, which may be too small for OCR or longer chats. Start it with the intended values and keep it running, then confirm the CONTEXT column of `ollama ps` shows 8192:

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


## State portability

Configuration is portable; runtime state is host-local:

- named Docker volumes remain on the Docker host where they were created
- native Ollama models remain in that host's Ollama model directory
- a new machine pulls images/models and creates fresh volumes
- migrate PostgreSQL with `pg_dump`/restore, not by copying raw volume directories across operating systems

## Validation scope

The repository contains static contracts for Windows, macOS, Linux, amd64, arm64, all Compose profiles, dashboards, and script portability. A platform is described as runtime-verified only after the full verifier runs on physical hardware or an appropriate self-hosted runner. CI configuration rendering does not certify GPU acceleration.

The nginx proxy was exercised on one host (Docker Desktop on macOS, native profile), including binding to `0.0.0.0` and reaching it through the host's own LAN address. It was not tested from another machine, on Linux or Windows, or with the `cpu` and `nvidia` profiles beyond configuration rendering in `tests/proxy-contract.ps1`.

Run the network-dependent multi-architecture image check before changing pinned image digests:

```powershell
pwsh ./tests/image-manifest.ps1
```
