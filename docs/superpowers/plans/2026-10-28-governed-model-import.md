# Optional Governed Model Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task in this session. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional MuleSoft-governed model acquisition and verified local import while preserving standalone and isolated serving.

**Architecture:** MuleSoft fronts an acquisition job API; a separate acquisition zone downloads, scans and approves artifacts. A management-side importer verifies trusted release metadata and local files before creating an Ollama model and registering a LiteLLM alias. Existing serving containers gain no external network or mandatory integration.

**Tech Stack:** Python 3.11+ standard library/SQLite shared workflow, PowerShell 7 entrypoints, JSON Schema/OpenAPI contracts, existing Ollama/LiteLLM/Open WebUI APIs, unittest behavior tests and existing PowerShell regression checks; separate optional Compose project. Production Mule assets depend on confirmed deployment inputs.

**Spec:** [ADR 0006 and detailed target state](../../decisions/0006-optional-governed-model-import.md).

**Status:** Stage A implemented and under verification; actual progress and test evidence are tracked in [the implementation ledger](../../../governance/IMPLEMENTATION.md). Stage B/C are pending organizational inputs. Task descriptions below preserve the original planning breakdown; Python shared modules implement the named responsibilities behind PowerShell entrypoints rather than adding a parallel PowerShell core. The runbook, actual code and ledger identify delivered interfaces and remaining qualification limits.

**Automation amendment (2026-10-28):** The administrator submits demand once. Scripts are internal building blocks, not a checklist of commands the administrator must run for each model. The delivered workflow includes durable progress, automatic policy decisions, target-agent installation and explicit group access before `ready`.

## Global Constraints

- Standalone commands and default Compose selection remain unchanged.
- Missing MuleSoft configuration never affects standalone startup, inference or model management.
- Existing Privacy mode remains supported without MuleSoft. Governed import must not require disabling Privacy mode.
- Existing models, stable aliases, credentials and persistent volumes are not migrated or replaced automatically.
- Governed operations fail closed; failure must never fall back to a public download.
- Governance on a managed deployment is enforced by infrastructure and privileged service boundaries, not merely an optional CLI flag.
- First import target: CPU/NVIDIA container Ollama and supported single-file GGUF; native governed import and DeepSeek/new-runtime qualification are outside the first release.
- Never mount the Docker socket in a governance service or share production data with acquisition workers.
- Repository checks are not evidence of deployed firewall, scanner or MuleSoft enforcement.

## Review Focus

1. A trusted-looking manifest beside untrusted weights is not approval: importer must verify release status against the configured authenticated authority (Tasks 1 and 3).
2. Tag changes, redirects and source metadata can cross trust boundaries: resolve immutable identities, constrain destinations and preserve provenance (Tasks 1 and 5).
3. Large/partial files, unsupported scanner formats and scanner timeouts must not pass as clean (Tasks 2, 3 and 5).
4. Alias/API failure or restart after model creation must not overwrite production, create duplicate release models or delete shared weights (Tasks 3 and 4).
5. Separate Compose project lifecycle, host access and configuration precedence must preserve standalone/Privacy boundaries (Tasks 1, 4 and 6).

## Delivery stages and ownership

### Execution checklist (current implementation)

- [x] Task 1: `governance/contracts.py`, `settings.py` and published `contracts/`; `test_governance_contracts.py` / `test_governance_cli.py`.
- [x] Task 2: `cli.py`, `http.py`, `scripts/model-acquisition.ps1`; loopback HTTP/client tests.
- [x] Task 3: `files.py`, `windows_acl.py`, `http.py` verification/staging; bundle and ACL regressions.
- [x] Task 4: `importer.py`, `runtime.py`, `scripts/import-governed-model.ps1`; import, recovery and HTTP payload tests.
- [x] Task 4A: `jobs.py`, `delivery.py`, `scripts/governance-agent.ps1`; durable workflow, separate-agent, lease and retry tests.
- [x] Task 4B: `server.py`, `compose.governance.yml`, `scripts/start-governance.ps1`; admin/API authentication, CSRF and progress tests.
- [x] Task 6 repository deliverables: runbook, optional configuration, CI matrix and Compose rendering tests.
- [ ] Task 5: real organization-specific MuleSoft/downloader/scanner/policy integration.
- [ ] Task 6 deployment qualification: live runtime, actual user discovery, service installation, image build/run and firewall evidence.

