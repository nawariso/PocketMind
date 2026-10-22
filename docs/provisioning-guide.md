# Provisioning Guide

How to bring PocketMind up on a new server for a shared pilot, in the order that avoids mistakes, and what to do afterwards. Follow it top to bottom; the checklist at the end is the short version.

What was verified, and what was not, is recorded in the [server deployment checklist](server-deployment-checklist.md). Read that once before the first real server.

## 1. Decide first

Settle these before you run anything; most are hard to change after users arrive.

| Decision | Recommended | Why it matters |
|---|---|---|
| Who may register | An administrator adds users (default). Open sign-up only on a network you trust, with `-EnableSignup`. | With sign-up open and the `user` role, anyone who can reach Open WebUI can chat and create API keys. No email-domain limit, no email verification. |
| Who can reach the server | One interface or a client range, not the whole network. | The proxy listens on `0.0.0.0` by default. Narrow it with `PROXY_BIND_ADDRESS` and `nginx/local/*.conf`. |
| Address users will type | A reserved IP or a DNS name. | It goes into the API examples users see (`public_base_url`) and into every bookmark. |
| HTTPS | Plan it; the proxy is plain HTTP today. | Passwords and API keys can be read on the network. Acceptable only for a trusted internal pilot with test data. |
| Administrator email | A real mailbox you control. | It becomes the first administrator account. |
| Inference profile | `auto` (see below). | `native` on Apple Silicon, `nvidia` with an NVIDIA GPU, otherwise `cpu`. |
| Backups | Decide who copies `.env` and the data, and how often. | Nothing is scheduled for you. |

## 2. What the server needs

| Need | Detail |
|---|---|
| Operating system | Windows 11 amd64, macOS Apple Silicon, or Linux amd64/arm64. |
| Docker | Docker Desktop (Windows, macOS) or Docker Engine (Linux), with Compose v2 version 2.23.1 or newer. Running, and your user allowed to use it. Linux containers on Windows (WSL2). |
| PowerShell | PowerShell 7 (`pwsh`) on Linux and macOS (the shell wrapper needs it). Windows PowerShell 5.1 or 7 on Windows; 5.1 is covered by CI only, not run locally. |
| Ollama | Only on macOS: install it and run it with `OLLAMA_CONTEXT_LENGTH=8192 OLLAMA_KEEP_ALIVE=10m ollama serve`. Windows and Linux run Ollama in a container. |
| NVIDIA | For the `nvidia` profile: driver plus NVIDIA Container Toolkit, so a container can use the GPU. |
| Memory | At least 8 GiB available to Docker; 16 GiB or more is recommended. |
| Disk | About 15 GiB for images and models; keep 25 GiB free. Models are about 2.5 GB (`default-general`) and 3.2 GB (`default-ocr`). |
| Network (outbound) | `registry-1.docker.io`, `ghcr.io` together with `pkg-containers.githubusercontent.com`, `docker.litellm.ai`, and `registry.ollama.ai`. A gateway that blocks these makes pulls fail (`unexpected EOF`, or a "denied" page). |
| Network (inbound) | Users reach two ports: Open WebUI (default 8480) and the API (default 8481). Nothing else needs to be open. |

By default the scripts install nothing: a failed check names what is missing and how to install it. With `--InstallPrerequisites` (section 3) they can install PowerShell 7 and, on macOS, Ollama. Docker is never installed by them.

## 3. Provision

Clone and run one script. It checks the host first and then runs every step in order.

```text
git clone https://github.com/nawariso/PocketMind.git
cd PocketMind

# Linux or macOS: look first (changes nothing), then install
./scripts/provision.sh --CheckOnly --AdminEmail admin@your-company.example
./scripts/provision.sh --AdminEmail admin@your-company.example

# Windows
powershell -ExecutionPolicy Bypass -File .\scripts\provision.ps1 -CheckOnly -AdminEmail admin@your-company.example
powershell -ExecutionPolicy Bypass -File .\scripts\provision.ps1 -AdminEmail admin@your-company.example
```

