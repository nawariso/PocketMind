# Cross-Platform Local LLM Portability Design

Date: 2026-08-12
Status: Proposed

## Goal

Make this repository deployable for evaluation on heterogeneous developer machines while preserving one application contract:

- Open WebUI at `http://localhost:3000`
- LiteLLM OpenAI-compatible API at `http://localhost:4000/v1`
- model alias `corp-general`
- PostgreSQL at `127.0.0.1:5432`
- Prometheus at `http://localhost:9090`
- Grafana at `http://localhost:3001`
- no host-published port reachable outside `127.0.0.1`

The system guarantees portable core services. Inference acceleration and hardware telemetry are selected according to the operating system and available hardware rather than pretending every platform has NVIDIA semantics.

## Support tiers

### Tier 1

- Windows 11, x86-64, Docker Desktop with WSL2
- macOS Sonoma 14 or newer, Apple Silicon arm64, Docker Desktop
- Ubuntu 22.04 or 24.04, x86-64 or arm64, Docker Engine and Compose v2

### Tier 2

- Other current Linux distributions with Docker Engine, Compose v2, and either x86-64 or arm64
- CPU-only operation on Tier 1 and Tier 2 platforms

BSD, mobile operating systems, Kubernetes, AMD-specific container acceleration, and identical hardware metrics across vendors are outside the first portability release.

## Runtime profiles

The launcher exposes explicit profiles and an automatic selection mode:

| Profile | Intended host | Inference | Hardware telemetry |
|---|---|---|---|
| `nvidia` | Windows or Linux with working NVIDIA container access | Ollama container with NVIDIA reservation | NVIDIA exporter |
| `native` | macOS Apple Silicon or a host-managed Ollama installation | Native Ollama through `host.docker.internal:11434` | No NVIDIA exporter |
| `cpu` | Any supported host | Ollama container without a GPU reservation | No GPU exporter |
| `auto` | Default | macOS selects `native`; Windows/Linux select `nvidia` only after an NVIDIA container probe succeeds, otherwise `cpu` | Matches selected profile |

Automatic detection never treats the presence of `nvidia-smi` alone as proof that containers can use the GPU. It must run a bounded Docker GPU probe. If the probe fails, setup reports the reason and chooses `cpu`; it does not silently claim GPU acceleration.

The existing `-NativeOllama` switch remains as a compatibility alias for `-Profile native`.

## Compose structure

Keep root-level Compose files so relative bind mounts continue to resolve from the repository root.

### `docker-compose.yml`

Portable default stack:

- PostgreSQL
- Ollama without a GPU reservation
- model initialization
- LiteLLM
- Open WebUI
- Prometheus using LiteLLM-only scrape configuration
- Grafana

Running plain `docker compose up -d` therefore works as a CPU-safe fallback on every supported Docker host.

### `docker-compose.nvidia.yml`

Overlay for the `nvidia` profile:

- adds the NVIDIA device reservation to Ollama
- adds `nvidia-exporter` with its immutable image digest
- changes Prometheus to the NVIDIA-enabled scrape configuration
- makes Prometheus wait for the exporter health check

It never publishes exporter port `9835` to the host.

### `docker-compose.native-ollama.yml`

Complete host-Ollama stack retained for clarity and safe service removal:

- no Ollama or model-init container
- no NVIDIA exporter
- LiteLLM uses `http://host.docker.internal:11434`
- adds `host.docker.internal:host-gateway` compatibility for native Linux Docker
- Prometheus uses the LiteLLM-only scrape configuration

Native setup requires the model to be present on the host. It checks `ollama list`; if the model is missing, `-Pull` downloads `llama3.2:3b`, while setup without `-Pull` stops and prints the exact `ollama pull` command.

## Prometheus and Grafana behavior

Create two Prometheus configurations:

- `prometheus/prometheus.yml`: LiteLLM only, used by `cpu` and `native`
- `prometheus/prometheus.nvidia.yml`: LiteLLM plus `nvidia_gpu`, used by `nvidia`

The existing LiteLLM dashboard remains universal. The combined GPU and engine dashboard remains provisioned on all profiles because its engine row is useful everywhere; its NVIDIA row clearly states that it requires the `nvidia` profile and shows no data rather than zero on other profiles.

The following metrics remain truthful and universal through LiteLLM:

- running requests
- token throughput
- time to first token for streaming requests
- inter-token latency

The following remain explicitly unavailable in the Ollama architecture:

- vLLM KV-cache usage
- vLLM waiting-request gauge
- vLLM prefix-cache hit rate

Apple GPU telemetry is a separate future feature because Apple Metal counters do not map one-to-one to `nvidia-smi` metrics and commonly require host-level privileges.

## Cross-platform command layer

PowerShell 7 (`pwsh`) is the standard automation runtime across Tier 1 platforms. Windows PowerShell 5.1 compatibility is preserved for the existing Windows host. Scripts must use APIs and syntax available in both Windows PowerShell 5.1 and PowerShell 7 unless an OS-specific branch is unavoidable.