The detailed planning steps below are preserved as design intent; this checklist and the ledger identify what actually ran and which implementation files supersede proposed `.ps1` library filenames.

| Stage | Deliverable | Owner/dependency |
|---|---|---|
| A: local software POC | Contracts, trusted fixture API, validator, importer, end-to-end coordinator/agent, admin progress interface and regression evidence | Repository work after design approval |
| B: enterprise acquisition | Real Mule API, jobs, download adapters, quarantine, scanning and approval | Mule/platform/security teams; deployment inputs required |
| C: deployment qualification | Trusted internal transfer, deny rules, real model smoke test and operational evidence | Infra/security plus PocketMind operator |

Stage A must not masquerade as Stage B. Automated fixtures use tiny inert files and mocked runtime/API boundaries; loading a real GGUF is an explicitly selected integration check, not a unit test dependency. No production endpoint or credentials are invented.

## Task 1: Versioned contracts and optional configuration

**Files:** Create `governance/contracts/acquisition-api.yaml`, `governance/contracts/model-release.schema.json`, `governance/contracts/import-receipt.schema.json`, `governance/README.md`, `.env.governance.example`, `scripts/governance/common.ps1`, `tests/governance-contract.ps1`.

**Interfaces:** `Get-GovernanceSettings -Path <file>` returns validated acquisition API base, internal release authority/base and credential environment-variable names. `Assert-ReleaseManifest -Manifest <object>` validates schema/required evidence and returns normalized metadata or throws. Configuration is loaded only by governance commands, with no hidden fallback to public endpoints.

- [ ] Write contract cases for valid approval; pending/revoked/unsupported schema; absent mandatory scan coverage; duplicate/unsafe file paths; and source identities missing full commit/blob digests. Every invalid case must throw.
- [ ] Run `pwsh -NoProfile -File tests/governance-contract.ps1`; confirm failure because implementation/contracts are absent.
- [ ] Define exact JSON field names/types/enums, API authentication requirements, job states, version handling and error responses from ADR 0006. Both provider adapters use the same release schema. Define the trusted approval/revocation lookup response explicitly.
- [ ] Implement the settings and manifest validators. Require HTTPS for real endpoints; permit loopback HTTP only in an explicit test mode with no production credentials. Never disable certificate verification. Treat example credentials as placeholders.
- [ ] Run the test again; require PASS and verify no serving config reads `.env.governance.example`.

## Task 2: Acquisition client and trusted fixture API

**Files:** Create `scripts/model-acquisition.ps1`, `tests/model-acquisition-behavior.ps1`, `tests/fixtures/governance/` and a test-only loopback fixture server under that directory.

**Interfaces:** `model-acquisition.ps1 request -Source <huggingface|ollama> -ModelId <id> -Revision <tag-or-revision> -Alias <name> -TargetId <id> -AccessGroupId <id> -Purpose <text> -ConfigPath <file>` submits a complete delivery demand and returns a job record; `status -JobId <id>` returns overall state and step checklist; `manifest -ReleaseId <id> -OutputPath <file>` retrieves approved metadata. `retry` and `cancel` act on the job ID. Recognized provider links are normalized by the client; arbitrary URLs are rejected. These commands invoke the workflow, not manual alias registration.

