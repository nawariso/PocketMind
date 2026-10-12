# Server Deployment Checklist

Readiness of this repository for a shared pilot on a server that users on the same network reach from their own devices (Open WebUI in a browser, LiteLLM API from applications). It records what was **verified**, how, and what was **not**. Re-run the checks that matter after any change.

The ordered steps are in the [provisioning guide](provisioning-guide.md).

## What was verified

A fresh `git clone` of the pushed repository, with a `.env` generated from `.env.example` using random secrets, on one macOS Apple Silicon host (Docker Desktop, `native` profile, host Ollama):

- All static contract tests pass in the clone, and `check-prerequisites.ps1` passes.
- A separate project (own containers, volumes, ports) started PostgreSQL, LiteLLM, Open WebUI, and nginx from scratch and all became healthy. Prometheus and Grafana were not part of that run.
- On that fresh installation, `install-key-manager.ps1` registered the API Key Manager and made `corp-general` and `corp-ocr` visible; an administrator added a regular user, who asked for a key in the chat backend, called `corp-general` through the proxy API port, was denied other models (403), and got 404 for `/ui`, `/key/generate`, `/model/new`, and `/team/list`.
- `scripts/provision.ps1` ran from nothing on a fresh clone in a separate project (own containers, volumes, ports): host checks, `.env` creation (mode 600, no placeholders, strong administrator password), start, verification (including Prometheus, Grafana, and the proxy), Open WebUI configuration, and the API Key Manager with its `public_base_url`. Afterwards a stranger could not sign up, the administrator signed in with the generated credentials, a regular user saw `corp-general` and `corp-ocr`, created a key, and called the API through the proxy. A second run left `.env`, the user, and the key untouched.
- The pieces that only run in special cases were exercised too: `provision.sh` end to end; changing the role of new accounts both ways; `-EnableSignup` (a visitor then registered with the `user` role, which is the risk that flag documents); `configure-open-webui.ps1` on an existing `corp-ocr` that was shared with one user, had extra capabilities, a custom name, icon, and parameters, and on one with no grants at all (only `builtin_tools` changed and the grants stayed as they were); the API address an administrator set was kept on a re-run and replaced only by an explicit `-PublicHost`; and a `.env` with no administrator, `PROXY_BIND_ADDRESS=0.0.0.0`, and no data volume was refused before anything started (while another project's `openwebui_data` volume existed on the host).
- The proxy checks of `verify-stack.ps1`, rate limits, streaming, websockets, body limits, and a LiteLLM recreate without an nginx reload (see ADR 0005).

## Why the guide's steps matter

The steps themselves (what to prepare, run, check, and do afterwards) are in the [provisioning guide](provisioning-guide.md). The evidence behind the steps that are easiest to skip:

- **The administrator must exist before anyone else can reach Open WebUI.** On a new installation the first visitor becomes administrator: a test visitor took the account within seconds, and the second visitor was refused only because the first registration closed sign-up. With `WEBUI_ADMIN_EMAIL` and `WEBUI_ADMIN_PASSWORD` set before the first start, Open WebUI creates that account and closes sign-up (verified: anonymous sign-up is refused, the configured account signs in as administrator, and `check-prerequisites.ps1` rejects a short or `CHANGE_ME` password). `provision` refuses to start a new Open WebUI that has no administrator while the proxy listens beyond the host.
- **Secrets are only as strong as you make them.** The prerequisite check rejects only `CHANGE_ME` placeholders; a weak master key (a common word) is accepted and also protects key creation. `provision` generates random ones.
- **Open sign-up is a deliberate risk.** With the `user` role, anyone on the network can chat and create API keys; password sign-up cannot restrict email domains or verify mailboxes, so use SSO before opening access broadly (see the README, "Who may register").
- **Open WebUI is pinned to the tested build.** `OPEN_WEBUI_IMAGE` in `.env.example` and the compose defaults is the digest `sha256:8b432fe0…` (Open WebUI 0.11.4, linux/amd64 and linux/arm64), and `tests/config-contract.ps1` rejects a moving tag. At the time of testing the registry's `main` was a different build (`e597ba2c…`) and the release tag `v0.11.4` a third (`9591b13f…`), neither tested here. The API Key Manager depends on Open WebUI internals, so a new server must not pull an untested build. How to change the pin is in the runbook.
- **Downloads can be blocked.** On the test network a pull of the Open WebUI image was answered with a "denied" block page from `pkg-containers.githubusercontent.com` (the blob host behind `ghcr.io`), and Docker Hub pulls failed intermittently with `unexpected EOF`. The hosts the install needs are listed in the guide.

## Know the limits

- **Open WebUI limits sign-ins to 15 per 3 minutes per email.** Normal use and one `provision` run stay far below it; scripts that sign in repeatedly (tests, loops) get `429 API rate limit exceeded` and must wait three minutes without trying again, because each attempt renews the window.

- **Plain HTTP.** Passwords and API keys can be read on the network. Acceptable only on a trusted internal network with test data; add HTTPS before real use.
- **Capacity does not scale with users.** Container Ollama serves one request at a time (`OLLAMA_NUM_PARALLEL=1`, one loaded model), and a request waits in a queue. Measured through LiteLLM on the reference Mac (native Ollama, memory under heavy pressure, swap nearly full), `corp-general`, 80-token answers: 1 request 15 s; 4 simultaneous requests finished between 25 s and 62 s (median 42 s); 8 simultaneous requests between 16 s and 155 s (median 70 s). Overall throughput stayed at about 4 to 5 tokens per second whatever the concurrency. A server with more memory or a GPU will be faster, but the queue behaviour is the same, so size for the number of people who ask at the same moment, and set per-key rate and concurrency limits accordingly.
- **Per-key limits add up.** Each key has its own limits, so many keys add up; a user's session in Open WebUI also reaches the model without those limits.
- **No automatic backups, alerts, or log rotation.** `pg_dump` and volume archives are documented but not scheduled; Docker's default logging has no size limit unless configured on the host; nothing notifies anyone when a service fails (Docker restarts containers with `unless-stopped`).
- **Settings stored in Open WebUI's database are not in Git.** Task Model (`corp-general`), the default user role, access grants for models, `corp-ocr` Built-in Tools off, the API Key Manager function and its Valves, and groups are configured per installation. Repeat them on the new server (see the runbook) and back up `openwebui_data`.
- **LiteLLM teams are created in the LiteLLM UI**, and members are added by email; a new installation has only the `unassigned` team.
- **Host monitoring.** The host dashboard uses `node_exporter` on a macOS host. A Linux server with the `cpu` or `nvidia` profile has no host CPU or memory panels until an exporter is added; the NVIDIA dashboard needs the `nvidia` profile.

## Not verified

- A Linux or Windows server, the `cpu` and `nvidia` profiles at runtime (configuration rendering only), and GPU acceleration on a server.
- A user on another device: all checks were made from the host itself (including through its LAN address), not from a second machine or a phone.
- Linux specifics: Docker publishes ports around host firewalls such as `ufw`, so restrict clients with `nginx/local/*.conf` or by binding `PROXY_BIND_ADDRESS` to one interface, and test from another machine. SELinux hosts may need bind-mount labels.
- Prometheus and Grafana on a fresh installation, restoring a backup, upgrading a running installation, long-running stability, and more than eight simultaneous requests.
- HTTPS, SSO, and an email-domain restriction.
