# Local data and privacy controls

These controls reduce unintended external connections. They do **not** certify models, the host, browsers, IDEs, plugins or users as incapable of leaking data. Infrastructure egress policy and workload testing are required before handling sensitive organizational data. No model-weight scan or production-server privacy test is performed by editing this repo.

## Base controls

- Container Ollama has `OLLAMA_NO_CLOUD=1` and request-body debug logging disabled. This disables cloud features, not model downloads. Native host Ollama needs its own configuration.
- LiteLLM disables telemetry and message logging, redacts messages in exceptions and reduces log verbosity. The configured success callback remains local Prometheus; token/cost accounting is retained. This does not erase chat history or guarantee every log is free of sensitive data.
- Open WebUI defaults disable update checks, Hugging Face/Chroma telemetry, direct connections/integrations, web search, OpenTelemetry, automatic pip installation from Function/Tool frontmatter and remote code for embedding/reranking models. Saved Admin settings may override environment defaults. Installed Functions, including API Key Manager, remain trusted executable code.
- Grafana analytics reporting and update checks are disabled. Backend exposure is controlled separately by the selected Compose files.

The ordinary bridge network still allows bootstrap downloads. **With `PRIVACY_MODE=false`, base settings are not network isolation.** The Docker CPU/NVIDIA base file publishes backend ports on `0.0.0.0` for direct server access; restrict allowed clients at the network boundary. The privacy overlay replaces these bindings with loopback-only bindings. `.env` values only affect containers when explicitly wired through Compose.

## Isolated serving mode

The optional [governed delivery POC](governance.md) runs separately. Synthetic mode never changes serving containers. Real integration uses a management host agent with approved internal connectivity; it must not add external networks to backends or require disabling Privacy mode. Actual scanner/acquisition and firewall qualification remain deployment work.

`PRIVACY_MODE=true` adds `docker-compose.privacy.yml` last in repository-script Compose calls. It requires Docker Compose 2.24.4 or newer (`!override`), `PROXY_ENABLED=true` and Docker CPU/NVIDIA; native host Ollama is explicitly rejected because it is outside this boundary.

The overlay makes `ai-net` internal. All inference, UI, database and monitoring backends attach only to it. nginx also gets a separate `privacy-edge` network for user ingress. Model-init inspects local weights instead of pulling them. Open WebUI enables offline mode, disables model auto-updates and ignores persisted application configuration in favor of environment defaults. Its provider is local LiteLLM; sign-up, code execution/interpreter, community sharing and user webhooks are disabled, and remote tool/terminal server lists start empty.

**Application impact:** saved Admin settings for RAG, task models, SSO, providers, etc. are not loaded. Accounts, Workspace Model grants, chats and Function Valves are separate records and are not deleted. Existing Admin APIs and custom code are not made immutable. Approved local dependencies must be configured through reviewed environment settings. Missing embedding/tokenizer/Whisper caches can prevent offline RAG/audio or startup. Browser code interpretation is disabled; IDE tools need independent sandbox/egress controls.

**Boundary limits:** internal Docker networks do not isolate the host, every host-provided service, DNS forwarding, user browsers or IDEs. nginx retains an edge network. Host proxies, container-to-host routes, callbacks, custom Functions, rendered external images/links and IDE cloud fallback need separate controls. This is not an air gap or a sandbox for malicious code.

## Prepare and enable on a server

These are future deployment steps, not actions performed automatically in this repository. Schedule downtime for network recreation. Coordinate any existing `corp-*` to `default-*` alias/key migration from the [server update guide](server-update.md) first.

