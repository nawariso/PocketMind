# Cross-Platform Local LLM Portability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the same Local LLM API and UI stack deployable on Windows, macOS Apple Silicon, and Ubuntu/Linux through CPU, native-Ollama, and NVIDIA runtime profiles.

**Architecture:** `docker-compose.yml` becomes the portable CPU-safe default. A new NVIDIA overlay adds GPU reservations, exporter, and NVIDIA Prometheus scraping, while the native-Ollama Compose file connects the universal core stack to host Ollama. A shared PowerShell profile abstraction selects Compose files and platform-specific verification without changing the public API contract.

**Tech Stack:** Docker Compose v2, Ollama, LiteLLM, PostgreSQL, Prometheus, Grafana, Windows PowerShell 5.1, PowerShell 7, GitHub Actions.

## Global Constraints

- Tier 1: Windows 11 x86-64, macOS Sonoma 14+ Apple Silicon, Ubuntu 22.04/24.04 x86-64 or arm64.
- Preserve `corp-general`, localhost URLs, credentials flow, and named service volumes.
- Every published port must bind explicitly to `127.0.0.1`.
- The NVIDIA exporter must never publish port `9835` to the host.
- Default `docker compose up -d` must be CPU-safe and contain no NVIDIA reservation.
- macOS must use native Ollama for Metal acceleration; it must never enter the NVIDIA profile automatically.
- CPU and native Prometheus configurations must have no NVIDIA scrape target.
- Windows PowerShell 5.1 compatibility must remain while macOS/Linux use PowerShell 7.
- Existing `-NativeOllama` remains a compatibility alias for `-Profile native`.
- Do not delete or migrate any existing volume.
- This workspace is not a Git repository, so commit steps are intentionally omitted.

---

### Task 1: Define profile and Compose contracts with failing tests

**Files:**
- Create: `tests/profile-contract.ps1`
- Modify: `tests/config-contract.ps1`
- Test: `tests/profile-contract.ps1`
- Test: `tests/config-contract.ps1`

**Interfaces:**
- Consumes: `scripts/common.ps1`, all Compose files, and Prometheus YAML files.
- Produces: executable contracts for `Resolve-PocProfile`, `Get-PocComposeFiles`, portable Compose composition, localhost binding, and scrape-target isolation.

- [ ] **Step 1: Create the failing pure profile contract**

Create `tests/profile-contract.ps1`, dot-source `scripts/common.ps1`, collect failures, and assert these exact outcomes without invoking live hardware discovery:

```powershell
Resolve-PocProfile -RequestedProfile auto -HostOs macos -Architecture arm64 -DockerNvidiaAvailable $false
# native

Resolve-PocProfile -RequestedProfile auto -HostOs windows -Architecture amd64 -DockerNvidiaAvailable $true
# nvidia

Resolve-PocProfile -RequestedProfile auto -HostOs linux -Architecture arm64 -DockerNvidiaAvailable $false
# cpu

Resolve-PocProfile -RequestedProfile cpu -HostOs windows -Architecture amd64 -DockerNvidiaAvailable $true
# cpu
```

Assert `Resolve-PocProfile -RequestedProfile nvidia -HostOs macos -Architecture arm64 -DockerNvidiaAvailable $false` throws. Assert Compose basenames are:

```text
cpu:     docker-compose.yml
nvidia:  docker-compose.yml, docker-compose.nvidia.yml
native:  docker-compose.native-ollama.yml
```

- [ ] **Step 2: Change the configuration contract to the target composition**

Add required files:

```text
docker-compose.nvidia.yml
prometheus/prometheus.nvidia.yml
tests/profile-contract.ps1
```

Render these exact combinations:

```powershell
docker compose -f docker-compose.yml config --format json
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml config --format json
docker compose -f docker-compose.native-ollama.yml config --format json
```

Assert:

- CPU contains `ollama` and `model-init`, but no `nvidia-exporter` and no service device reservations.
- NVIDIA contains `ollama`, `model-init`, and `nvidia-exporter`; Ollama and exporter each reserve one NVIDIA GPU; exporter has no `ports` property.
- Native contains neither `ollama`, `model-init`, nor `nvidia-exporter`; LiteLLM points at `http://host.docker.internal:11434` and defines `host.docker.internal:host-gateway`.
- all three publish PostgreSQL exactly as `127.0.0.1:5432:5432` and every other published port is loopback-only.
- `prometheus/prometheus.yml` contains `litellm` but not `nvidia_gpu` or `nvidia-exporter:9835`.
- `prometheus/prometheus.nvidia.yml` contains both jobs and exactly one `nvidia-exporter:9835` target with a five-second scrape interval.

