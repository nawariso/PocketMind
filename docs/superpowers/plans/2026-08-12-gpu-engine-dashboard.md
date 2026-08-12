# GPU and Engine Grafana Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a provisioned Grafana dashboard for NVIDIA hardware and truthful Ollama/LiteLLM engine telemetry.

**Architecture:** A containerized NVIDIA GPU exporter reads the GPU through NVIDIA's container runtime and exposes Prometheus metrics on the internal Compose network. Prometheus scrapes both the exporter and LiteLLM, while Grafana provisions a new two-row dashboard from JSON. vLLM-only semantics that the current Ollama stack cannot expose are rendered as explicit informational `N/A` panels.

**Tech Stack:** Docker Compose, `utkuozdemir/nvidia_gpu_exporter`, Prometheus/PromQL, Grafana dashboard JSON, PowerShell contract and runtime tests.

## Global Constraints

- Keep the current Ollama + LiteLLM inference stack; do not migrate to vLLM.
- Keep all host-published ports bound to `127.0.0.1`.
- Keep the existing LiteLLM overview dashboard.
- Never fabricate a vLLM-only metric.
- The detected RTX 3050 Laptop GPU reports fan speed as `N/A`.
- Do not publish the exporter port to the host; Prometheus accesses `nvidia-exporter:9835` internally.
- This workspace is not a Git repository, so commit steps are intentionally omitted.

---

### Task 1: Monitoring configuration contract

**Files:**
- Modify: `tests/config-contract.ps1`
- Test: `tests/config-contract.ps1`

**Interfaces:**
- Consumes: rendered Compose JSON from `docker compose config --format json` and the provisioned dashboard JSON.
- Produces: failing assertions that define the exporter service, Prometheus target, dashboard identity, rows, twelve content panels, and exact PromQL contract.

- [ ] **Step 1: Add the failing configuration assertions**

Add `grafana/dashboards/gpu-engine-overview.json` to `$requiredFiles`. Add `nvidia-exporter` to the primary Compose expected service list, then assert:

```powershell
$exporter = $config.services.'nvidia-exporter'
Assert-True -Condition ($null -ne $exporter) -Message "$ComposeFile does not define service 'nvidia-exporter'"
Assert-True -Condition ($null -eq $exporter.PSObject.Properties['ports']) `
    -Message "$ComposeFile must not publish the NVIDIA exporter port"
```

Only apply exporter-specific assertions to `docker-compose.yml`; the native Ollama fallback is allowed to run without GPU telemetry.

Parse the new dashboard with `ConvertFrom-Json` and assert:

```powershell
$dashboardPath = Join-Path $repoRoot 'grafana/dashboards/gpu-engine-overview.json'
$dashboard = Get-Content -Raw -LiteralPath $dashboardPath | ConvertFrom-Json
$rowTitles = @($dashboard.panels | Where-Object type -eq 'row' | ForEach-Object title)
$contentPanels = @($dashboard.panels | Where-Object type -ne 'row')

Assert-True ($dashboard.uid -eq 'pocketmind-gpu-engine') 'GPU dashboard UID is incorrect'
Assert-True ($dashboard.title -eq 'Local LLM - GPU & Engine') 'GPU dashboard title is incorrect'
Assert-True ($dashboard.refresh -eq '5s') 'GPU dashboard refresh must be 5s'
Assert-True (($rowTitles -join '|') -eq 'GPU Hardware (nvidia-smi)|Ollama / LiteLLM Engine') `
    'GPU dashboard rows are incorrect'
Assert-True ($contentPanels.Count -eq 12) 'GPU dashboard must contain twelve content panels'
```

Assert the twelve titles and flatten every target expression into `$expressions`. The required expressions are:

```text
nvidia_smi_utilization_gpu_ratio
nvidia_smi_memory_used_bytes
nvidia_smi_memory_total_bytes
nvidia_smi_power_draw_watts
nvidia_smi_temperature_gpu
nvidia_smi_clocks_current_graphics_clock_hz
nvidia_smi_fan_speed_ratio
sum(litellm_in_flight_requests)
sum(rate(litellm_input_tokens_metric_total[1m]))
sum(rate(litellm_output_tokens_metric_total[1m]))
histogram_quantile(0.50, sum by (le) (rate(litellm_llm_api_time_to_first_token_metric_bucket[5m])))
histogram_quantile(0.95, sum by (le) (rate(litellm_llm_api_time_to_first_token_metric_bucket[5m])))
histogram_quantile(0.50, sum by (le) (rate(litellm_deployment_latency_per_output_token_bucket[5m])))
histogram_quantile(0.95, sum by (le) (rate(litellm_deployment_latency_per_output_token_bucket[5m])))
```

