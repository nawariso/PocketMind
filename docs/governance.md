# Optional governed model delivery

## Current delivery

The opt-in **synthetic POC** implements the administrator workflow in [ADR 0006](decisions/0006-optional-governed-model-import.md). Submit one demand; a durable job drives acquisition, policy, installation, registration and an explicit group grant. Closing the browser does not stop it.

The shipped coordinator does **not** download real models, perform real security scans, contact MuleSoft or install into the existing PocketMind stack. It accepts only two named synthetic models and labels every screen accordingly. A separate real Ollama/LiteLLM/Open WebUI adapter exists for integration work, refuses fixture manifests and needs a trusted real authority plus live qualification before organizational use.

Default Compose, standalone Model Lab, profiles, inference routing and Privacy mode remain unchanged. Governance settings are loaded only by new management commands. No pip packages are required for the new application: Python 3.11+ standard library only.

## Try the admin workflow

On Windows, use PowerShell 7 from the repo root:

```powershell
$env:POCKETMIND_GOV_ADMIN_TOKEN = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
$env:POCKETMIND_GOV_AGENT_TOKEN = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
# Optional: copy the admin token to sign in; never paste it into chat/logs.
$env:POCKETMIND_GOV_ADMIN_TOKEN | Set-Clipboard
pwsh ./scripts/start-governance.ps1 -Fixture
```

Open `http://127.0.0.1:8787/jobs`, sign in with that token, and request:

| Field | Hugging Face fixture | Ollama fixture |
|---|---|---|
| Model ID | `pocketmind-fixtures/tiny-gguf` | `pocketmind-fixture:tiny` |
| Revision | `main` | `latest` |
| Artifact | `model.gguf` | `model.gguf` |
| Alias | Any new unprotected alias | Any new unprotected alias |
| Target / group | `local` / `testers` | `local` / `testers` |

Select **Request model** once. The page refreshes every two seconds and displays the full checklist. `ready` means the synthetic runtime has the alias and requested group grant; no real LLM was installed. For another alias, try revision `review-required` (policy exception waits) or `scan-error` (mandatory failure is rejected). No approve/bypass button exists in this fixture.

Stop with Ctrl+C and restart using the same state directory/secrets to retain jobs and receipts. Sign in again after restart. State defaults to git-ignored `.governance-state/demo/`; keep it private. Clipboard contents remain the operator's responsibility.

The portable Python equivalent is `python -m governance serve --fixture --embedded-agent`, after setting the same secrets through your approved secret mechanism. This local POC HTTP server is not a public enterprise admin portal. Shared service-token sign-in is not SSO or per-person audit attribution.

## Optional separate Compose project

```powershell
Copy-Item .env.governance.example .env.governance
# Edit the private copy: two distinct random 32+ character secrets, no placeholders.
docker compose --env-file .env.governance -f compose.governance.yml up -d --build
```

Never combine this file with serving Compose files. Project `pocketmind-governance` publishes only loopback port 8787, uses its own internal network/volume and has no Docker socket or serving mounts. Image build needs an approved source for the Python base image. The POC base uses a tag; production qualification must pin an approved digest.

Stop only this project with `docker compose --env-file .env.governance -f compose.governance.yml down`. Do not add `-v` if history must be preserved. Existing serving setup's `--remove-orphans` operates on its separate project.

## CLI and separate agent

The CLI and browser use the same job API. With the coordinator running and credentials in the CLI session:

```powershell
pwsh ./scripts/model-acquisition.ps1 request -ConfigPath governance/config.example.json `
  -Source huggingface -ModelId pocketmind-fixtures/tiny-gguf -Alias fixture-api `
  -TargetId local -AccessGroupId testers -Purpose 'Synthetic POC' -IdempotencyKey poc-request-001
pwsh ./scripts/model-acquisition.ps1 status -ConfigPath governance/config.example.json -JobId <returned-job-id>
```

Reuse an idempotency key for the identical demand after a lost response. Conflicting demands or target aliases fail. Status exposes checkpoints, timestamps, measured byte progress or unknown totals, sanitized errors and release ID, never a lease/credential.