- [ ] **Step 3: Run both tests and verify RED**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\profile-contract.ps1
powershell -ExecutionPolicy Bypass -File .\tests\config-contract.ps1
```

Expected: profile test fails because the new functions do not exist; configuration test fails because the overlay and NVIDIA Prometheus file do not exist and the base still contains NVIDIA components.

---

### Task 2: Split portable CPU, NVIDIA, and native Compose configurations

**Files:**
- Modify: `docker-compose.yml`
- Create: `docker-compose.nvidia.yml`
- Modify: `docker-compose.native-ollama.yml`
- Modify: `prometheus/prometheus.yml`
- Create: `prometheus/prometheus.nvidia.yml`
- Test: `tests/config-contract.ps1`

**Interfaces:**
- Consumes: immutable image variables in `.env` and current service contracts.
- Produces: the three profile compositions defined in Task 1.

- [ ] **Step 1: Make base Compose CPU-safe**

Remove the Ollama NVIDIA `deploy.resources.reservations.devices` block, remove the entire `nvidia-exporter` service, and remove the exporter dependency from Prometheus. Keep every other service, health check, volume, network, and localhost port unchanged.

- [ ] **Step 2: Create the NVIDIA overlay**

Create `docker-compose.nvidia.yml` with no top-level project-name override and these service changes:

```yaml
services:
  ollama:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]

  nvidia-exporter:
    image: ${NVIDIA_GPU_EXPORTER_IMAGE:-utkuozdemir/nvidia_gpu_exporter:1.13.1-nvml}
    container_name: pocketmind-nvidia-exporter
    restart: unless-stopped
    environment:
      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: utility
    command: ["--collect.backend=nvml", "--collect.interval=5s"]
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    healthcheck:
      test: ["CMD", "/usr/bin/nvidia_gpu_exporter", "--version"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [ai-net]

  prometheus:
    volumes:
      - ./prometheus/prometheus.nvidia.yml:/etc/prometheus/prometheus.yml:ro
    depends_on:
      nvidia-exporter:
        condition: service_healthy
```

Compose volume merging by container target replaces the base Prometheus config mount and preserves the token and data mounts.

- [ ] **Step 3: Split Prometheus configuration**

Make `prometheus/prometheus.yml` contain only the authenticated LiteLLM job. Create `prometheus/prometheus.nvidia.yml` with the same global section and LiteLLM job plus:

```yaml
  - job_name: nvidia_gpu
    scrape_interval: 5s
    scrape_timeout: 4s
    static_configs:
      - targets:
          - nvidia-exporter:9835
        labels:
          stack: pocketmind
```

- [ ] **Step 4: Make native Compose host-compatible**

Keep native Compose free of Ollama and exporter services. Add to LiteLLM:

```yaml
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

Keep the base Prometheus config mount and all localhost bindings.

- [ ] **Step 5: Run the configuration contract**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\config-contract.ps1
```

Expected: Compose and Prometheus assertions pass; only profile-function assertions remain red if run separately.

---

### Task 3: Implement shared profile selection and cross-platform HTTP

**Files:**
- Modify: `scripts/common.ps1`
- Modify: `scripts/check-prerequisites.ps1`
- Modify: `scripts/setup.ps1`
- Modify: `scripts/smoke-test.ps1`
- Modify: `scripts/verify-stack.ps1`
- Test: `tests/profile-contract.ps1`
- Test: `tests/config-contract.ps1`

**Interfaces:**
- Produces: `Get-PocHostOs() -> string`, `Get-PocArchitecture() -> string`, `Test-PocDockerNvidia() -> bool`, `Resolve-PocProfile(...) -> string`, `Get-PocComposeFiles(Profile) -> string[]`, `Invoke-PocCompose(Profile, Arguments)`, and `Invoke-PocHttpStatus(...) -> int`.
- Consumes: `.env` image variables, Docker CLI, optional `ollama`, optional `nvidia-smi`.

- [ ] **Step 1: Implement pure platform helpers and Compose mapping**

Use `[System.Runtime.InteropServices.RuntimeInformation]` so the code runs on Windows PowerShell 5.1 and PowerShell 7. Normalize OS values to `windows`, `macos`, `linux`; normalize architectures to `amd64` and `arm64`.

Implement the `Resolve-PocProfile` signature used by Task 1:

```powershell
function Resolve-PocProfile {
    param(
        [ValidateSet('auto', 'cpu', 'native', 'nvidia')] [string] $RequestedProfile = 'auto',
        [switch] $NativeOllama,
        [string] $HostOs = (Get-PocHostOs),
        [string] $Architecture = (Get-PocArchitecture),
        [Nullable[bool]] $DockerNvidiaAvailable = $null
    )
}
```

Rules: compatibility switch forces `native` unless a conflicting explicit profile was supplied; explicit `cpu`/`native` is returned; `nvidia` requires Windows/Linux + amd64 + successful probe; `auto` chooses native on macOS, otherwise NVIDIA only when the probe is true, otherwise CPU.

Implement `Get-PocComposeFiles` with the exact basename mapping from Task 1. Change `Invoke-PocCompose` to add one `-f` argument for every returned file.

- [ ] **Step 2: Implement a bounded NVIDIA Docker probe**

Use the pinned Ollama image and execute:

```text
docker run --rm --pull missing --gpus all --entrypoint nvidia-smi <OLLAMA_IMAGE> --query-gpu=name --format=csv,noheader
```

Run it through `Start-Process` with temporary stdout/stderr files and a 30-second timeout. Kill only that exact child process on timeout, remove the temporary files in `finally`, return `$true` only for exit code zero and non-empty GPU output, and preserve a diagnostic string for setup output. Do not change Docker configuration.

- [ ] **Step 3: Replace curl-specific status handling**

Add:

```powershell
function Invoke-PocHttpStatus {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [hashtable] $Headers = @{},
        [string] $Method = 'GET',
        [string] $Body,
        [string] $ContentType,
        [int] $TimeoutSeconds = 15
    )
}
```

Return the integer status from successful `Invoke-WebRequest` calls and from HTTP exceptions. Rethrow transport failures that have no HTTP response. Update prerequisite, invalid-key smoke check, and metrics retrieval to use PowerShell-native HTTP. No script may contain `curl.exe` or `--output NUL` afterward.

- [ ] **Step 4: Make prerequisite and setup scripts profile-aware**

Add parameters to both scripts:

```powershell
[ValidateSet('auto', 'cpu', 'native', 'nvidia')] [string] $Profile = 'auto'
[switch] $NativeOllama
```

Resolve once in setup, pass the resolved profile to prerequisites, Compose, and health checks. Native requires host Ollama health and model presence; `-Pull` pulls the missing model. NVIDIA requires host `nvidia-smi` and a successful Docker probe. CPU requires neither host command.

Expected long-running containers:

```text
all:     postgres, litellm, open-webui, prometheus, grafana
cpu:     + ollama
nvidia:  + ollama, nvidia-exporter
native:  no additional container
```

- [ ] **Step 5: Make smoke and runtime verification profile-aware**

Replace the invalid-key curl call with `Invoke-PocHttpStatus`. In verification, replace the PostgreSQL hairpin query with both:

- a `TcpClient` connection to `127.0.0.1:5432`
- authenticated `psql` inside `pocketmind-postgres`

Only the NVIDIA profile requires exporter health, `nvidia_gpu` target, GPU metric families, and `GPU` placement. CPU/native profiles must not fail because no NVIDIA target exists. Native runs `ollama list` and `ollama ps` on the host; CPU/NVIDIA run those commands inside the container.

- [ ] **Step 6: Run RED/GREEN profile and configuration tests**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\profile-contract.ps1
powershell -ExecutionPolicy Bypass -File .\tests\config-contract.ps1
```