Read `prometheus/prometheus.yml` and assert it contains a `nvidia_gpu` job, target `nvidia-exporter:9835`, and `scrape_interval: 5s` within that job.

- [ ] **Step 2: Run the contract and verify RED**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\config-contract.ps1
```

Expected: exit `1`, specifically reporting the missing NVIDIA exporter service, Prometheus scrape job, and `gpu-engine-overview.json`.

---

### Task 2: NVIDIA exporter, Prometheus scrape, and dashboard

**Files:**
- Modify: `.env`
- Modify: `docker-compose.yml`
- Modify: `prometheus/prometheus.yml`
- Create: `grafana/dashboards/gpu-engine-overview.json`
- Test: `tests/config-contract.ps1`

**Interfaces:**
- Consumes: NVIDIA container runtime, GPU reservation syntax already used by `ollama`, Prometheus datasource UID `prometheus`.
- Produces: internal endpoint `http://nvidia-exporter:9835/metrics`, Prometheus job `nvidia_gpu`, Grafana UID `pocketmind-gpu-engine`.

- [ ] **Step 1: Resolve and pin the exporter image**

Pull the stable NVML flavor and inspect its immutable digest:

```powershell
docker pull utkuozdemir/nvidia_gpu_exporter:1.13.1-nvml
docker image inspect utkuozdemir/nvidia_gpu_exporter:1.13.1-nvml --format '{{index .RepoDigests 0}}'
```

Add the returned `utkuozdemir/nvidia_gpu_exporter@sha256:...` value as `NVIDIA_GPU_EXPORTER_IMAGE` in `.env` beside the other immutable image references.

- [ ] **Step 2: Add the internal exporter service**

Add this service to `docker-compose.yml` before Prometheus:

```yaml
  nvidia-exporter:
    image: ${NVIDIA_GPU_EXPORTER_IMAGE:-utkuozdemir/nvidia_gpu_exporter:1.13.1-nvml}
    container_name: pocketmind-nvidia-exporter
    restart: unless-stopped
    environment:
      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: utility
    command:
      - "--collect.backend=nvml"
      - "--collect.interval=5s"
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
```

Do not add `ports`. Add an exporter dependency to Prometheus:

```yaml
    depends_on:
      litellm:
        condition: service_healthy
      nvidia-exporter:
        condition: service_healthy
```

- [ ] **Step 3: Add the five-second Prometheus scrape job**

Append to `scrape_configs` in `prometheus/prometheus.yml`:

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

- [ ] **Step 4: Create the provisioned dashboard JSON**

Create schema version `39`, UID `pocketmind-gpu-engine`, title `Local LLM - GPU & Engine`, refresh `5s`, time range `now-15m` to `now`, timezone `browser`, and tags `pocketmind`, `gpu`, `litellm`.

Use row panels at `y=0` and `y=17`. Place each row's six content panels in a three-column grid (`x=0,8,16`, `w=8`, `h=8`). Use IDs 1-14 with IDs 1 and 8 reserved for row panels.

GPU panels use these exact PromQL expressions and units:

| Title | Expression(s) | Unit |
|---|---|---|
| GPU SM Utilization | `nvidia_smi_utilization_gpu_ratio` | `percentunit` |
| VRAM Used / Total | `nvidia_smi_memory_used_bytes`; `nvidia_smi_memory_total_bytes` | `bytes` |
| Power Draw | `nvidia_smi_power_draw_watts` | `watt` |
| GPU Temperature | `nvidia_smi_temperature_gpu` | `celsius` |
| Graphics Clock | `nvidia_smi_clocks_current_graphics_clock_hz` | `hertz` |
| Fan Speed | `nvidia_smi_fan_speed_ratio` | `percentunit` |

The fan panel must set `noValue` to `N/A - not exposed by this laptop GPU` and explain the limitation in its description. It must not use `or vector(0)`.

Engine panels use these definitions:

| Title | Type | Expression/content |
|---|---|---|
| KV Cache Usage | `text` | `N/A - Ollama does not expose a Prometheus KV-cache usage gauge.` |
| Requests Running / Waiting | `timeseries` | `sum(litellm_in_flight_requests)` with legend `Running`; description states that waiting count is unavailable and LiteLLM only exposes queue latency. |
| Throughput (tokens/s) | `timeseries` | input and output one-minute rates from the contract expressions. |
| Prefix Cache Hit Rate | `text` | `N/A - the current stack does not expose both cache hit and query counters.` |
| Time to First Token | `timeseries` | p50 and p95 five-minute histogram quantiles from the contract expressions, unit `s`. |
| Inter-token Latency | `timeseries` | p50 and p95 five-minute histogram quantiles from the contract expressions, unit `s`. |

All metric panels use datasource `{ "type": "prometheus", "uid": "prometheus" }`, transparent dark-theme-friendly styling, tooltips, legends, and sensible thresholds. Text panels use Markdown and do not contain Prometheus targets.