Fix every `[FAIL]` it prints and run again. `[WARN]` lines are advice (small memory or disk, firewall notes, a registry that did not answer as expected).

The order, and what each step does:

1. **Host checks** (operating system, Docker and Compose, memory, disk, profile and its runtime, ports, registry reachability, firewall notes, and a refusal to start a new Open WebUI that anyone could claim).
2. **`.env`**: created from `.env.example` with random secrets, the administrator you named, and the proxy switched on. An existing `.env` is never overwritten.
3. **`check-prerequisites.ps1`** for the chosen profile.
4. **`setup.ps1 -Pull`**: downloads images and models, starts the services, waits until they are healthy.
5. **`verify-stack.ps1`**: inference, monitoring, and the proxy.
6. **`configure-open-webui.ps1`**: new accounts get the `user` role and are approved at once, the Task Model is `default-general`, `default-general` and `default-ocr` are visible to signed-in users (`default-ocr` with Built-in Tools off).
7. **`install-key-manager.ps1`**: the "API Key Manager" model, with the API address set for users.

It stops at the first failure and is safe to run again: `.env` and data are kept, and each step changes only what differs.

Options: `-Profile cpu|nvidia|native`, `-PublicHost <ip-or-name>`, `-NoPull`, `-SkipNetworkCheck`, `-EnableSignup`, `-InstallPrerequisites`, `-Yes` (use `--` instead of `-` with the shell wrapper).

### Installing prerequisites (optional)

`--InstallPrerequisites` installs what is missing, after printing the commands and asking (`--Yes` skips the question; with no terminal and no `--Yes` it refuses). With `--CheckOnly` it prints the plan and installs nothing. It never upgrades something already installed, and it never installs Docker, the NVIDIA toolkit, or anything on Windows.

| What | Where | How |
|---|---|---|
| PowerShell 7 | macOS | `brew install powershell` with Homebrew told not to update itself or upgrade anything. |
| PowerShell 7 | Ubuntu, Debian | Microsoft's package repository (`packages-microsoft-prod.deb`), then `apt-get install powershell`; only when Microsoft publishes that repository for your exact distribution and version. |
| PowerShell 7 | RHEL family (Rocky, Alma, RHEL, CentOS) | Microsoft's repository package, then `dnf install powershell`; same condition. |
| PowerShell 7 | any other Linux | Not automatic: the manual link is printed. |
| Ollama | macOS (`native` profile) | `brew install ollama` if missing, then a launchd agent (`com.pocketmind.ollama`) that starts `ollama serve` at login and keeps it running with `OLLAMA_CONTEXT_LENGTH` and `OLLAMA_KEEP_ALIVE` from `.env` (Ollama stays on `127.0.0.1`). An Ollama that already answers on port 11434 is left alone and a warning says to check its context length. |

Root is needed on Linux (the script asks for the `sudo` password first). Installing adds Microsoft's package repository, or Homebrew's formula, to the host: it trusts those sources, so use it only where that is acceptable. What was and was not exercised is in the [checklist](server-deployment-checklist.md).

The generated `.env` is private (mode 600 on Linux and macOS): keep it out of Git and back it up. It holds the administrator password (`WEBUI_ADMIN_PASSWORD`), the LiteLLM master key, and the Grafana password.

### The same steps by hand

Run these yourself instead of `provision` (it does exactly this, in this order, and stops at the first failure):

1. **`.env`**: copy `.env.example` to `.env`, replace every `CHANGE_ME` value with a long random one, set `WEBUI_ADMIN_EMAIL` and `WEBUI_ADMIN_PASSWORD` (at least 12 random characters), and set `PROXY_ENABLED=true`. The administrator and the new-account role (`DEFAULT_USER_ROLE=user`) take effect only on the first start of Open WebUI; without an administrator the first visitor to a new installation becomes one, so do not expose it to a network first.
2. `pwsh ./scripts/check-prerequisites.ps1 -Profile <profile>`, then `pwsh ./scripts/setup.ps1 -Profile <profile> -Pull`, then `pwsh ./scripts/verify-stack.ps1 -Profile <profile>`.
3. `pwsh ./scripts/configure-open-webui.ps1 -AdminEmail <email>`, then `pwsh ./scripts/install-key-manager.ps1 -AdminEmail <email> -PublicBaseUrl http://<host-ip>:8481/v1`.
4. Continue with section 4 below.

