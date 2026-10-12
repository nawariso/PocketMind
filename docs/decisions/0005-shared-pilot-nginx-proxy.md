# ADR 0005: Shared Pilot Access Through an nginx HTTP Proxy

- Status: Accepted

## Context

All published ports bind to `127.0.0.1`, which is correct for one host but means other people cannot use a shared pilot. Users need Open WebUI and, with their personal virtual key, the LiteLLM API. No certificate or DNS name is available yet, and publishing LiteLLM or the other services directly would also expose its administration UI and API, Grafana, and the database port.

## Decision

Add an optional nginx service in `docker-compose.proxy.yml`, enabled by `PROXY_ENABLED=true` in `.env` and added to every compose call by the repository scripts so no later run removes it as an orphan. It works with all three profiles.

- One port serves Open WebUI (including websockets); a second serves only the LiteLLM inference endpoints (`/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/responses`, `/v1/models`). Anything else is a 404, and the path that matched is the path forwarded.
- HTTP only, so no certificate is needed. The bind address defaults to `127.0.0.1`; exposing it to a network is a deliberate setting.
- Upstream names resolve at request time so recreated containers are found without a reload. Streaming is unbuffered, timeouts are 600 s, bodies up to 50 MB are accepted, the API port rate-limits each client address, and Open WebUI's sign-in/session endpoints are rate-limited (everything else it serves is not). Open WebUI's OpenAI passthrough stays off because that route would forward arbitrary paths to LiteLLM with the master key.
- A git-ignored `nginx/local/*.conf` is included in both servers for local rules such as `allow`/`deny` client ranges.
- The container runs with a read-only filesystem, all capabilities dropped except those nginx needs to change user, and `no-new-privileges`.

## Consequences

- Plain HTTP exposes passwords and keys to anyone who can observe the network. It suits a trusted internal pilot with test data; HTTPS is the next step (a certificate on this proxy needs no other change).
- Client-address rules and rate limits see the real address only where Docker preserves it. Docker Desktop showed the VM gateway for every client (observed on macOS), and on Linux the published nginx port can bypass host firewall rules, so restrictions belong in nginx (`nginx/local`) and must be checked on the shared host.
- The allow-list means a new LiteLLM endpoint users need is unreachable until it is added to `nginx/nginx.conf` and the contract test.
- Observed on the reference host (Docker Desktop, macOS): all listed paths, streaming (first chunk 0.39 s, last 17.5 s), websocket chat in the browser, a LiteLLM recreate without an nginx reload, a 413 for a 60 MB body, 429 responses under burst, and `allow`/`deny` rules behaved as designed. Binding to a non-loopback address was verified by rendering the compose configuration only, not by exposing the host. A Linux or Windows shared host was not tested.
