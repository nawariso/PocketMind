# Governed model import delivery ledger

Plan: `docs/superpowers/plans/2026-10-28-governed-model-import.md`

- [x] ADR and automation amendment reviewed by user; execution authorized 2026-10-28.
- [x] Feature branch: `feat/optional-governed-model-import` (existing checkout; sandbox permits workspace writes and branch creation was approved).
- [x] Versioned contracts, validation and optional configuration.
- [x] Acquisition client and fixture authority.
- [x] Bundle verification and protected staging.
- [x] Local runtime import, alias registration and access provisioning (HTTP boundary tests; live runtime pending).
- [x] Durable automated delivery, retries, leases and recovery.
- [x] Optional admin interface and progress view (HTTP behavior tests; browser visual inspection pending because CUA runtime failed to initialize).
- [x] Regression verification and independent review (Windows development host; CI matrix configured, not executed here).
- [ ] Real MuleSoft/scanner/storage integration — requires organizational deployment inputs.
- [ ] Live serving-host/firewall qualification — requires selected test host.

## Rulings and evidence

- Ruling: implement shared coordinator/validation/import behavior in Python 3.11+ standard library, with PowerShell entrypoints. SQLite gives durable atomic jobs without adding dependencies to serving containers; a server-rendered admin UI avoids a separate frontend toolchain. No changes to default startup. Cost: management hosts need Python in addition to PowerShell.
- Ruling: Stage A uses an unmistakably labelled synthetic fixture acquisition backend; real download/scanning adapters are Stage B and must not be silently substituted. An eligible fixture demonstrates the full automated workflow but cannot load a real model.
- Ruling: prefer Ollama's loopback HTTP blob/create APIs over Docker exec. This requires no Docker socket or external serving network. The real runtime adapter is qualified with boundary tests; live model/OS qualification remains pending.
- Pre-flight: Tasks 1/2 supply API and release identity to Tasks 3/4; Tasks 4A/4B supply durable jobs and UI. Approval lifecycle is separate from overall `ready`; grants are required for readiness. No conflicting default inference changes.
- Baseline: UTF-8 resolves Windows cp874 subprocess decoding failures. Existing Python privacy tests pass; full Python discovery initially blocked by missing pydantic (existing key-manager dependency). PowerShell 7 executable requires approved execution outside sandbox.
- Ruling: tasks are implemented as shared Python modules with executable behavior tests rather than duplicated `.ps1` library logic. The published PS entrypoints retain operator-friendly invocation; the implementation plan now records the chosen stack. Cost: management hosts require Python 3.11+; no new serving dependency.
- Ruling: real acquisition policy/scan/storage integration, organization identity, OS service installation and live model/firewall checks remain Stage B/C. Synthetic `ready` is labelled everywhere and is not production readiness. Costs if ignored: falsely trusting an unqualified deployment; runbook/evidence table retain explicit pending status.
- Final review: independent read-only reviewer found Windows explicit-ACL retention (P1), uncertain-create recovery (P2), and release authorization limited by UI pagination (P2). All have dedicated regression reproductions; fixes replace complete owner-checked DACLs including existing descendants, reconcile owned local models by approved manifest/blob provenance, and use an unpaginated target/release lookup.
- Final review declined-to-judge ruling: real Mule/scanner/provider enforcement, live loading/user discoverability, deployed TLS/firewall/OS qualification are intentionally deferred to Stages B/C; docs/CI are completed by the implementer and verified separately. Cost if treated as delivered: missing enterprise controls; documentation explicitly marks them pending.
- No deferred minor review findings.

## Final verification (2026-10-29)

- `python -X utf8 -m unittest discover -s tests -p 'test_*.py'` with existing pydantic dependency supplied from ignored temporary test storage and `GOV_RUN_PWSH_TESTS=1`: **75 tests, 74 passed, 1 skipped** (POSIX symlink case on Windows). Includes separate-agent HTTP and real PowerShell request/status wrappers.
- All 11 local PowerShell contract/behavior scripts other than the network image-manifest check passed in separate processes: configuration, documentation, key manager, Model Lab contract/behavior, Privacy, profile, provisioning, proxy, rename and portability. The image-manifest check also passed earlier in the session.
- Existing proxy contract reports `nginx -t` skipped because its image could not run. No claim of live nginx/container deployment verification.
- `python -X utf8 -m compileall -q governance`: passed. `git diff --check`: passed. New Markdown relative links and three JSON contract files parsed successfully.
- `compose.governance.yml` rendered with a separate project, loopback publication, internal network and independent state volume; no serving mounts or Docker socket. No container image build/run was performed.
- Final review regressions: explicit Windows Everyone ACL removal (including existing files), lost model-create response recovery, release authorization beyond 100 recent jobs, and deterministic receipt identity all passed. Recovery revalidates model provenance rather than trusting a completed receipt alone.
- Browser visual inspection could not run: the CUA Node runtime failed to initialize. Admin pages were verified through actual HTTP/auth/CSRF/form/progress tests; visual appearance is not independently browser-qualified.
- Integration status: source downloads/scanners/MuleSoft and real user-group/live inference/firewall qualification remain unchecked above. No external application, production service, model weights or user grants were changed.
- Work is preserved on `feat/optional-governed-model-import`; no production deployment was performed. Commit/push requested by the user for cross-machine continuation on 2026-10-29.

## Resume on another machine

- User has one server, MuleSoft DEV access, and ample storage; the user is the administrator who will deploy the APIs.
- Next design discussion: colocate acquisition worker/scanner/publisher as separately networked containers while keeping the existing serving Compose/Privacy boundary unchanged. This topology has been discussed, not implemented or runtime-qualified.
- Clarify whether ALL file transfer must pass through MuleSoft, or only the authorized download worker may have destination-restricted Internet egress. Containers share a host/NAT identity; a plain upstream allow-list cannot necessarily distinguish them.
- Need server OS and Docker Engine versus Docker Desktop. Need Runtime Manager DEV application target/runtime/endpoint and API Manager endpoint/authentication policies (no secrets).
- Scanner product/format/size coverage remains unknown. Storage capacity is available, but Quarantine/Approved access separation and release policy still need configuration.
- Read `docs/governance.md` to run the synthetic POC. Do not mistake synthetic ready/scan results for real model approval or live installation. Existing standalone behavior is intentionally retained.
