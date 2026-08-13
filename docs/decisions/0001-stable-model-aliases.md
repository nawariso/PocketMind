# ADR 0001: Stable Model Aliases

- Status: Accepted

## Context

Physical Ollama tags change as models are evaluated or replaced. Open WebUI, API clients, tests, and user access rules should not need to change every time the underlying model changes.

## Decision

Expose workload-oriented stable aliases through LiteLLM:

- `corp-general` for general text/reasoning/coding/tools;
- `corp-ocr` for document OCR;
- `lab-*` for experiments only.

Physical model changes occur behind the stable production aliases after benchmark, contracts, runtime verification, review, and rollback preparation.

## Consequences

- Clients remain stable while physical models evolve.
- Capabilities must be managed per alias; OCR cannot inherit general-tool assumptions.
- Documentation and tests must record exact physical mappings.
- Model Lab experiments cannot silently promote themselves.

## Alternatives considered

- Expose raw Ollama tags directly: simpler initially, but couples clients/access rules to model churn.
- Use one alias for all workloads: rejected because OCR and general models have incompatible capabilities and performance profiles.

## Rollback

Restore the previous exact physical mapping, ensure weights exist, recreate/reload LiteLLM as required, then rerun smoke and workload-specific tests.