- [ ] Write failing behavior tests: 202/job ID, idempotency header reuse, denied auth, pending/rejected/revoked release, API timeout, malformed response, no token in stdout/stderr, no arbitrary URL, no indefinite polling.
- [ ] Run `pwsh -NoProfile -File tests/model-acquisition-behavior.ps1`; require the expected pre-implementation failures.
- [ ] Implement bounded requests with distinct actionable error codes, no automatic public-download fallback and no credentials in command arguments. The fixture authority must clearly identify itself as test-only and default to not-approved.
- [ ] Verify all client cases pass without external network, Docker or real model weights. Keep approved fixture hashes reproducible and only approve them within the test authority.
- [ ] Cover overall job lifecycle separately from release approval, byte progress with unknown totals, retry/cancel authorization and supported source-link normalization. A disconnected client must not cancel its submitted job.

## Task 3: Validate and stage approved bundles

**Files:** Create `scripts/governance/release.ps1`, `tests/governed-release-behavior.ps1`; extend Task 1 fixtures/schema only where ADR fields require it.

**Interfaces:** `Test-GovernedBundle -Manifest <object> -BundlePath <path> -Settings <object>` checks authenticated current authority approval and all files, returning a verified release descriptor or throwing. `New-GovernedStaging -VerifiedRelease <descriptor> -Destination <private-directory>` produces a protected local staging descriptor with a generated restricted Modelfile. Neither function invokes Ollama or LiteLLM.

- [ ] Write failing tests: hash/size mismatch, partial download, unlisted/missing file, duplicate/case-colliding path, traversal/absolute path, symlink/reparse point, revoked approval, TLS/auth failure, release identity mismatch, unsupported runtime, unsafe Modelfile directives and evidence marked skipped/error.
- [ ] Run `pwsh -NoProfile -File tests/governed-release-behavior.ps1`; confirm the missing implementation failures.
- [ ] Implement streaming SHA-256 verification with bounded memory and safe path resolution. Validate authority identity and approval independently of bundled metadata. Generate only reviewed template/parameter directives and local `FROM` from verified inputs; do not run source scripts.
- [ ] Protect staging from modification during use, or fail if the platform cannot provide the required permission/locking boundary. Unit tests must exercise mutation attempts and ensure no runtime invocation can follow failure.
- [ ] Run behavior tests; require PASS. Record scanner size/format coverage as policy evidence, not inference from file extension or a zero-exit stub.

## Task 4: Local model import and alias registration

**Files:** Create `scripts/import-governed-model.ps1`, `scripts/governance/import.ps1`, `tests/governed-import-behavior.ps1`. Reuse existing alias/profile/API conventions in `scripts/model-lab.ps1` and `scripts/common.ps1` without changing standalone behavior. Modify shared code only if necessary and add regression coverage for the changed contract.

**Interfaces:** `import-governed-model.ps1 -ManifestPath <file> -BundlePath <directory> -Alias <name> -Profile <cpu|nvidia> -ConfigPath <file> -ReceiptDirectory <path> [-CheckOnly]`. `-CheckOnly` performs approval/bundle/profile validation without model creation or alias mutation. Physical names derive from immutable release identity and never overwrite existing models. Import receipts use Task 1's schema.

- [ ] Write failing tests proving every Task 3 rejection makes zero Ollama/LiteLLM mutation calls; native profile rejection happens before mutation; and protected/existing aliases are refused.
- [ ] Add failure/retry tests: Ollama create failure, smoke failure, alias-registration failure, duplicate release, concurrent import, receipt-write failure and restart recovery. Existing/shared models are never deleted. A repeated completed release/alias returns its existing receipt only after re-verification, or a clear conflict.
- [ ] Run `pwsh -NoProfile -File tests/governed-import-behavior.ps1`; confirm expected failures.
- [ ] Implement a release-level lock, preflight writable receipt destination, verified local create, synthetic smoke check, alias registration and durable receipt. Write a pending receipt before mutation and update it atomically through completion/failure so recovery can reconcile interrupted operations. Do not invoke `pull` or automatically promote default aliases.
- [ ] Run new tests plus `pwsh -NoProfile -File tests/model-lab-contract.ps1`, `pwsh -NoProfile -File tests/model-lab-behavior.ps1` and `pwsh -NoProfile -File tests/privacy-contract.ps1`; require PASS.