Required changes:

- replace `curl.exe` status checks with `Invoke-WebRequest` or `Invoke-RestMethod`
- remove Windows device name `NUL`
- avoid Windows-only paths, WSL commands, and `.exe` suffixes in executable checks
- detect `$IsWindows`, `$IsMacOS`, `$IsLinux`, and process architecture
- centralize profile and Compose-file selection in `scripts/common.ps1`
- make setup, smoke test, benchmark, key creation, and verification use the selected profile consistently
- print actionable errors containing the selected OS, architecture, and profile

README examples use `pwsh` for portable commands and document `powershell` as a supported Windows-only alternative. Users may also run direct Docker Compose commands without PowerShell.

## Native Ollama connectivity and security

Setup verifies two boundaries separately:

1. host access to `http://localhost:11434/api/tags`
2. container access to `http://host.docker.internal:11434/api/tags`

It never automatically changes `OLLAMA_HOST` or exposes Ollama to the LAN. If Docker Desktop cannot reach the default host binding, setup stops with platform-specific instructions. Any broader bind address requires an explicit user decision because it changes the localhost-only security contract.

All Compose-published ports remain explicitly bound to `127.0.0.1`. The NVIDIA exporter has no published host port.

## Image architecture contract

Every image used by `cpu` and `native` profiles must publish both `linux/amd64` and `linux/arm64` manifests. The currently pinned PostgreSQL, Ollama, LiteLLM, Open WebUI, Prometheus, and Grafana digests satisfy this condition.

The NVIDIA exporter may remain amd64-only because the `nvidia` profile is initially supported only on x86-64 Windows and Linux hosts. Profile selection rejects `nvidia` on arm64 with a clear message rather than allowing emulation.

## State portability

Repository configuration is portable; local runtime state is not automatically portable.

- Docker named volumes stay on the originating Docker host.
- Native Ollama models stay in the host's Ollama model directory.
- Moving to another machine creates fresh volumes and requires pulling the model again.
- Database migration requires an explicit PostgreSQL dump and restore workflow; copying raw Docker volume directories between operating systems is unsupported.

No existing Windows volumes are deleted or migrated by this work.

## Tests and validation

### Static contract tests

Run on Windows, macOS, and Linux with PowerShell 7:

- render each supported Compose combination
- assert every published port binds to `127.0.0.1`
- assert only the NVIDIA overlay contains NVIDIA device reservations and exporter service
- assert the base and native Prometheus configurations do not contain an NVIDIA target
- assert the NVIDIA configuration contains exactly one NVIDIA target
- validate Grafana dashboard JSON and required panel semantics
- reject invalid profile/architecture combinations
- scan scripts for `curl.exe`, `NUL`, and Windows-only executable assumptions

### Image manifest test

A separate network-dependent test verifies `linux/amd64` and `linux/arm64` on every universal image digest. It is not part of fast offline configuration tests.

### Runtime tests

- Current Windows NVIDIA host: full stack, GPU exporter, inference, authentication, PostgreSQL host access, Grafana provisioning, and Prometheus samples
- CPU profile: full inference path without NVIDIA devices or target
- macOS Apple Silicon: native Ollama Metal placement plus full core stack
- Ubuntu: CPU profile in CI; NVIDIA profile on a self-hosted NVIDIA runner

GitHub-hosted runners can validate scripts and configuration on a Windows/macOS/Linux matrix. Real GPU acceleration is only claimed after a physical or self-hosted machine passes runtime verification.

## Documentation

Replace the Windows-only linear README with:

- support matrix and limitations
- common prerequisites
- one quick-start section per profile
- profile selection and override instructions
- platform-specific Ollama setup
- dashboard availability by profile
- troubleshooting keyed by OS/profile
- state migration warning
- commands using `pwsh`

## Acceptance criteria

1. Plain `docker compose up -d` is a portable CPU-safe stack.
2. `pwsh ./scripts/setup.ps1 -Profile auto` chooses a valid profile on every Tier 1 OS.
3. Existing `-NativeOllama` callers continue to work.
4. Windows/Linux NVIDIA profile retains GPU inference and NVIDIA dashboard metrics.
5. macOS native profile uses host Ollama and never attempts NVIDIA setup.
6. CPU/native Prometheus has no permanently down NVIDIA target.
7. All host ports remain localhost-only.
8. The API alias, URLs, credentials flow, and persisted service data contract remain unchanged.
9. Tests distinguish static compatibility from runtime hardware certification.

## Rollout order

1. Make tests express profile and cross-platform contracts.
2. Extract NVIDIA functionality into its overlay and split Prometheus configuration.
3. Refactor PowerShell scripts around a common profile abstraction.
4. Update runtime verifier for profile-specific expectations.
5. Rewrite README around the support matrix and quick starts.
6. Verify Windows NVIDIA and CPU profiles locally.
7. Add CI configuration for static Windows/macOS/Linux validation.
8. Record macOS and Ubuntu physical test results when those hosts are available.
