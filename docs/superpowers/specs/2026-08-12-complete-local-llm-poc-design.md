# Complete PocketMind Design

## Goal

Make the README's PocketMind fully operational and repeatable on Windows while exposing every published service only through `127.0.0.1`.

## Scope

The primary mode runs Ollama in Docker with NVIDIA GPU access. A native-Windows Ollama compose variant remains available as a fallback. Both modes expose the same LiteLLM OpenAI-compatible contract and model alias, `corp-general`.

The stack includes PostgreSQL, Ollama, LiteLLM, Open WebUI, Prometheus, and Grafana. It also includes setup, prerequisite, smoke-test, virtual-key, benchmark, and full-stack verification scripts.

## Architecture

- PostgreSQL persists LiteLLM state and virtual keys in a named volume.
- Ollama serves `llama3.2:3b`; the Docker mode downloads it through the one-shot `model-init` service.
- LiteLLM maps the client-facing `corp-general` alias to the physical Ollama model and exposes authenticated OpenAI-compatible APIs and Prometheus metrics.
- Open WebUI connects only to LiteLLM, never directly to Ollama.
- Prometheus scrapes LiteLLM's authenticated `/metrics/` endpoint.
- Grafana is provisioned with the Prometheus datasource and a local LiteLLM dashboard.
- All host port mappings bind to `127.0.0.1`.
- PostgreSQL is available to Windows database clients at `127.0.0.1:5432`. The conflicting OpenMetadata PostgreSQL container must remain stopped while this mapping is active.

## Configuration and Reproducibility

Image references are supplied through `.env` with versioned defaults in Compose rather than unqualified `latest` references. Bind-mounted file sources must exist as files before Compose starts. The setup and acceptance scripts reject a directory where a file is required, preventing Docker from silently reproducing the original `IsADirectoryError` failure.

The two Ollama modes share the LiteLLM model contract. The Docker config targets `http://ollama:11434`; the native fallback targets `http://host.docker.internal:11434`.

## Operational Flow

1. `scripts/setup.ps1` validates prerequisites and required bind mounts, synchronizes the Prometheus bearer token with `LITELLM_MASTER_KEY`, validates Compose, and starts the selected mode.
2. Compose health dependencies bring services up in dependency order.
3. `scripts/smoke-test.ps1` verifies LiteLLM health, model discovery, authenticated inference, and invalid-key rejection.
4. `scripts/verify-stack.ps1` additionally verifies all containers, Open WebUI, Prometheus target health, Grafana provisioning, metrics, Ollama model presence, and GPU placement.
5. `scripts/benchmark.ps1` records per-request latency and approximate output-token throughput.

## Error Handling

PowerShell scripts use terminating errors and return non-zero on failure. Every failure identifies its component and expected state. HTTP checks use bounded timeouts. The setup process never deletes volumes. The persistence check uses service restarts only and verifies the model and database-backed LiteLLM state afterward.

## Testing

A dependency-free PowerShell acceptance test checks required files, YAML-relevant Compose rendering, localhost-only bindings, expected service definitions, and provisioning assets. It is run before implementation to demonstrate the missing-file failure and after implementation to verify the corrected static configuration.

Runtime verification checks:

- six long-running services are running and healthy;
- `model-init` exits with code 0;
- LiteLLM liveness/readiness and Admin UI respond;
- `corp-general` completes an inference through Ollama;
- an invalid key receives HTTP 401;
- Prometheus reports the LiteLLM target as healthy;
- Grafana reports a healthy database, provisioned Prometheus datasource, and provisioned dashboard;
- Ollama shows the model loaded on GPU;
- restart preserves the model and LiteLLM model alias.
- a password-authenticated TCP connection through `127.0.0.1:5432` reaches the `litellm` database as the `litellm` user.

## Non-Goals

TLS, LAN exposure, SSO, external secret managers, Kubernetes, HA, and Internet exposure are intentionally excluded. This remains a local-machine POC.
