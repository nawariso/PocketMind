# PocketMind Documentation

This directory separates current operational knowledge from historical implementation artifacts.

## Authoritative current-state documentation

Use these documents for the running system:

- [Architecture](architecture.md) — components, request paths, profiles, persistence, and trust boundaries.
- [Operations runbook](operations-runbook.md) — startup, verification, model lifecycle, diagnostics, and emergency procedures.
- [Security](security.md) — credentials, localhost-only policy, access control, tunnels, and incident response.
- [Backup and restore](backup-and-restore.md) — what state matters and how to preserve or restore it.
- [Troubleshooting](troubleshooting.md) — symptom-oriented diagnosis and recovery.

## Model knowledge

- [Model catalog](models/catalog.md) — production and retired models, exact identifiers, settings, and constraints.
- [Evaluation guide](models/evaluation-guide.md) — repeatable quality and hardware-fit evaluation.
- [Benchmark log](models/benchmark-log.md) — measurements already observed on the reference laptop.

## Decisions

Architecture decision records explain choices that should survive implementation changes:

- [0001 — Stable model aliases](decisions/0001-stable-model-aliases.md)
- [0002 — Typhoon for OCR](decisions/0002-typhoon-for-ocr.md)
- [0003 — Database-backed Model Lab](decisions/0003-database-backed-model-lab.md)

## Historical implementation plans

`docs/superpowers/plans/` and `docs/superpowers/specs/` are historical implementation plans and design snapshots. They preserve development context but are not authoritative current-state documentation. They may contain completed checklists, superseded model IDs, or architecture that predates later changes. When they disagree with the root README, current config, tests, or the documents above, use the current config/tests and this authoritative set.

## Update policy

Update the relevant document in the same change when modifying:

- service topology or ports;
- profiles, persistence, or trust boundaries;
- production model IDs or capabilities;
- backup/restore behavior;
- operational commands or incident procedures;
- an architectural decision and its consequences.

Runtime measurements belong in `models/benchmark-log.md`; reusable evaluation procedure belongs in `models/evaluation-guide.md`; quick-start commands remain in the root README.
