# Optional governance POC

See [the runbook](../docs/governance.md), [ADR 0006](../docs/decisions/0006-optional-governed-model-import.md) and [delivery ledger](IMPLEMENTATION.md).

Python 3.11+ standard library only; no serving service imports this package.

- `contracts.py`: runtime validation alongside published JSON schemas.
- `jobs.py`: durable checkpoints, target leases, idempotency and bounded retry.
- `server.py`: optional synthetic acquisition API and authenticated admin UI.
- `delivery.py`: unattended delivery and explicitly named fixture implementations.
- `http.py`: internal authority and resumable approved-file transfer.
- `importer.py`, `files.py`, `runtime.py`: private staging, receipts, locks and local management APIs.
- `settings.py`, `cli.py`: explicit management-only settings and CLI.
- `contracts/`: versioned contract for a future real MuleSoft implementation.

The POC HTTP server and shared-token sign-in are for isolated local testing, not public production hosting.