## 4. Check the result

Run these on the server. Replace `<ip>` with the address users will use.

| Check | Expected |
|---|---|
| `docker ps --filter name=pocketmind-` | postgres, litellm, open-webui, prometheus, grafana, nginx all `healthy` (plus ollama on container profiles). |
| `curl -s http://localhost:3000/api/config` | `enable_signup` is false (unless you chose `-EnableSignup`) and there is no `onboarding` flag. |
| Open `http://<ip>:8480` from another device | The Open WebUI sign-in page; the administrator signs in with the email and the `WEBUI_ADMIN_PASSWORD` from `.env`. |
| A second visitor tries to register | Refused (when sign-up is closed). |
| `curl -s -o /dev/null -w "%{http_code}" http://<ip>:8481/v1/models` | `401` (no key). |
| `curl -s -o /dev/null -w "%{http_code}" http://<ip>:8481/ui/` | `404` (administration is not exposed). |
| `pwsh ./scripts/verify-stack.ps1 -Profile <profile>` | `Full stack verification passed`. |

Then test as a normal person, not as the administrator (an administrator bypasses access control and proves nothing):

1. As the administrator, add a test user: Admin Panel → Users → +, role `user`.
2. Sign in as that user in a private window. The model list shows `default-general`, `default-ocr`, and "API Key Manager".
3. Chat with `default-general`; send a document image to `default-ocr` with the prompt in [Open WebUI and OCR](open-webui.md#thai-and-english-ocr-with-typhoon).
4. Select "API Key Manager", type `models`, then `new default-general`. Copy the key and call the API from another machine:

   ```text
   curl http://<ip>:8481/v1/chat/completions \
     -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
     -d '{"model":"default-general","messages":[{"role":"user","content":"Reply with exactly: API_OK"}],"max_tokens":16}'
   ```

   The same key on `default-ocr` must give 403 (a key works for one model).
5. Delete the test user, and their chat, afterwards.

Testing from a second device matters: every check made while building this ran on the host itself.

## 5. Do these by hand afterwards

- **Limit who can connect** with `allow <cidr>;` and `deny all;` in `nginx/local/*.conf`. On Linux, Docker publishes ports around host firewalls such as `ufw`, so this (or binding `PROXY_BIND_ADDRESS` to one interface) is the control that works; the steps, and how to see the real client address, are in the [runbook](operations-runbook.md#shared-pilot-proxy-nginx).
- **Open the firewall for the two proxy ports only**, from the user network.
- **Reach the administration pages.** LiteLLM (`http://localhost:4000/ui`, user `admin`, password = `LITELLM_MASTER_KEY` in `.env`) and Grafana (`http://localhost:3001`, user and password from `.env`) listen on the server's loopback only. Open them in a browser on the server, or forward the ports from your PC with SSH (`ssh -L 4000:localhost:4000 -L 3001:localhost:3001 <server>`; standard SSH, not exercised here).
- **Create LiteLLM teams** if usage should be split by team: LiteLLM UI → Teams, add members by email. Each team is mirrored to an Open WebUI group automatically (at most every 10 minutes, when someone uses the API Key Manager) or at once when an administrator types `sync` in it. A user in no team is attributed to `unassigned`.
- **Tune the API Key Manager** in Admin Panel → Functions → API Key Manager → Valves: allowed models, key lifetime (30 days), rate and concurrency limits, number of keys per user (20).
- **macOS only: keep Ollama running** with the environment above. `--InstallPrerequisites` sets this up as a launchd agent; an Ollama you started by hand stops with the session, and then LiteLLM answers 500.
- **Plan backups**: `.env`, PostgreSQL, and the `openwebui_data` volume (see the [backup guide](backup-and-restore.md)); a user's key cannot be recovered from a backup, they ask for a new one.
- **Plan HTTPS** before real use, and SSO if people should register themselves (an email-domain limit exists only for SSO).

## 6. Tell the users

- Chat: `http://<ip>:8480`, sign in with the account the administrator created.
- API: pick "API Key Manager" in the model list and type `models`, then `new <model>` (add `as <name>` to label a key). Each key works for one model, expires, and is shown once: copy it at once and delete that chat. `list` shows their keys, `rotate <alias>` replaces one, `revoke <alias>` removes one.
- API base URL: `http://<ip>:8481/v1` (OpenAI-compatible).
- The default parallel setting is one request per loaded model; server tuning can change it. Capacity-test before increasing concurrency; see [Tuning](tuning.md).

## 7. Change or update later

- **Apply configuration or Git updates**: use [Updating a server](server-update.md). It covers `.env` preservation, one-time migration of local YAML tuning, aliases/keys, Function installation, normal/privacy file sets and verification. Do not copy `.env.example` over a running server's `.env`.
- **Move Open WebUI to another build**: see "Move Open WebUI to another build" in the [runbook](operations-runbook.md#move-open-webui-to-another-build).
- **Rotate the master key or any secret**: follow the runbook; Open WebUI, Prometheus, and Grafana keep their own copies.
- **Stop**: `docker compose <profile files> -f docker-compose.proxy.yml down`. Never add `-v` unless you mean to delete all data.

## 8. When something goes wrong

| Symptom | Where to look |
|---|---|
| A check fails or warns | The line names the fix. See the [troubleshooting guide](troubleshooting.md). |
| `429 API rate limit exceeded` while provisioning | Open WebUI allows 15 sign-ins per 3 minutes per email. Wait three minutes without trying again and re-run. |
| "First administrator" refusal | Set `WEBUI_ADMIN_EMAIL` and `WEBUI_ADMIN_PASSWORD` in `.env`, or `PROXY_BIND_ADDRESS=127.0.0.1` until the account exists. |
| Image or model download fails | The network blocks a registry (section 2). |
| Users see only "API Key Manager" | The models have no access entry: run `configure-open-webui.ps1`. |
| Chat or API is slow | Check actual GPU placement, queueing and [tuning](tuning.md); a UI streaming failure needs [troubleshooting](troubleshooting.md). |

## Checklist

Before:

- [ ] Decided: who registers, who can reach the server, the address, the administrator email, backups, HTTPS plan.
- [ ] Docker with Compose 2.23.1+ running; `pwsh` on Linux and macOS; Ollama running with `OLLAMA_CONTEXT_LENGTH=8192` on macOS.
- [ ] 8 GiB (16 recommended) of memory for Docker; 25 GiB of free disk.
- [ ] Outbound access to the four registries; two inbound ports open to the user network only.

Provision:

- [ ] `git clone`, then `provision.sh --CheckOnly --AdminEmail <email>`; every `[FAIL]` fixed.
- [ ] `provision.sh --AdminEmail <email>` finished with "Ready".
- [ ] `.env` stored safely (administrator password, master key, Grafana password) and kept out of Git.

Check:

- [ ] Sign-up is closed (or opened deliberately); a stranger cannot become administrator.
- [ ] From another device: sign-in page loads; API gives 401 without a key and 404 for `/ui/`.
- [ ] A normal test user sees the models, chats, gets a key, and the key works on its one model only; test user deleted.
- [ ] `verify-stack.ps1` passes.

After:

- [ ] Client range limited in `nginx/local`; firewall allows only the two proxy ports.
- [ ] LiteLLM teams created if needed; Valves reviewed.
- [ ] macOS: Ollama stays running after a reboot.
- [ ] Backups scheduled and one restore tried; HTTPS planned.
- [ ] Users told the address and how to get a key.