## Task 5: Enterprise acquisition implementation and qualification

**Files:** Add approved deployment-specific assets under `governance/mulesoft/` and acquisition-host assets under `governance/acquisition/` only after platform choices are confirmed. Add `tests/governance-acquisition-integration.ps1` for explicit opt-in live tests. Do not add a production-looking always-approved scanner.

**Interfaces:** Implement Task 1's OpenAPI and schemas. Download adapters consume validated provider identifiers and produce quarantined artifacts/provenance; scanners produce tool/version/format/size/status evidence; approval service emits authenticated immutable releases and current revocation status.

- [ ] Confirm Mule product/version/entitlements, hosting/connectivity, IdP, secret management, job persistence, storage, scanner coverage, approval ownership and retention. Record choices as an ADR amendment before deployment-specific implementation.
- [ ] Write and run failing adapter/workflow tests for immutable identity, rejected source, redirect to metadata/private address, interrupted transfer, oversized/unsupported input, scanner timeout/error, partial scan, unauthorized policy modification, requester self-approval of exceptions and unauthorized promotion/revocation.
- [ ] Implement durable async jobs, Hugging Face pinned-revision and Ollama manifest/blob adapters, isolated quarantine and normalized supported bundles. Validate all source/redirect destinations and never load untrusted code just to inspect it.
- [ ] Integrate qualified scanning, isolated evaluation and versioned automatic policy approval. Route reviewable exceptions to an independent authorized reviewer; mandatory failed checks must not be manually overridden. Keep rejected artifacts unavailable to the release API. Never approve unsupported mandatory coverage.
- [ ] Exercise real authenticated requests with synthetic data; retain job, scan, approval and release evidence. Qualify resumable large-artifact transfer separately before claiming support for hundreds of GB.

## Task 6: Deployment, compatibility evidence and runbook

**Files:** Create `docs/governance.md`; update `docs/README.md`, `docs/privacy.md`, `docs/security.md`, `docs/models/manage-models.md` and the existing `.github/workflows/portability-contract.yml` when software lands. Deploy the optional admin/coordinator project in `compose.governance.yml`; document the host-agent service separately from serving containers.

**Interfaces:** Existing setup, Model Lab, Privacy and inference endpoints remain unchanged. New integration tests are opt-in, parameterized and never provision real infrastructure implicitly.

- [ ] Add tests that missing/invalid MuleSoft configuration does not affect standalone commands, default Compose files or inference routing. Test governed settings precedence explicitly.
- [ ] If Compose is added, render configuration and verify distinct project/container names, no serving-network attachment, no Docker socket, no production-volume mount and no removal during existing `setup.ps1` lifecycle. Require these checks in CI.
- [ ] Add offline-cache/image preparation, trusted transfer, import/recovery, approval expiry/revocation, already-serving revocation, incident response and rollback procedures. Rollback never enables Internet or removes volumes automatically.
- [ ] Run the existing portability CI checks and new offline fixture checks. Record exact commands/results; do not claim Windows/Linux/macOS runtime coverage from static rendering.
- [ ] On an explicitly selected test host, import one small supported real approved GGUF with outbound denied; test chat, API streaming, alias/key scope, restart and model-init expectations. Ensure pre-existing required default models are prepared.
- [ ] Verify firewall logs and direct outbound failure for host, Docker, nginx, DNS and IPv6; approved internal authority/artifact access must succeed. Run existing `scripts/verify-privacy.py` and profile-appropriate `scripts/verify-stack.ps1` on the deployed stack. Keep their existing local-only route checks.
- [ ] Publish an evidence matrix marking local fixture tests, real runtime tests, Mule integration, scanner coverage and infrastructure controls separately as passed/pending/failed. Update ADR status only after detailed design review; record implementation/qualification status separately.

