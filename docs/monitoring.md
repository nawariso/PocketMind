# Monitoring and performance evidence

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

## Benchmarks and usage

```powershell
pwsh ./scripts/benchmark.ps1 -Runs 5
pwsh ./scripts/usage-report.ps1 -Days 30
```

Record cold/warm timings, workload, concurrency, context, model tag and actual GPU placement. Token totals do not establish answer quality. See [tuning](tuning.md), [evaluation](models/evaluation-guide.md), [benchmark log](models/benchmark-log.md), and [usage accounting](operations-runbook.md#usage-and-cost-comparison).
