# Rename a model while preserving existing API clients

Run [scripts/rename-model.ps1](../../scripts/rename-model.ps1) **on the server**, from the deployed repository. It adds a new LiteLLM alias and changes the matching Open WebUI display name while keeping the old API alias alive. It supports local `ollama_chat` routes in this repository, including the initial defaults and DB-backed custom models.

This is a compatibility rename, not a global replacement of every stored identifier. Existing API clients keep their original model string and key. Removing that original alias would break them, so the script never removes it.

## Preview and apply

Back up PostgreSQL/Open WebUI as in [Backup and restore](../backup-and-restore.md). Keep other administrators from editing these model records during the operation. Ollama, LiteLLM, PostgreSQL and Open WebUI must be healthy; no image/model download or service restart is needed.

Use the **LiteLLM alias**, not an arbitrary WebUI display label, as `-OldAlias`. Inspect aliases with `pwsh ./scripts/model-lab.ps1 list -Profile auto` for custom models; initial aliases are in `litellm/config.yaml`.

```powershell
# Preview: signs in and reads configuration, but does not change model records/routes.
pwsh ./scripts/rename-model.ps1 -OldAlias default-general -NewAlias Pocket-General -AdminEmail admin@example.com -WhatIf

# Apply the same plan.
pwsh ./scripts/rename-model.ps1 -OldAlias default-general -NewAlias Pocket-General -AdminEmail admin@example.com
```

Use your actual administrator email. The password comes from `OPENWEBUI_ADMIN_PASSWORD`, the matching bootstrap account in the private `.env`, or an interactive secure prompt. Do not pass passwords or the master key as command arguments. Management calls use loopback `4000` and `3000`, including in Privacy mode; use `-OpenWebUiUrl http://localhost:8480` if the local UI management route is the proxy instead. Remote URL origins are rejected.

Aliases may contain letters/numbers (including Thai), `.`, `_`, `:`, `/`, `-`, start with a letter/number, and have at most 128 characters. Spaces, wildcards and case-only renames are rejected. Choose a distinct unused name. Multi-deployment/load-balanced aliases and nonstandard/credential-bearing provider routes require separate review and are rejected.

## What is updated

- **LiteLLM:** creates a DB-backed alias with a new deployment ID, the same physical model, routing parameters and capability metadata. Keeps the original route, including version-controlled defaults, untouched.
- **Open WebUI:** changes the base record's display name, keeping its ID, system prompt, parameters, capabilities, active state and access grants. Exact-name presets referring to that alias are renamed too; independently named curated presets keep their names and base IDs. Earlier rename ancestry is followed, so a later `Pocket-General` → another name can still update the original stable WebUI ID.
- **API Key Manager (v0.6.1+):** new-key requests use current names only. `models` adds a separate legacy section only for the caller's own active keys using an earlier name; a user without those keys sees current names only. Chained renames use the same rule. Expired, blocked, revoked or invalid-expiry keys do not make a legacy name appear. If discovery is disabled and the old alias is in its manual allowlist, the script appends the new alias while retaining every existing setting and old name. If the function is not installed, it is skipped.

If no matching WebUI base record exists, the script creates one with **no public grants**. Review its intended access before sharing. It does not turn an admin-only model into a public model. Admins may see both provider aliases in the picker with similar labels; IDs remain distinct for compatibility.

## What stays stable

- Existing virtual keys and their model scopes, expiry, limits and team restrictions.
- Physical Ollama model tags, weights, context, concurrency, GPU settings and running services.
- Chat history, WebUI model IDs, task/default references and existing clients' model strings.
- Tracked YAML, `.env`, the installed Function source and unrelated workspace presets.

Task/default references retain their stable old IDs, which continue routing successfully. The visible model name changes; rewriting those references is unnecessary for compatibility. The old name intentionally remains in raw LiteLLM `/v1/models` discovery for compatibility, but API Key Manager shows it in `models` only to its active-key owners and rejects `new <old-alias>`. `list`/`status` still show the actual old scope of existing keys, and rotation/revocation continue to work for those keys. Existing key scopes are **not expanded** to the new alias.

## Verify old and new access

1. Refresh Open WebUI. Check a regular user's model name and access, plus an existing conversation and OCR/tool metadata where applicable.
2. Install/update the Function on the server after pulling the updated source:

   ```powershell
   pwsh ./scripts/install-key-manager.ps1 -AdminEmail admin@example.com
   ```

   Existing Valves are preserved; use your actual administrator email. This update is required even if an older Function was already installed: Git/Compose alone do not replace it. No container restart is needed.
3. Send a synthetic request from an existing IDE/API integration using its **unchanged old key and old model alias**. This is the decisive compatibility check for that client; discovery alone is not an inference test.
4. In API Key Manager type `models`, then `new Pocket-General` to obtain a new scoped key. If team policy restricts models, an administrator must separately approve the new alias; the script does not broaden team policy.
5. Test the new key with `model: Pocket-General` against the approved API base URL. An old key scoped to `default-general` is expected to be rejected if used with `Pocket-General`.
6. Confirm both aliases remain in LiteLLM and the old deployment still exists. No restart, model pull or `configure-open-webui.ps1` run is needed for this rename.

The script verifies discovery of both aliases before changing WebUI, then reads updated WebUI records to verify labels/IDs. It does not use or recover a user's secret key and does not perform real inference itself. Runtime checks above must be run on the actual server before claiming compatibility is verified.

## Interrupted operations and undo

Changes span LiteLLM and Open WebUI and are not transactional. If an API call fails, a new alias or some display updates may already exist. The script retains compatibility routes rather than deleting them on failure. Restore service health and rerun the same command; it reuses a matching alias carrying its rename provenance and refuses unrelated collisions or routing drift. Do not run competing renames concurrently.

For undo, restore WebUI display names through its admin UI or a verified backup; leave both API aliases available until all consumers are checked. Retire a new custom alias with Model Lab only after confirming no keys, team scopes, clients or WebUI presets depend on it. Never delete the original compatibility alias while old clients still use it. Full backup restore is a separate maintenance operation and can discard changes made after the backup.

This is a deployment-state change, so Git alone does not transfer it to another server. The aliases live in PostgreSQL and names in Open WebUI data; preserve those volumes on updates. See [server updates](../server-update.md) and [API access](../api-access.md).

Endpoint shapes are based on the pinned Open WebUI v0.11.4 [model router](https://github.com/open-webui/open-webui/blob/v0.11.4/backend/open_webui/routers/models.py) and [Function router](https://github.com/open-webui/open-webui/blob/v0.11.4/backend/open_webui/routers/functions.py). Revalidate this integration when changing the image pin.

Rename provenance uses the extensible `ModelInfo` metadata in the pinned [LiteLLM router types](https://github.com/BerriAI/litellm/blob/v1.96.0/litellm/types/router.py).
