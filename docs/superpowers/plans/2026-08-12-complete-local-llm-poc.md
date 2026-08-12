# Complete PocketMind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a complete, localhost-only Windows PocketMind matching the README and verified end to end.

**Architecture:** Docker Compose runs PostgreSQL, Docker Ollama, LiteLLM, Open WebUI, Prometheus, and Grafana with named-volume persistence and health-gated startup. PowerShell scripts validate bind mounts and exercise the same public APIs an application uses; a second Compose file supports native Windows Ollama without changing the client-facing model alias.

**Tech Stack:** Docker Compose, PowerShell 7/Windows PowerShell, LiteLLM, Ollama, PostgreSQL 16, Open WebUI, Prometheus, Grafana.

## Global Constraints

- Publish service ports only on `127.0.0.1`.
- Publish Local LLM PostgreSQL as `127.0.0.1:5432:5432`; the conflicting OpenMetadata PostgreSQL container must remain stopped.
- Preserve existing Docker volumes and model/database data.
- Keep `corp-general` as the client-facing alias and `llama3.2:3b` as the default physical model.
- Do not add TLS, SSO, Kubernetes, HA, or Internet exposure.
- Scripts must have bounded waits, terminating failures, and no external PowerShell module dependency.

---

### Task 1: Static acceptance contract

**Files:**
- Create: `tests/config-contract.ps1`

**Interfaces:**
- Consumes: repository files and rendered Docker Compose configuration.
- Produces: exit code 0 only when required assets exist with correct types and all host ports are loopback-bound.

- [ ] Write assertions for the six services, required config/provisioning/script files, and `127.0.0.1` port bindings.
- [ ] Run `powershell -ExecutionPolicy Bypass -File .\tests\config-contract.ps1` and confirm it fails on the currently missing assets.
- [ ] Keep the failing test unchanged while implementing Tasks 2-4.

### Task 2: Service and observability configuration

**Files:**
- Modify: `.env`
- Modify: `docker-compose.yml`
- Modify: `docker-compose.native-ollama.yml`
- Modify: `litellm/config.yaml`
- Create: `prometheus/prometheus.yml`
- Create: `prometheus/litellm_token`
- Create: `grafana/provisioning/datasources/prometheus.yml`
- Create: `grafana/provisioning/dashboards/dashboard.yml`
- Create: `grafana/dashboards/litellm-overview.json`

**Interfaces:**
- Consumes: `.env` credentials, model settings, Docker DNS names, and named volumes.
- Produces: a shared LiteLLM config, health-gated services, authenticated metrics scraping, and an automatically provisioned dashboard.

- [ ] Replace wrongly typed empty bind-mount directories with real files after stopping affected containers.
- [ ] Bind every published port as `127.0.0.1:<host>:<container>` and add healthchecks for all long-running HTTP services.
- [ ] Publish PostgreSQL as `127.0.0.1:5432:5432` in both Compose modes and assert the exact rendered mapping in `tests/config-contract.ps1`.
- [ ] Configure Prometheus to scrape `http://litellm:4000/metrics/` using `litellm_token`.
- [ ] Provision Grafana's Prometheus datasource and a dashboard containing request, failure, token, and latency panels.
- [ ] Run `docker compose config --quiet` for both Compose files.

### Task 3: Operational PowerShell scripts

**Files:**
- Create: `scripts/common.ps1`
- Create: `scripts/check-prerequisites.ps1`
- Create: `scripts/setup.ps1`
- Create: `scripts/smoke-test.ps1`
- Create: `scripts/create-virtual-key.ps1`
- Create: `scripts/benchmark.ps1`
- Create: `scripts/verify-stack.ps1`

**Interfaces:**
- Consumes: `.env`, Docker CLI, HTTP endpoints, and optional `-NativeOllama` / benchmark parameters.
- Produces: deterministic setup, smoke-test, key creation, benchmark output, and a full verification summary.

- [ ] Implement shared `.env`, HTTP, Compose, and bounded-wait helpers in `common.ps1`.
- [ ] Implement prerequisite checks for Docker, Compose, NVIDIA, and required file types.
- [ ] Implement setup with token synchronization, Compose validation, startup, and health wait.
- [ ] Implement smoke test with model discovery, inference, and invalid-key rejection.
- [ ] Implement a 30-day `corp-general` virtual-key request without printing the master key.
- [ ] Implement warm-up plus latency/token-throughput benchmark.
- [ ] Implement full runtime checks for all services, Prometheus, Grafana, model, and GPU.

### Task 4: Documentation alignment

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: scripts and Compose commands delivered in Tasks 2-3.
- Produces: exact setup, verification, fallback, troubleshooting, and security instructions.

- [ ] Replace manual fragile startup with `scripts/setup.ps1` as the recommended path while retaining equivalent manual commands.
- [ ] Document localhost-only ports, health verification, virtual-key handling, benchmark usage, fallback mode, and persistence verification.
- [ ] Remove statements that refer to files or dashboards not delivered by this plan.

### Task 5: Green static verification and runtime bring-up

**Files:**
- Test: `tests/config-contract.ps1`

**Interfaces:**
- Consumes: all artifacts from Tasks 2-4.
- Produces: a statically valid repository and a running primary stack.

- [ ] Run the static contract and confirm all assertions pass.
- [ ] Run `scripts/setup.ps1` and wait for dependency-gated startup.
- [ ] Inspect failures component-by-component and make only root-cause fixes.
- [ ] Re-run the static contract after any configuration edit.

### Task 6: End-to-end and persistence verification

**Files:**
- Test: `scripts/smoke-test.ps1`
- Test: `scripts/verify-stack.ps1`

**Interfaces:**
- Consumes: the running primary stack.
- Produces: evidence for README success criteria.

- [ ] Run smoke test and verify authenticated inference plus HTTP 401 for an invalid key.
- [ ] Verify Prometheus target health and all four named LiteLLM metrics.
- [ ] Verify Grafana health, datasource, and dashboard through its API.
- [ ] Verify Open WebUI health and its LiteLLM-only environment.
- [ ] Verify password-authenticated PostgreSQL access through `127.0.0.1:5432`, matching DBeaver's connection path.
- [ ] Record Ollama GPU placement after inference.
- [ ] Restart services without deleting volumes, wait for health, and verify the model and `corp-general` remain available.
- [ ] Run the full verifier once more and report any remaining limitation explicitly.