- [ ] **Step 5: Run the contract and verify GREEN**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\config-contract.ps1
```

Expected: exit `0` and `Configuration contract passed.`

- [ ] **Step 6: Validate rendered Compose configuration**

Run:

```powershell
docker compose config --quiet
docker compose config --format json
```

Expected: both commands exit `0`; the JSON contains `nvidia-exporter` without a `ports` property.

---

### Task 3: Runtime verification and operator documentation

**Files:**
- Modify: `scripts/verify-stack.ps1`
- Modify: `README.md`
- Test: `tests/config-contract.ps1`
- Runtime test: `scripts/verify-stack.ps1`

**Interfaces:**
- Consumes: container `pocketmind-nvidia-exporter`, Prometheus job `nvidia_gpu`, Grafana UID `pocketmind-gpu-engine`.
- Produces: one-command verification of exporter health, required GPU metric families, Prometheus target health, and dashboard provisioning; documented access and limitations.

- [ ] **Step 1: Add failing verification-script contract assertions**

Extend `tests/config-contract.ps1` to read `scripts/verify-stack.ps1` and assert it references:

```text
pocketmind-nvidia-exporter
pocketmind-gpu-engine
nvidia_gpu
nvidia_smi_utilization_gpu_ratio
nvidia_smi_memory_used_bytes
nvidia_smi_memory_total_bytes
nvidia_smi_power_draw_watts
nvidia_smi_temperature_gpu
nvidia_smi_clocks_current_graphics_clock_hz
```

- [ ] **Step 2: Run the contract and verify RED**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\config-contract.ps1
```

Expected: exit `1` because `verify-stack.ps1` does not yet validate the new monitoring path.

- [ ] **Step 3: Extend runtime verification**

For Docker-Ollama mode, add `pocketmind-nvidia-exporter` to `$requiredContainers`. Do not require it for `-NativeOllama`.

After checking the LiteLLM target, query Prometheus targets and require exactly one `nvidia_gpu` target with `health = up`. Query `http://localhost:9090/api/v1/query?query=<URL-encoded metric>` for each required GPU family listed in Step 1 and require a non-empty `data.result`.

Query Grafana UID `pocketmind-gpu-engine`, require title `Local LLM - GPU & Engine`, two row panels, and twelve non-row panels. Do not require `nvidia_smi_fan_speed_ratio`, because this laptop reports fan speed as unsupported.

- [ ] **Step 4: Document the dashboard and limitations**

Update the architecture diagram and service list with `nvidia-exporter`. In the Grafana section, list both dashboards and explain:

```text
Supported GPU metrics: utilization, used/total VRAM, power draw, temperature, graphics clock.
Fan speed: N/A on the detected RTX 3050 Laptop GPU.
Ollama/LiteLLM equivalents: running requests, token throughput, TTFT, inter-token latency.
Unavailable without vLLM: KV-cache usage, waiting-request gauge, prefix-cache hit rate.
```

Add troubleshooting commands:

```powershell
docker compose logs nvidia-exporter
Invoke-RestMethod 'http://localhost:9090/api/v1/targets'
```

State explicitly that port `9835` is internal-only and the dashboard remains reachable only through `http://localhost:3001`.

- [ ] **Step 5: Start changed services and generate inference samples**

Run:

```powershell
docker compose up -d nvidia-exporter prometheus grafana
powershell -ExecutionPolicy Bypass -File .\scripts\smoke-test.ps1
```

Expected: exporter, Prometheus, and Grafana become healthy; inference completes and seeds LiteLLM latency/token histograms.

- [ ] **Step 6: Run complete fresh verification**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\config-contract.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify-stack.ps1
docker compose ps
```

Expected: both PowerShell tests exit `0`; every long-running primary service is running and healthy; `model-init` is exited `0`.

- [ ] **Step 7: Visually inspect the provisioned dashboard**

Open `http://localhost:3001/d/pocketmind-gpu-engine` and confirm the two row layout, readable panel titles, supported GPU data, engine data after inference, and explicit `N/A` panels. Capture a screenshot for verification if browser automation is available.

---

## Final review checklist

- [ ] Every design requirement maps to a task above.
- [ ] Primary Compose contains the exporter and publishes no exporter port.
- [ ] Native fallback remains renderable and documented as lacking Docker GPU telemetry.
- [ ] Exactly two rows and twelve requested content panels exist.
- [ ] No vLLM-only value is synthesized.
- [ ] Fan speed absence is not converted to zero.
- [ ] Existing LiteLLM dashboard remains unchanged.
- [ ] Contract, runtime, Compose, Prometheus, Grafana API, and visual checks all pass with fresh evidence.
