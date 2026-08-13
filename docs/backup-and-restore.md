# PocketMind Backup and Restore

## Scope

Back up unique state; re-pull rebuildable artifacts. Test restoration before relying on a backup.

| State | Backup priority | Method |
|---|---|---|
| Private `.env` | Critical | Approved encrypted secret store; never Git |
| PostgreSQL (`postgres_data`) | Critical | Logical `pg_dump`/`pg_restore` |
| Open WebUI (`openwebui_data`) | Critical when users/chats/grants matter | Quiesced archive of `/app/backend/data` |
| Ollama weights (`ollama_data`) | Optional | Usually re-pull exact tags |
| Grafana local state | Optional | Provisioned assets are in Git; back up if local edits exist |
| Prometheus history | Optional | Rebuildable; retain only if history is required |
| Source/config | Critical | Git remote plus verified commit |

Create backups outside the repository so they cannot be committed accidentally.

## PostgreSQL backup

Read database/user names from the private `.env`; do not place the password on the host command line. The container already has its runtime environment:

```powershell
docker exec pocketmind-postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /tmp/pocketmind.dump'
docker cp pocketmind-postgres:/tmp/pocketmind.dump C:\secure-backups\pocketmind-postgres.dump
docker exec pocketmind-postgres rm -f /tmp/pocketmind.dump
```

On macOS/Linux, change the destination path. Verify the host file exists and has non-zero size. Periodically test `pg_restore --list` against the dump using a compatible PostgreSQL client/container.

## PostgreSQL restore

Restore is destructive when replacing current LiteLLM state. Stop request traffic, create a fresh pre-restore backup, and confirm the target database identity.

A safe pattern is to restore into a separate temporary database first, validate its contents, then schedule replacement. Do not blindly restore over an active database. Example inspection in a disposable PostgreSQL 16 environment:

```powershell
pg_restore --list C:\secure-backups\pocketmind-postgres.dump
```

For an actual replacement, stop LiteLLM/Open WebUI traffic, recreate or clean the intended target database under operator control, run `pg_restore`, restart LiteLLM, and verify production aliases, Model Lab records, keys, and smoke tests. Exact database replacement commands are intentionally not automated because they permanently delete current state.

## Open WebUI backup

Open WebUI stores users, chats, workspace model metadata, and grants in `openwebui_data`. Quiesce Open WebUI before copying its data to avoid an inconsistent SQLite snapshot:

```powershell
docker stop pocketmind-open-webui
docker run --rm -v pocketmind_openwebui_data:/source:ro -v C:\secure-backups:/backup alpine sh -c 'cd /source && tar -czf /backup/pocketmind-openwebui.tgz .'
docker start pocketmind-open-webui
```

The Compose-generated volume name is normally `pocketmind_openwebui_data`; confirm it with `docker volume ls` before running. On macOS/Linux, use an absolute host path accepted by Docker Desktop/Engine.

## Open WebUI restore

Restore is destructive because it replaces current users/chats/grants.

1. Stop Open WebUI.
2. Back up the current volume.
3. Confirm the archive source and volume name.
4. Clear the target volume only after explicit approval.
5. Extract the archive into the target volume.
6. Start Open WebUI and verify health, login, model records, and access grants.

Do not restore an unknown/newer database into an incompatible older Open WebUI image without testing on a disposable volume.

## Ollama models

Normally restore Ollama by pulling the exact tags in `.env`/catalog and re-adding desired Model Lab candidates. This is more portable than copying raw model volumes across operating systems. A native profile uses the host Ollama model directory, not the Docker volume.

## Full recovery order

1. Clone and check out the verified Git commit.
2. Restore the private `.env` from secure storage.
3. Start PostgreSQL and restore/validate its dump.
4. Restore Open WebUI data if users/chats/grants are required.
5. Pull configured production Ollama models.
6. Start the resolved profile.
7. Run smoke and full verification.
8. Confirm Open WebUI access and OCR metadata.
9. Recreate only intentional temporary integrations; do not automatically restore Quick Tunnels.

## Validation and retention

- Record backup creation time, source commit, image versions, and profile outside the archive.
- Keep at least one previous known-good backup.
- Encrypt backups containing credentials, chats, users, or keys.
- Perform periodic restore tests on disposable databases/volumes.
- Never copy raw PostgreSQL volume directories across operating systems as a migration method.
