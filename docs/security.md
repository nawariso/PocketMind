# PocketMind Security

## Security posture

PocketMind is a local, single-host stack. Its default network policy is localhost-only: Compose-published ports bind to `127.0.0.1`. Container-to-container traffic uses the private `ai-net` network.

## Credentials

| Credential | Authority | Intended holder/use | Never expose to |
|---|---|---|---|
| `LITELLM_MASTER_KEY` | LiteLLM administrator, model/key management | Local operator and internal service wiring | Testers, public tunnel clients, shared Postman collections, Git, logs |
| LiteLLM Virtual Key | Scoped API access | Temporary API tester/workload | Git or unrelated users |
| `LITELLM_SALT_KEY` | Encrypts database-held credentials | LiteLLM runtime only | Users or public clients |
| `WEBUI_SECRET_KEY` | Open WebUI session security | Open WebUI runtime only | Users, logs, Git |
| PostgreSQL password | Database administration | Runtime/operator | Public clients |
| Grafana admin credentials | Dashboard administration | Operator | Shared/public documentation |

The private `.env` is ignored by Git. `.env.example` contains placeholders only. Back up real values in an approved secret store; do not print them during diagnostics.

## Model access

- `corp-general` and `corp-ocr` are stable production aliases.
- Open WebUI user access is controlled by role and workspace model grants.
- `corp-ocr` must keep Built-in Tools off (`builtin_tools=false`) because Typhoon supports completion/vision but not tool calling.
- Model Lab's `lab-*` and deletion rules are client-side safeguards in `model-lab.ps1`. Anyone with the LiteLLM master key can bypass them via management APIs.
- Experimental aliases are admin-visible; ordinary users need an explicit Workspace Model/read grant.

## Public exposure

Quick Tunnel is temporary test access, not production ingress:

- expose Open WebUI only by default;
- require authenticated accounts and disable public signup after account provisioning;
- never tunnel Ollama, PostgreSQL, Prometheus, or Grafana;
- do not expose LiteLLM API unless a separate test specifically requires it;
- for API testing, use a short-lived scoped Virtual Key, never the master key;
- use restart policy `no`, record the current temporary URL, then remove the tunnel and revoke test keys.

## Least privilege

- Give each person a separate Open WebUI account; do not share Admin.
- Keep normal testers at role `user`.
- Grant only the model access required.
- Keep experimental Model Lab aliases private until reviewed.
- Use time-limited/scoped API credentials.

## Logs and screenshots

Treat environment dumps, container inspection, request payloads, browser screenshots, and Postman exports as potentially secret-bearing. Redact bearer tokens, passwords, cookies, database URLs, and tunnel credentials before sharing.

## Credential incident response

If a credential may have leaked:

1. Stop public tunnels and external clients.
2. Revoke Virtual Keys immediately.
3. Rotate the affected secret. If rotating `LITELLM_SALT_KEY`, first understand that existing encrypted database credentials may become unreadable; preserve a backup and plan migration.
4. Recreate only services that consume the changed value.
5. Review logs and model/key records for unauthorized changes.
6. Run smoke and full verification before reopening access.
7. Remove leaked material from shared artifacts; Git history cleanup requires a dedicated procedure if a secret was committed.

## Security verification checklist

- All published Compose addresses remain `127.0.0.1`.
- Open WebUI direct Ollama and OpenAI passthrough remain disabled as configured.
- Public signup is not left open.
- OCR Built-in Tools remains off.
- No live secrets appear in staged diffs.
- Quick Tunnel is absent when not actively testing.
- Model Lab contains only intended aliases.
- Invalid LiteLLM keys receive HTTP 401.
