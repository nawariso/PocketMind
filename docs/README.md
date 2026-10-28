# PocketMind Documentation

This directory separates current operational knowledge from historical implementation artifacts.

## Authoritative current-state documentation

Use these documents for the running system:

### Installation and server changes

- [Getting started](getting-started.md) — platform support, profiles, prerequisites and manual installation.
- [Updating a server](server-update.md) — preserve `.env`/volumes, migrate YAML tuning, pull safely, apply aliases/Functions and verify.
- [Tuning](tuning.md) — two-L40S baseline, context/concurrency/GPU tradeoffs, commands and workload measurements.

### User access and models

- [Network access](network-access.md) — service ports, firewall handoff, proxy, direct access, DBeaver and temporary test tunnels.
- [Rename a model](models/rename-models.md) — change WebUI/API naming while retaining old aliases and key scopes.
- [Model management](models/manage-models.md) — Model Lab commands, arbitrary aliases, Hugging Face artifact compatibility and model access.
- [API access](api-access.md) — automatic model discovery, scoped keys, IDE setup, tools and rate-limit boundaries.
- [Open WebUI](open-webui.md) — accounts, regular-user grants, Task Model and the exact OCR prompt.
- [Monitoring](monitoring.md) — dashboards, exporters, benchmark and usage interpretation.

### Operations, privacy and recovery

- [Architecture](architecture.md) — components, request paths, profiles, persistence, and trust boundaries.
- [Provisioning guide](provisioning-guide.md) — the ordered steps to bring up a new server, how to check it, what to do by hand afterwards, and a checklist.
- [Operations runbook](operations-runbook.md) — startup, verification, model lifecycle, native macOS Ollama and host monitoring, master-key rotation, API Key Manager, shared pilot proxy, usage reports, diagnostics, and emergency procedures.
- [Security](security.md) — credentials, backend exposure policy, the shared pilot proxy, accounts and sign-up, API keys, tunnels, and incident response.
- [Local data and privacy controls](privacy.md) — cloud/reporting defaults, isolated serving mode, preparation and infrastructure requirements, verification and limits.
- [Optional governed model delivery](governance.md) — synthetic admin POC, durable progress, automation and real MuleSoft/scanner deployment boundaries.
- [Backup and restore](backup-and-restore.md) — what state matters and how to preserve or restore it.
- [Troubleshooting](troubleshooting.md) — symptom-oriented diagnosis and recovery.
- [Server deployment checklist](server-deployment-checklist.md) — what was verified for a shared pilot on a server, what must be done first, and the known limits.

## Model knowledge

- [Model catalog](models/catalog.md) — production and retired models, exact identifiers, settings, and constraints.
- [Evaluation guide](models/evaluation-guide.md) — repeatable quality and hardware-fit evaluation.
- [Benchmark log](models/benchmark-log.md) — measurements already observed on the reference laptop.

## Decisions

Architecture decision records explain choices that should survive implementation changes:

- [0001 — Stable model aliases](decisions/0001-stable-model-aliases.md)
- [0002 — Typhoon for OCR](decisions/0002-typhoon-for-ocr.md)
- [0003 — Database-backed Model Lab](decisions/0003-database-backed-model-lab.md)
- [0004 — Self-service virtual keys through Open WebUI](decisions/0004-self-service-virtual-keys.md)
- [0005 — Shared pilot access through an nginx HTTP proxy](decisions/0005-shared-pilot-nginx-proxy.md)
- [0006 — Optional governed model import with MuleSoft](decisions/0006-optional-governed-model-import.md) — accepted target state; synthetic POC delivered, real enterprise integration pending.

## Active design and implementation work

- [Governed model import plan](superpowers/plans/2026-10-28-governed-model-import.md) — target state, execution checklist and remaining enterprise integration work. Use the governance runbook for the delivered synthetic POC; this plan is not a production server operating procedure.

## Historical implementation plans

Except for work explicitly listed as active above, `docs/superpowers/plans/` and `docs/superpowers/specs/` are historical implementation plans and design snapshots. They preserve development context but are not authoritative current-state documentation. They may contain completed checklists, superseded model IDs, or architecture that predates later changes. When they disagree with the root README, current config, tests, or the documents above, use the current config/tests and this authoritative set.

## Update policy

Update the relevant document in the same change when modifying:

- service topology or ports;
- profiles, persistence, or trust boundaries;
- production model IDs or capabilities;
- backup/restore behavior;
- operational commands or incident procedures;
- an architectural decision and its consequences.

Runtime measurements belong in `models/benchmark-log.md`; reusable evaluation procedure belongs in `models/evaluation-guide.md`; quick-start commands remain in the root README.