## Task 4A: Durable automated delivery and host agent (Stage A)

Execute after Task 4 and before Tasks 5/6. This is required for the one-request experience; importing a bundle manually is not Stage A completion.

**Files:** Create `governance/coordinator/`, `scripts/governance-agent.ps1`, `scripts/governance/delivery.ps1`, `tests/governance-delivery-behavior.ps1` and `governance/contracts/delivery-job.schema.json`. Choose a minimal coordinator implementation and pinned dependencies during implementation, recording the choice; persistence must support atomic state updates and concurrent lease ownership.

**Interfaces:** `governance-agent.ps1 -TargetId <id> -ConfigPath <file>` runs a cancellable management loop against authenticated internal job claim/heartbeat/result APIs. It invokes Task 4 locally with a fenced job lease; only this target's approved releases can be claimed. The coordinator owns jobs/checkpoints, not the CLI or browser. Define exact claim/result fields and lease/fencing rules in Task 1's OpenAPI before implementation.

- [ ] Write failing tests for one request reaching `ready`, automatically approved eligible policy, reviewable exception waiting, mandatory scan failure rejection, target/group unauthorized, insufficient disk/runtime preflight failure and reused approved release with current revocation check.
- [ ] Add restart/disconnect, expired lease/stale agent, concurrent delivery, transfer resume, bounded retry/backoff and cancellation tests. Assert no duplicate aliases, overwrites, premature `ready` or deletion of shared data.
- [ ] Define checkpoint reconciliation for every side effect, including model creation and Workspace Model/group grant. Verify caller-supplied group access against server policy; never expand existing keys or default aliases. Failed grants leave an explicit failed step and no availability to the requested group.
- [ ] Implement the coordinator and host agent using Tasks 1–4, with injected fixture acquisition/scanner/runtime boundaries for local tests. Real scan results cannot be replaced by fixtures in production mode. Install the agent explicitly as an OS service/scheduled worker; do not add a privileged Docker container.
- [ ] Run `pwsh -NoProfile -File tests/governance-delivery-behavior.ps1`; require PASS including restart recovery and requested-group availability verification.

## Task 4B: Admin demand form and progress view (Stage A)

Execute after Task 4A and before Tasks 5/6. The optional interface is separate from default PocketMind startup and uses the coordinator API, not a second workflow implementation.

**Files:** Create `governance/admin/`, `compose.governance.yml` and behavior tests under `tests/governance-admin/`. Use a minimal server-rendered interface unless repository review identifies a better existing integration; record the selected implementation before writing UI code.

**Interfaces:** An authenticated admin form submits provider/model or recognized link, version/quantization, alias, target, authorized group and purpose. A job page displays the durable checklist, current step, real byte progress where available, waiting/failure reason and authorized retry/cancel actions. Initial POC may use fixture targets/groups but must visibly identify fixture mode. Production requires an approved identity integration and no anonymous administrative access.

- [ ] Write behavior tests for unauthorized submission/status/action, invalid input, double submit idempotency, refresh/disconnect recovery, indeterminate download progress, awaiting exception review, retry/cancel and `ready` only after verified group availability. Protect state-changing browser requests against CSRF and render provider/error text safely.
- [ ] Implement views against Tasks 1/4A. Do not require manual file copy, commit lookup, import command or grant assignment on the normal eligible path. Secrets, upstream signed URLs and internal stack traces never appear in the browser.
- [ ] Verify both one-command submission and form submission use the same state machine. Record visual/manual UI checks and automated behavior results separately. Verify standalone setup does not start the governance project.

## Stop conditions and change control

Do not weaken Privacy mode to fix connectivity; do not convert standalone startup into an integration client; do not treat an unsupported GGUF as scanner-approved; do not add cloud fallback or another inference runtime under this plan. Surface the requirement and amend the ADR when these boundaries need to change.

Stage A can be completed without organizational access. Stages B/C remain explicitly pending until real deployment inputs and test systems are available; a local mock cannot close them.