1. Back up PostgreSQL, Open WebUI data and secrets. Review installed Functions/Tools, DB-backed models and logging callbacks for external services. Approve model sources/licenses, record revision/digests and scan supported artifact formats and container images. Do not put real data or production credentials in the online preparation environment.
2. With `PRIVACY_MODE=false`, prepare approved images, models and the exact local embedding/tokenizer/reranker/Whisper caches serving will use. Exercise document/RAG/audio workflows with synthetic data before disconnecting. An offline cache failure must not be bypassed by giving a server holding real data unrestricted Internet access.
3. Stop without removing volumes. For NVIDIA, from the repo root:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml down
   ```

   **Never add `-v`.** CPU omits `docker-compose.nvidia.yml`.
4. Set `.env`:

   ```dotenv
   PROXY_ENABLED=true
   PRIVACY_MODE=true
   ```

5. Have Infra apply the policies below, then start and verify:

   ```bash
   pwsh ./scripts/setup.ps1 -Profile nvidia
   python3 ./scripts/verify-privacy.py
   pwsh ./scripts/verify-stack.ps1 -Profile nvidia
   ```

   CPU uses `-Profile cpu`. `verify-stack` performs inference and briefly creates a scoped test key.
6. Test chat, streaming/WebSocket, API, uploads/RAG, model switching and restart with synthetic data. Review firewall/DNS/proxy flow logs; test cross-user file/chat isolation. Repeat after model, Function, Tool or IDE-extension changes.

Manual Compose commands must include privacy **last**:

```bash
docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml -f docker-compose.privacy.yml up -d
```

Omitting the overlay can undo these controls. Never attach a backend to an external network to fix downloads. Model Lab pulls and missing dependencies are intentionally unavailable during isolated serving; use a controlled preparation/import process. Docker image pulling occurs in the **host daemon**, outside the backend network.

## Prepare caches for offline workloads

Preparing Ollama weights alone is insufficient for RAG/audio. While approved outbound access is available, run the exact embedding/reranking/audio configuration you intend to serve with synthetic fixtures. The pinned Open WebUI image uses caches under its persistent `/app/backend/data` volume; preserve that volume when recreating containers.

For the default local embedding and tokenizer, this preparation command runs inside the existing Open WebUI container. Run it only in the approved online preparation window, before sensitive serving:

```bash
docker exec -i pocketmind-open-webui python - <<'PYTHON'
import os
from sentence_transformers import SentenceTransformer
import tiktoken
SentenceTransformer(
    os.environ.get("RAG_EMBEDDING_MODEL", "sentence-transformers/all-MiniLM-L6-v2"),
    device="cpu",
    cache_folder=os.environ.get("SENTENCE_TRANSFORMERS_HOME", "/app/backend/data/cache/embedding/models"),
    trust_remote_code=False,
)
tiktoken.get_encoding(os.environ.get("TIKTOKEN_ENCODING_NAME", "cl100k_base"))
print("Default embedding/tokenizer preparation completed; verify the actual offline workflow next.")
PYTHON
```

This does not prepare an arbitrary saved Admin model, reranker or Whisper model. Configure approved non-default dependencies explicitly through reviewed Compose environment settings, prepare their caches in the same persistent volume, then test offline. Privacy ignores saved Admin configuration, so exercise the environment-selected configuration rather than assuming a previous online test covers it.

## Temporarily disable privacy to download and register a model

Yes, privacy can be disabled and restored. Use a maintenance window with no real-data requests. Changing `PRIVACY_MODE` alone does not change existing networks or manual Compose file selection. Infra outbound rules are independent and must be temporarily adjusted through the approved download path.

The following NVIDIA procedure keeps WebUI/nginx stopped during model download/registration. CPU omits the NVIDIA file. Keep backups, volumes and the original image pins; do not add `-v`.

1. Pause clients and have Infra block user access to both proxy and directly published backend ports for the maintenance window. Stop the active private stack using its full file set:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml -f docker-compose.privacy.yml down
   ```

2. Set `PRIVACY_MODE=false` in `.env`. Leave `PROXY_ENABLED=true` for eventual restoration, but start only the model-management dependencies below. Have Infra permit the approved registries/download destinations temporarily. Normal YAML may publish their ports on all interfaces; maintain the client block.

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml up -d postgres ollama litellm
   ```

   Dependencies may run model-init, which pulls the initial models. WebUI and nginx are not requested. Wait for `pocketmind-litellm` to report healthy.

3. Download and register the approved model, using a verified exact tag and your chosen alias:

   ```powershell
   pwsh ./scripts/model-lab.ps1 add -Model <approved-exact-tag> -Alias <chosen-alias> -Profile nvidia
   pwsh ./scripts/model-lab.ps1 list -Profile nvidia
   pwsh ./scripts/model-lab.ps1 test -Alias <chosen-alias> -Profile nvidia
   ```

   `add` both pulls weights and registers the alias in PostgreSQL. For weights only, use `docker exec pocketmind-ollama ollama pull <approved-exact-tag>`; this does not register an API alias. Record provenance, hash/revision and test results. If new WebUI caches/images are needed, use a separate controlled preparation environment or the cache procedure above with synthetic data; do not silently reopen user serving.

4. Stop the temporary ordinary stack, restore `PRIVACY_MODE=true`, and have Infra restore default-deny outbound before serving:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml down
   ```

