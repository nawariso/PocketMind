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

The prerequisite check rejects only `CHANGE_ME` placeholders. It accepts a weak value such as a common word, so choose long random secrets yourself, especially `LITELLM_MASTER_KEY` (and Grafana's password) before anyone else can reach the stack. The master key is also read by Open WebUI's API Key Manager, so a weak key exposes key creation too. Rotating it touches several stores; follow the operations runbook.

## Model access

- `corp-general` and `corp-ocr` are stable production aliases.
- Open WebUI user access is controlled by role and workspace model grants.
- `corp-ocr` must keep Built-in Tools off (`builtin_tools=false`) because Typhoon supports completion/vision but not tool calling.
- Model Lab's `lab-*` and deletion rules are client-side safeguards in `model-lab.ps1`. Anyone with the LiteLLM master key can bypass them via management APIs.
- Experimental aliases are admin-visible; ordinary users need an explicit Workspace Model/read grant.

## Public exposure

For a shared pilot on an internal network use the nginx proxy described below. Quick Tunnel is temporary test access, not production ingress:

- expose Open WebUI only by default;
- require authenticated accounts and disable public signup after account provisioning;
- never tunnel Ollama, PostgreSQL, Prometheus, or Grafana;
- do not expose LiteLLM API unless a separate test specifically requires it;
- for API testing, use a short-lived scoped Virtual Key, never the master key;
- use restart policy `no`, record the current temporary URL, then remove the tunnel and revoke test keys.

## Shared pilot proxy

The optional nginx proxy (ADR 0005) is the only component meant to listen beyond `127.0.0.1`:

- it publishes Open WebUI and, on a second port, only the LiteLLM inference endpoints; the administration UI and APIs of LiteLLM, Grafana, Prometheus, PostgreSQL, and Ollama stay on loopback;
- it listens on every interface (`0.0.0.0`) by default; set `PROXY_BIND_ADDRESS` to the LAN IP to use one interface, or `127.0.0.1` to keep it local, and enable it only on a host whose network you trust;
- it speaks plain HTTP, so passwords and API keys are readable by anyone who can observe the network: use it only on a trusted internal network with test data, never on the internet, and add HTTPS before real use;
- limit callers with `allow`/`deny` in `nginx/local/*.conf`, not with the host firewall: on Linux the ports Docker publishes can bypass `ufw`, and on Docker Desktop (observed on macOS) nginx sees every client as the VM gateway, so address rules and per-address rate limits cannot distinguish clients there;
- the API port rate-limits requests per client address (30 per second, burst 60) and Open WebUI's sign-in/session endpoints are limited to 2 per second (burst 10) to slow password guessing and floods; keys themselves are long random values;
- Open WebUI holds the LiteLLM master key and would forward arbitrary paths upstream with it if its OpenAI passthrough were on, so `ENABLE_OPENAI_API_PASSTHROUGH` is pinned to `false` in the compose files and asserted by `tests/proxy-contract.ps1`. Through the Open WebUI port a signed-in user then gets 403 for `/openai/key/generate`, `/openai/key/list`, `/openai/model/new`, `/openai/team/list`, and `/openai/openapi.json` (tested with a throwaway non-admin account). Open WebUI's own OpenAI-compatible chat routes (`/openai/chat/completions`, `/api/chat/completions`) stay available to signed-in users with their session token, within the models they may see; those calls reach LiteLLM with Open WebUI's key, so a personal key's rate and concurrency limits do not apply to them;
- keep sign-up closed and use strong secrets in `.env`, because the master key is the only protection of everything the proxy does not expose.

## Installing prerequisites

`--InstallPrerequisites` adds third-party software to the host and trusts its source: Microsoft's package repository (PowerShell on Linux) or Homebrew (PowerShell and Ollama on macOS). It runs only on request, shows the commands first, never upgrades what is installed, and never installs Docker. On a managed server use your own change process instead if installing from those sources is not allowed.

## Accounts and sign-up

- Open WebUI sign-up is closed; administrators add accounts. Keep it closed unless account creation is otherwise controlled. Check it with `curl -s http://localhost:3000/api/config` (`enable_signup` must be false) before sharing the server; the setting lives in Open WebUI's database and an administrator can turn it back on.
- On a new installation the first visitor becomes administrator. Set `WEBUI_ADMIN_EMAIL` and `WEBUI_ADMIN_PASSWORD` in `.env` before the first start (the prerequisite check refuses short or placeholder passwords), or keep the proxy on `127.0.0.1` until the account exists.
- Password sign-up checks only the email format. It cannot restrict email domains and does not verify that the person owns the address. Team attribution in the API Key Manager trusts the account email, so unverified sign-up would let someone claim another person's team by using their address.
- Domain restriction exists for SSO (`OAUTH_ALLOWED_DOMAINS`) and, with an identity provider, also proves mailbox ownership. Use SSO before opening access to many users.
- The default user role (`pending` unless changed) decides what a newly created or SSO account may do. Changing it to `user` removes the approval step, so combine it only with controlled account creation.
- Open WebUI persists these settings in its database after first start; change them in Admin Panel → Settings, not in `.env`.

## Least privilege

- Give each person a separate Open WebUI account; do not share Admin.
- Keep normal testers at role `user`.
- Grant only the model access required.
- Keep experimental Model Lab aliases private until reviewed.
- Use time-limited/scoped API credentials.

## Self-service API keys

Pilot users create their own LiteLLM key from the Open WebUI model "API Key Manager" (see [ADR 0004](decisions/0004-self-service-virtual-keys.md)):

- keys are scoped to an explicit model list, expire, and have rate and concurrency limits set by the administrator;
- the full key is shown once in the user's chat history, so users should delete that chat after copying it;
- after every Open WebUI upgrade, create a key in a test chat and confirm the key does not appear in the chat title, tags, or follow-ups, because those tasks receive the reply text;
- reach LiteLLM from other machines only through the nginx proxy (ADR 0005), which forwards just the inference paths; never publish `/ui`, `/key`, or `/model`, and add HTTPS before real use;
- never use a weak master key; the Pipe reads it from the Open WebUI container environment;
- publish API keys' endpoint through the nginx proxy (ADR 0005), which forwards only `/v1` inference paths;
- keys are limited to one model each and attributed to the LiteLLM team the user belongs to (matched by email); manage teams only in LiteLLM, they are mirrored to Open WebUI groups by `sync` and never the other way;
- if you set the default user role to `user` so people are not left `pending`, keep sign-up closed or limited to a trusted identity provider, because every approved user can chat and create keys;
- deleting a LiteLLM team also deletes every key attributed to it, so move or recreate keys before removing a team (`unassigned` included);
- revoke a user's access by deleting their key in LiteLLM (Virtual Keys) or with `revoke` by that user.

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
