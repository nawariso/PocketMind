# ADR 0003: Database-Backed Model Lab

- Status: Accepted

## Context

Trying a new Ollama model previously required editing `litellm/config.yaml`, restarting LiteLLM, and reverting production config. That made experiments risky and created unnecessary config churn.

LiteLLM supports database-backed model management, and PocketMind already uses PostgreSQL.

## Decision

Enable database model storage and provide `scripts/model-lab.ps1` with four actions:

- `add` — pull/show an exact tag and register a `lab-*` alias;
- `list` — inspect lab mappings;
- `test` — run a bounded deterministic text test;
- `remove` — remove the alias, optionally removing safe unshared weights.

Production aliases remain in version-controlled config. Model Lab aliases persist in PostgreSQL across LiteLLM restarts.

## Safety constraints

- Enforce the `lab-*` namespace.
- Validate exact Ollama tag syntax.
- Derive protected physical models from production config.
- Refuse production/shared weight deletion before removing an alias.
- Attempt deployment rollback if post-create discovery verification fails.
- Treat all safeguards as client-side; the LiteLLM master key can bypass them.
- Do not grant ordinary Open WebUI users automatic access.

## Consequences

- Experiments are faster and reversible without LiteLLM restart.
- PostgreSQL backup now preserves Model Lab aliases.
- Master-key protection becomes more important because management APIs are enabled.
- The built-in test proves text chat only; capability-specific tests remain separate.

## Alternatives considered

- Wildcard passthrough: rejected because it exposes arbitrary model names without controlled lifecycle/discovery.
- Rewrite static config per experiment: rejected for restart/config-churn risk.
- Expose Ollama directly in Open WebUI: rejected because it bypasses the gateway/access/metrics architecture.

## Rollback

Remove all `lab-*` aliases, disable database-backed model management if no DB-managed features remain, recreate LiteLLM, and verify only production aliases are exposed. Preserve a PostgreSQL backup before changing storage behavior.
