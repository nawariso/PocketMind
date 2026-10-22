# ADR 0004: Self-Service Virtual Keys Through Open WebUI

- Status: Accepted

## Context

Pilot users should work in one system, Open WebUI, but some also need an API key to call local models from their own tools. Open WebUI reaches LiteLLM with the master key, so Open WebUI's own API keys would put every user under one LiteLLM identity and prevent per-user limits.

## Decision

Provide an Open WebUI Pipe, `openwebui/functions/api_key_manager.py`, installed with `scripts/install-key-manager.ps1`. It appears as the model "API Key Manager" and understands only fixed commands: `models`, `new <model> [as <label>]`, `list`, `rotate <alias|model>`, `revoke <alias|model>`, `help`, and the administrator-only `sync`. No language model is involved.

Each key is limited to exactly one model, chosen by the user from the current LiteLLM catalog, and a user may create several keys for the same model, for example one per application, each with an optional label. By default, `auto_discover_models=true` reads aliases from `/v1/models` for each `models` or `new` command, so new Model Lab aliases need no Valve change. Administrators can disable discovery and use the explicit `allowed_models` Valve instead. The total per user is capped (default 20, a Valve). With several keys for a model, `rotate` and `revoke` take the key's alias; `revoke <model> all` removes every key for that model. A key is bound to the user's Open WebUI user ID and has a mandatory expiry, requests-per-minute and tokens-per-minute limits, and a concurrency limit. Limits and discovery mode are administrator Valves.

Usage is attributed to teams, and LiteLLM teams are the single place to manage them. A user belongs to a team when their email, or Open WebUI user ID, is a member of the LiteLLM team (add members by email in the LiteLLM UI). The key carries that team ID. A user in several teams must name one (`new <model> <team>`); a user in none uses the `unassigned` team. Members the Pipe never added cannot be moved with `key/update` later (LiteLLM rejects it), so a key's team is fixed when it is created or rotated.

Each LiteLLM team is mirrored to an Open WebUI group of the same name, with members matched by email. Sync only creates and updates groups it marked with `litellm_team_id`; a hand-made group of the same name is never overwritten, and groups of deleted teams are reported, not deleted. The mirror runs when an administrator types `sync` and automatically, at most every 10 minutes (Valve), when anyone uses the key manager. `sync` also lists keys whose owner left the team so those users can `rotate`.

Open WebUI hides models from non-admin users until an access grant exists, and new accounts start as `pending` unless the default role is changed. The installer can grant selected models to every signed-in user (`-PublicModels`), and the default role is an Admin Settings choice. Auto-approval is safe only while account creation is controlled: with open sign-up, anyone who can reach Open WebUI would receive chat access and could create API keys.

## Consequences

LiteLLM Logs and Usage identify each request by key alias and user ID. Cost views stay at zero until real prices exist. Newly registered aliases become available for new key requests automatically; existing keys remain scoped to their original model. Automatic discovery reads the service's master-key catalog and does not mirror Open WebUI model grants, so registering an alias is a decision to offer it for self-service API use. Disable discovery for a restricted manual catalog. Empty catalogs and failed discovery never generate unrestricted keys. Deleting a LiteLLM team deletes its keys (observed when a team created for a test was removed), so removing the `unassigned` team revokes its keys. Sync reports stale team memberships; it does not move keys automatically.

Users call LiteLLM directly with their key, so other machines reach it through the nginx proxy of ADR 0005, which forwards only the `/v1` inference paths and never `/ui`, `/key`, or `/model`.
