# API keys and IDE access

## Self-service API keys for Open WebUI users

Pilot users can create their own scoped LiteLLM key without leaving Open WebUI. An administrator installs the "API Key Manager" model once:

```text
pwsh ./scripts/install-key-manager.ps1 -AdminEmail <admin email>
```

The script prompts for the admin password (or reads `OPENWEBUI_ADMIN_PASSWORD`) and registers the model for every signed-in user; add `-GroupId <id>` to limit it to groups. Add `-PublicModels default-general,default-ocr` (comma-separated is fine) to make those models visible to every signed-in user (a model that already has an Open WebUI entry is skipped, so check its access in Admin → Settings → Models). Users select "API Key Manager" and type `models`, `new <model>` (optionally `new <model> as <label>`), `list`, `rotate <alias>`, `revoke <alias>`, or `help`. Each key works for one model, a user may create several keys for the same model (up to 20 in total by default), each key expires, is limited in rate and concurrency by the function's Valves, is shown only once, and is attributed to the LiteLLM team the user belongs to (add members by email in the LiteLLM UI). Teams are managed only in LiteLLM and are mirrored to Open WebUI groups automatically, or immediately when an administrator types `sync`. Users call LiteLLM directly, so a shared pilot should reach it only through the [nginx proxy](network-access.md#shared-pilot-access-with-the-nginx-proxy), which forwards just the inference paths. See [ADR 0004](decisions/0004-self-service-virtual-keys.md) and [security guidance](security.md).

The function discovers the current LiteLLM model aliases automatically, including new custom models: users can type `models`, then `new <alias>` without an administrator editing `allowed_models`. This offers the master-key catalog for self-service API keys, independently of Open WebUI model visibility; LiteLLM team restrictions still apply. To use a restricted manual list instead, set `auto_discover_models=false` in the function's Valves and maintain `allowed_models`. Existing keys remain limited to their original model. To update a server, copy the updated function source and rerun the installer above; existing Valves are preserved and the new discovery setting defaults to true. No container restart is needed.

## Renamed models

With API Key Manager v0.6.1+, `models` offers current names recorded by the [rename script](models/rename-models.md) for new keys. It also shows a separate legacy section only for names used by the caller's own active, unblocked, unexpired keys. Users without such keys see current names only. Expired, blocked, revoked or invalid-expiry keys do not add a legacy name to this section. The legacy route remains live for old clients, but `new <old-alias>` is refused. `list` and `status` retain the actual model scope of existing keys; rotating a legacy key preserves its scope rather than silently switching its model.

The Function reads LiteLLM `/model/info` rename metadata in addition to discovery (also in manual-allowlist mode). If metadata cannot be read/validated, model listing and new-key creation fail closed; existing key listing/rotation/revocation do not depend on that lookup. Only aliases explicitly marked as renamed are hidden; sharing physical model weights does not make an independent alias obsolete.

After pulling this change on a server, rerun `pwsh ./scripts/install-key-manager.ps1 -AdminEmail <admin-email>` to update the installed Function; existing Valves are kept. Updating source files alone does not replace a running Function.

## Test the API key

Postman configuration:

```text
POST http://localhost:4000/v1/chat/completions
Authorization: Bearer <USER_VIRTUAL_KEY>
Content-Type: application/json
```

Body:

```json
{
  "model": "default-general",
  "messages": [
    { "role": "user", "content": "Reply with exactly: API_OK" }
  ],
  "max_tokens": 16,
  "temperature": 0
}
```

Create a restricted 30-day virtual key:

```powershell
pwsh ./scripts/create-virtual-key.ps1
```

## Connect an IDE

Use an OpenAI-compatible provider, base URL `http://<server-ip>:8481/v1` through the proxy (or the approved HTTPS equivalent), a scoped user Virtual Key, and the exact registered model alias. The key's model scope must match that alias. Do not put the LiteLLM master key in an IDE or share it with users. Port `8481` deliberately does not expose model/key/team administration.

The serving model must support the IDE's actual protocol and tools. File reading, Excel parsing, terminal commands and edits are performed by IDE tools or an approved execution service, not by model weights alone. Check tool results and messages sent by the IDE; selecting a larger model does not install an Excel parser. Keep file access, terminal/network permissions and auto-approve restricted in the IDE. Disable unapproved cloud fallback and extensions independently of server privacy settings.

For partial/empty responses, capture the non-secret request metadata, `finish_reason`, tool-call flow and context size; see [troubleshooting](troubleshooting.md). Compare direct local Ollama, LiteLLM API, then IDE to locate the failing layer.

## Rate limits and fair access

API Key Manager Valves control expiry, rate, concurrent requests and key count. LiteLLM teams provide additional scope/budget policy. These limits do not reserve equal GPU shares for users, and per-key limits can be multiplied by issuing multiple keys. WebUI chat may use its shared provider credential, so API-key limits are not automatically per-WebUI-user limits. Capacity-test both access paths and apply organization/team/user policy at the appropriate gateway.
