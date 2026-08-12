# GPU and Engine Grafana Dashboard Design

Date: 2026-08-12
Status: Proposed

## Goal

Add a Grafana dashboard that follows the two-row visual structure in `ref/dashboard1.png` and `ref/dashboard2.png` while reporting only metrics the current Ollama/LiteLLM stack and NVIDIA laptop GPU actually expose.

## Scope and constraints

- Keep the current Ollama + LiteLLM inference stack; do not migrate to vLLM.
- Add a Prometheus exporter that reads NVIDIA GPU data through `nvidia-smi`.
- Keep all host-published ports bound to `127.0.0.1`.
- Keep the existing LiteLLM overview dashboard.
- Never fabricate a vLLM-only metric. Unsupported values must show `N/A` or a concise explanation.
- The detected RTX 3050 Laptop GPU reports fan speed as `N/A`; the dashboard must represent that honestly.

## Architecture

```text
NVIDIA GPU -> nvidia-smi exporter -> Prometheus -> Grafana
LiteLLM metrics endpoint ---------> Prometheus -> Grafana
```

The NVIDIA exporter runs as a Compose service with GPU access and remains internal to the Compose network. Prometheus scrapes it every five seconds. Grafana continues to use the provisioned Prometheus data source.

## Dashboard layout

Create a provisioned dashboard named `Local LLM - GPU & Engine`, with a five-second refresh and two collapsible rows. Each row uses a three-column by two-row panel layout matching the references.

### GPU Hardware (nvidia-smi)

1. GPU SM Utilization - percentage over time.
2. VRAM Used / Total - used and total bytes, formatted as GiB.
3. Power Draw - watts over time.
4. GPU Temperature - Celsius over time with warning thresholds.
5. Graphics Clock - MHz over time.
6. Fan Speed - percentage when available; otherwise an explicit `N/A` state for this laptop GPU.

### Ollama / LiteLLM Engine

The row is deliberately named for the actual engine instead of `vLLM Engine`.

1. KV Cache Usage - explanatory `N/A`; Ollama does not expose a compatible Prometheus gauge.
2. Requests Running / Waiting - running requests from `litellm_in_flight_requests`; waiting count marked unavailable because LiteLLM exposes queue latency but not a waiting-request gauge.
3. Throughput - input and output token rates derived from LiteLLM token counters.
4. Prefix Cache Hit Rate - explanatory `N/A`; the current stack lacks the hit/query counters required for a truthful ratio.
5. Time to First Token - p50 and p95 from LiteLLM's TTFT histogram.
6. Inter-token Latency - p50 and p95 from LiteLLM's per-output-token latency histogram.

## Configuration changes

- Add an NVIDIA GPU exporter service to the primary Compose file with a pinned image version, GPU reservation, and a health check.
- Add a Prometheus scrape job for the exporter.
- Add the dashboard JSON under `grafana/dashboards/` so existing provisioning loads it automatically.
- Extend the README with metric availability, the fan-speed limitation, and troubleshooting for exporter/GPU access.
- Extend configuration contract tests to cover the service, scrape target, dashboard rows, panel titles, PromQL expressions, and localhost-only publishing policy.

The native Ollama fallback remains usable for inference. GPU telemetry depends on Docker GPU access; if unavailable, the GPU panels show no data and the troubleshooting guide explains how to verify Docker/NVIDIA integration.

## Failure handling

- Missing GPU access: exporter health/Prometheus target identifies the failure; Grafana panels show no data rather than zero.
- Unsupported fan metric: panel displays `N/A`, not `0%`.
- Missing LiteLLM histogram samples: latency panels show no data until requests are made.
- Dashboard provisioning errors: verification queries the Grafana API by dashboard UID.

## Verification

1. Run the configuration contract tests before and after implementation.
2. Render and validate Compose configuration.
3. Start/recreate the changed monitoring services.
4. Confirm the exporter is healthy and its Prometheus target is `UP`.
5. Confirm required GPU metric families exist; fan speed is optional.
6. Send inference requests so engine histograms and token counters have samples.
7. Confirm all supported dashboard queries return data through Prometheus.
8. Confirm Grafana loads the dashboard UID and contains two rows with twelve requested panels.
9. Run the existing full-stack verification to ensure no regression.

## External references

- NVIDIA GPU exporter: https://github.com/utkuozdemir/nvidia_gpu_exporter
- vLLM metric definitions used only to identify unsupported semantics: https://docs.vllm.ai/en/latest/usage/metrics/