Expected: both exit zero, and a repository script scan finds no `curl.exe` or `--output NUL`.

---

### Task 4: Platform documentation and CI contracts

**Files:**
- Modify: `README.md`
- Create: `.github/workflows/portability-contract.yml`
- Create: `tests/script-portability.ps1`
- Modify: `tests/config-contract.ps1`

**Interfaces:**
- Consumes: profiles and commands implemented in Tasks 2-3.
- Produces: user-facing quick starts and OS-matrix static validation.

- [ ] **Step 1: Write a failing script portability test**

Create `tests/script-portability.ps1` that reads every `scripts/*.ps1`, fails on `curl.exe`, `--output NUL`, backslash-only repository path construction, and direct selection of Compose files outside `common.ps1`. Assert README contains the strings `Windows 11`, `macOS`, `Ubuntu`, `-Profile auto`, `-Profile nvidia`, `-Profile native`, and `-Profile cpu`.

- [ ] **Step 2: Run the test and verify RED**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\script-portability.ps1
```

Expected: failure because README is still Windows-only and contains no profile quick starts.

- [ ] **Step 3: Rewrite README around the support matrix**

Document common URLs and security once, then provide exact commands:

```powershell
# Automatic
pwsh ./scripts/setup.ps1 -Profile auto -Pull