Transient failures automatically retry with 2/4/8-second backoff, at most three retries; rejection/review never auto-approves. Manual retry shares that budget. `model-acquisition.ps1 retry` or `cancel` takes `-ConfigPath` and `-JobId`. Cancellation is cooperative at checkpoints and preserves completed effects, including any grant already applied; it is not a transactional rollback.

To test a separate process, start Python `serve --fixture` without `--embedded-agent`, then run:

```powershell
pwsh ./scripts/governance-agent.ps1 -ConfigPath governance/config.example.json -Fixture
```

The agent downloads approved synthetic files through authenticated HTTP. Use one host-owned state directory per target; do not run embedded and separate agents for the same target with different state directories. Cross-process locks protect local side effects, 10-second heartbeats renew 60-second leases, and stale/cancelled workers cannot write checkpoints.

## Real integration boundary

Copy `governance/config.example.json` to ignored `governance/config.local.json`. Configure a real HTTPS authority, target ID, actual group IDs, local `allowed_groups` and secret **environment variable names**, never secret values. The authority implements [OpenAPI v1](../governance/contracts/acquisition-api.yaml), including target-bound credentials and current approval/revocation checks. TLS is verified; redirects and ambient proxy variables are not used. Explicit `test_loopback_http` permits only loopback test HTTP.

The real agent omits `-Fixture` and calls loopback management APIs without Docker access. Release runtime version must match the qualified Ollama version exactly. Only supported single-file GGUF bundles are in this increment; arbitrary HF architectures, split weights, vision projectors and native governed import require further work. Existing API keys retain their model scopes.

Lower-level integration/recovery command (not a per-model admin task):

```powershell
pwsh ./scripts/import-governed-model.ps1 -ConfigPath governance/config.local.json `
  -ManifestPath <approved-manifest.json> -BundlePath <bundle-directory> `
  -Alias <new-alias> -AccessGroupId <approved-group-id> -Profile nvidia -CheckOnly
```

`-CheckOnly` validates current authority approval, exact manifest, files, runtime and group/alias compatibility without installation. Removing it enables privileged import, short synthetic inference, registration and the requested group grant. No public pull is called. This path needs live qualification before real use.

## Recovery and operations

- Back up the private governance state directory/volume: SQLite job history, releases and atomic import receipts are audit records. Retention expiry, encryption-at-rest and HA coordination are deployment work.
- Keep source credentials only in acquisition infrastructure. Configure real identity, audit ownership, approval policy and qualified scanners before Stage B; fixtures cannot satisfy these controls.
- Failed registration/grants never delete shared or existing weights. Inspect receipts before retry; never bypass failure by pulling directly on a managed serving host.
- Revocation prevents new imports. Already-serving revocation is an explicit incident operation: remove user access/aliases deliberately, unload the affected model and preserve evidence. Automatic runtime revocation is not implemented.
- Rollback stops only the governance agent/project and preserves serving networks, `.env`, volumes, keys and aliases. It never reopens Internet automatically.
- Host/Docker administrators and master-key holders remain privileged. Restrict management access/PAM; this integration does not sandbox a malicious host administrator.

## Evidence and remaining deployment work

| Capability | Evidence / boundary |
|---|---|
| Contracts, immutable identity, paths, integrity and authority comparison | Automated tests |
| Durable jobs, leases, idempotency, retry and cancellation | SQLite behavior tests |
| Import/recovery, grants and ready state | Fixture and HTTP boundary tests |
| Admin auth/CSRF and separate-agent delivery | Actual loopback HTTP / subprocess tests |
| Existing standalone/Privacy compatibility | Existing regression tests; executed results in ledger |
| Separate Compose isolation | Rendered config; container image build/run separate |
| Real MuleSoft, remote download, scanning, IdP and policy | **Stage B pending organizational inputs** |
| Live runtime/user-group discoverability, performance, firewall/DNS/IPv6 | **Stage C pending selected test host** |

Run `python -X utf8 -m unittest discover -s tests -p 'test_governance_*.py' -v`. See [implementation progress](../governance/IMPLEMENTATION.md) and [Privacy preparation](privacy.md). Tests do not certify external models or a deployed firewall.