5. Recreate the private network and verify:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.nvidia.yml -f docker-compose.proxy.yml -f docker-compose.privacy.yml up -d
   python3 ./scripts/verify-privacy.py
   pwsh ./scripts/verify-stack.ps1 -Profile nvidia
   ```

6. Test the new alias with a scoped API key and synthetic input, grant regular-user WebUI access if needed, and only then reopen approved ingress. API Key Manager automatic discovery offers registered aliases for new keys; existing keys do not gain model scopes.

If switching networks reports active endpoints, inspect remaining containers attached to `pocketmind_ai-net` and stop the intended stack members deliberately. Do not attach private backends to an online network as a workaround. A failed privacy verifier is a reason to keep sensitive serving paused and inspect the boundary.

## Infra and endpoint policies still required

- Default-deny outbound Internet for the host, Docker forwarding paths and nginx edge network, covering IPv4 and IPv6. Keep an approved management/download path separate. Account for Docker rules, not only `ufw`.
- Allow only approved internal dependencies. Audit their downstream flows, including SSO, OCR, embeddings and monitoring.
- Restrict DNS to an approved resolver with external-query policy and monitoring, including host/Docker DNS forwarding. No host HTTP/SOCKS proxy or gateway service should bypass inference-container restrictions.
- Keep backend ports loopback-only. Use HTTPS with an approved certificate/reverse proxy and permit same-origin WebSockets. The repository pilot nginx still serves HTTP. Restrict administration through the management network/PAM.
- Apply policy on browsers/IDEs too: approved API base, no cloud fallback, approved extensions/MCP/Tools, least-privilege file access and restricted network/terminal execution. Server settings do not control these endpoints.
- Rotate weak/previously shared secrets. Use SSO/RBAC, scoped keys, log minimization, retention and encryption/access controls for chat history, uploads, databases and backups.

## Verification scope

`verify-privacy.py` checks running backend network attachments, loopback port bindings, cloud/offline flags, internal PostgreSQL/Ollama connectivity, failed TCP probes to fixed external IPv4/IPv6 addresses, and all current LiteLLM `/model/info` routes including DB-backed aliases. It refuses routes outside local Ollama and does not print credentials, prompts or container environments.

It does not prove every external address, DNS channel, callback or client integration is blocked. Static Compose tests check intended topology, not a deployed firewall. Keep verifier output, approved model/image digests, configuration and network flow logs as evidence. Production runtime verification remains necessary.

## Rollback

Stop using the full privacy Compose file set (no `-v`), set `PRIVACY_MODE=false`, and recreate using the ordinary files. This restores online-capable networking and saved Admin settings, potentially including external endpoints. Do not reopen Internet access while sensitive workloads run. Volumes and secrets are preserved.

## References

- [Ollama local-only configuration](https://docs.ollama.com/faq#how-do-i-disable-ollamas-cloud-features)
- [Open WebUI offline setup](https://docs.openwebui.com/tutorials/maintenance/offline-mode/), [v0.11.4 environment options](https://github.com/open-webui/open-webui/blob/v0.11.4/backend/open_webui/env.py), [v0.11.4 application configuration](https://github.com/open-webui/open-webui/blob/v0.11.4/backend/open_webui/config.py)
- [LiteLLM v1.96.0 telemetry and logging options](https://github.com/BerriAI/litellm/blob/v1.96.0/litellm/__init__.py)
- [Docker internal networks](https://docs.docker.com/reference/compose-file/networks/#internal)
- [Grafana analytics configuration](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/#analytics)