# NVIDIA Windows/Linux
pwsh ./scripts/setup.ps1 -Profile nvidia -Pull

# macOS native Ollama
ollama pull llama3.2:3b
pwsh ./scripts/setup.ps1 -Profile native

# Portable CPU
pwsh ./scripts/setup.ps1 -Profile cpu -Pull
```

Document Windows PowerShell 5.1 as `powershell -ExecutionPolicy Bypass -File ...`, native volume/model separation, image architectures, dashboard availability, macOS Metal, Ubuntu NVIDIA Toolkit prerequisite, localhost-only behavior, and the fact that hardware certification requires the target machine.

- [ ] **Step 4: Add the CI matrix**

Create a workflow triggered by pushes and pull requests. Use `windows-latest`, `macos-14`, and `ubuntu-latest` with `shell: pwsh` to run `tests/profile-contract.ps1` and `tests/script-portability.ps1`. On Ubuntu, additionally run `tests/config-contract.ps1` where Docker Compose is available. This CI performs static compatibility only and makes no GPU claim.

- [ ] **Step 5: Run portability tests GREEN**

Run all three local tests and require exit zero.

---

### Task 5: Preserve the current NVIDIA deployment and verify CPU composition

**Files:**
- Modify only if a failing regression test identifies a defect in files from Tasks 2-4.
- Test: `tests/profile-contract.ps1`
- Test: `tests/config-contract.ps1`
- Test: `tests/script-portability.ps1`
- Runtime test: `scripts/verify-stack.ps1`

**Interfaces:**
- Consumes: all completed profile configurations and scripts.
- Produces: fresh evidence for the current Windows NVIDIA host plus static evidence for CPU/native portability.

- [ ] **Step 1: Switch the existing deployment to the NVIDIA overlay**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -Profile nvidia
```

Expected: existing volumes are reused; all long-running services including exporter become healthy; no volume is deleted.

- [ ] **Step 2: Run full NVIDIA verification**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-stack.ps1 -Profile nvidia
```

Expected: inference/authentication, PostgreSQL host port, Grafana dashboards, LiteLLM target, NVIDIA target, GPU metric samples, model presence, and GPU placement pass.

- [ ] **Step 3: Validate CPU and native configurations without disrupting the running stack**

Run `docker compose config --quiet` for CPU, NVIDIA, and native combinations. Inspect rendered services, mounts, dependencies, device reservations, and published ports. Do not start CPU/native compositions because their fixed container names intentionally conflict with the running NVIDIA profile.

- [ ] **Step 4: Run the complete fresh test suite**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\profile-contract.ps1
powershell -ExecutionPolicy Bypass -File .\tests\config-contract.ps1
powershell -ExecutionPolicy Bypass -File .\tests\script-portability.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify-stack.ps1 -Profile nvidia
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml ps
```

Expected: every command exits zero and all NVIDIA-profile long-running containers report healthy.

- [ ] **Step 5: Record certification limits accurately**

Report Windows NVIDIA runtime as verified. Report macOS, Ubuntu, and CPU as statically validated until those physical environments execute runtime verification. Do not claim unexecuted platforms as runtime-certified.

---

## Final review checklist

- [ ] Default Compose has no NVIDIA dependency.
- [ ] NVIDIA features exist only in the overlay and NVIDIA Prometheus file.
- [ ] Native Compose uses host Ollama and has no NVIDIA target.
- [ ] Auto profile decisions match OS, architecture, and bounded GPU probe results.
- [ ] Windows PowerShell 5.1 and PowerShell 7 syntax remain compatible.
- [ ] No script uses `curl.exe` or `NUL`.
- [ ] Every published port remains loopback-only.
- [ ] Existing data volumes remain untouched.
- [ ] Windows NVIDIA runtime verification passes.
- [ ] macOS/Linux claims are limited to evidence actually collected.
