"""
title: API Key Manager
author: PocketMind
version: 0.3.0
description: Lets signed-in Open WebUI users create, list, rotate, and revoke their own LiteLLM API keys, one model per key, attributed to the LiteLLM team they belong to. LiteLLM teams are the single source of truth and are mirrored to Open WebUI groups.
"""

import asyncio
import json
import logging
import os
import re
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request

from pydantic import BaseModel, Field

log = logging.getLogger(__name__)

COMMANDS = ("help", "models", "new", "list", "status", "rotate", "revoke", "sync")


class Pipe:
    class Valves(BaseModel):
        enabled: bool = Field(default=True, description="Allow users to create keys.")
        litellm_url: str = Field(default="http://litellm:4000", description="Internal LiteLLM base URL.")
        public_base_url: str = Field(
            default="http://localhost:4000/v1",
            description="Base URL shown to users in the usage example. Set it to the address users can reach.",
        )
        allowed_models: str = Field(
            default="corp-general,corp-ocr",
            description="Comma-separated LiteLLM model aliases users may request a key for. Must not be empty.",
        )
        key_duration: str = Field(default="30d", description="Key lifetime such as 12h, 30d. Always applied.")
        rpm_limit: int = Field(default=20, ge=1, description="Requests per minute per key.")
        tpm_limit: int = Field(default=30000, ge=1, description="Tokens per minute per key.")
        max_parallel_requests: int = Field(default=1, ge=1, description="Concurrent requests per key.")
        max_keys_per_user: int = Field(default=5, ge=1, le=20, description="Active keys one user may hold (one per model).")
        unassigned_team_alias: str = Field(
            default="unassigned",
            description="LiteLLM team for users who belong to no LiteLLM team. Leave empty to issue keys without a team.",
        )
        auto_sync_minutes: int = Field(
            default=10,
            ge=0,
            description="Mirror LiteLLM teams to Open WebUI groups at most this often, when someone uses the key manager. 0 disables.",
        )
        cooldown_seconds: int = Field(default=20, ge=0, description="Minimum seconds between create/rotate/revoke per user.")

    def __init__(self):
        self.valves = self.Valves()
        self._last_action = {}
        self._last_sync = -1e9
        self._tasks = set()

    # ---- LiteLLM access -------------------------------------------------
    def _master_key(self):
        # The Open WebUI container already holds the LiteLLM master key for its own connection.
        return os.environ.get("LITELLM_MASTER_KEY") or os.environ.get("OPENAI_API_KEY") or ""

    def _litellm(self, method, path, body=None, tolerate=()):
        request = urllib.request.Request(
            self.valves.litellm_url.rstrip("/") + path,
            data=json.dumps(body).encode() if body is not None else None,
            method=method,
            headers={"Authorization": f"Bearer {self._master_key()}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            detail = error.read()[:300]
            if error.code in tolerate:
                return {}
            log.error("LiteLLM %s %s failed: %s %s", method, path, error.code, detail)
            raise RuntimeError("LiteLLM rejected the request.") from None
        except Exception as error:
            log.error("LiteLLM %s %s unreachable: %s", method, path, error)
            raise RuntimeError("LiteLLM is unreachable.") from None

    def _own_keys(self, user_id):
        # Always filter by the caller's user_id; ownership is never taken from chat text.
        result = self._litellm("GET", f"/key/list?user_id={urllib.parse.quote(user_id)}&return_full_object=true&size=100")
        return [k for k in result.get("keys", []) if isinstance(k, dict) and k.get("user_id") == user_id]

    # ---- helpers ----------------------------------------------------------
    @staticmethod
    def _last_user_text(body):
        for message in reversed(body.get("messages", [])):
            if message.get("role") != "user":
                continue
            content = message.get("content", "")
            if isinstance(content, list):
                content = " ".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
            return str(content).strip()
        return ""

    def _models(self):
        return [m.strip() for m in self.valves.allowed_models.split(",") if m.strip()]

    def _pick_model(self, text):
        wanted = (text or "").strip().lower()
        for model in self._models():
            if model.lower() == wanted:
                return model
        return None

    def _config_problem(self):
        if not self.valves.enabled:
            return "API key creation is currently disabled by the administrator."
        if not self._master_key():
            return "The key service is not configured. Please contact the administrator."
        if not self._models():
            return "No models are enabled for API keys. Please contact the administrator."
        if not re.fullmatch(r"\d{1,4}[smhd]", self.valves.key_duration):
            return "The key lifetime is misconfigured. Please contact the administrator."
        return None

    def _cooling_down(self, user_id):
        now = time.monotonic()
        if now - self._last_action.get(user_id, -1e9) < self.valves.cooldown_seconds:
            return True
        self._last_action[user_id] = now
        return False

    @staticmethod
    def _key_model(key):
        models = key.get("models") or []
        return models[0] if len(models) == 1 else None

    # ---- LiteLLM teams (source of truth) ------------------------------------
    def _litellm_teams(self):
        teams = self._litellm("GET", "/team/list")
        return [t for t in (teams if isinstance(teams, list) else []) if isinstance(t, dict) and not t.get("blocked")]

    @staticmethod
    def _is_member(team, user):
        # Members added in the LiteLLM UI by email carry a LiteLLM-generated user_id, so match on email too.
        email = (user.get("email") or "").lower()
        for member in team.get("members_with_roles") or []:
            if member.get("user_id") == user.get("id"):
                return True
            if email and (member.get("user_email") or "").lower() == email:
                return True
        return False

    def _resolve_team(self, user, requested, current_team_id=None):
        """Return (team_id, team_alias, problem). A key has exactly one team, so multi-team users must choose."""
        teams = self._litellm_teams()
        mine = {t["team_alias"]: t["team_id"] for t in teams if t.get("team_alias") and self._is_member(t, user)}
        if requested:
            for alias, team_id in mine.items():
                if alias.lower() == requested.lower():
                    return team_id, alias, None
            if not mine:
                return None, None, "You are not a member of any team yet. Ask an administrator to add you to a team in LiteLLM."
            return None, None, "You are not a member of that team.\n\nYour teams: " + ", ".join(f"`{a}`" for a in sorted(mine))
        if len(mine) == 1:
            alias, team_id = next(iter(mine.items()))
            return team_id, alias, None
        if len(mine) > 1:
            for alias, team_id in mine.items():
                if team_id == current_team_id:
                    return team_id, alias, None
            return None, None, (
                "You belong to several teams, and a key is attributed to one team. Add the team name, "
                "for example `new <model> <team>`.\n\nYour teams: " + ", ".join(f"`{a}`" for a in sorted(mine))
            )
        fallback = self.valves.unassigned_team_alias.strip()
        if not fallback:
            return None, None, None
        for team in teams:
            if str(team.get("team_alias") or "").lower() == fallback.lower():
                return team["team_id"], team["team_alias"], None
        created = self._litellm("POST", "/team/new", {"team_alias": fallback, "metadata": {"source": "open-webui"}})
        return created.get("team_id"), fallback, None

    def _stale_keys(self, teams):
        """Keys whose owner is no longer in the key's team, by the owner's email recorded on the key."""
        stale, page = [], 1
        fallback = self.valves.unassigned_team_alias.strip().lower()
        by_id = {t["team_id"]: str(t.get("team_alias") or "").lower() for t in teams}
        while page <= 50:
            result = self._litellm("GET", f"/key/list?return_full_object=true&size=100&page={page}&key_alias=owui-&substring_matching=true")
            for key in result.get("keys", []):
                email = ((key.get("metadata") or {}).get("email") or "").lower()
                if not email or not str(key.get("key_alias") or "").startswith("owui-"):
                    continue
                person = {"id": key.get("user_id"), "email": email}
                owner_teams = {t["team_id"] for t in teams if self._is_member(t, person)}
                current = key.get("team_id")
                if current in owner_teams:
                    continue
                if not owner_teams and (current is None or by_id.get(current) == fallback):
                    continue
                stale.append(key["key_alias"])
            if page >= int(result.get("total_pages") or 1):
                break
            page += 1
        return stale

    async def _mirror_teams_to_groups(self, report=True):
        """Create or update one Open WebUI group per LiteLLM team; membership follows team member emails."""
        from open_webui.models.groups import GroupForm, Groups
        from open_webui.models.users import Users

        teams = await asyncio.to_thread(self._litellm_teams)
        owner = await Users.get_super_admin_user()
        fallback = self.valves.unassigned_team_alias.strip().lower()
        created, updated, unmatched, unmanaged, seen_ids = 0, 0, 0, [], set()
        for team in teams:
            alias, team_id = team.get("team_alias"), team.get("team_id")
            if not alias or not team_id or alias.lower() == fallback:
                continue
            seen_ids.add(team_id)
            emails = sorted({(m.get("user_email") or "").lower() for m in team.get("members_with_roles") or [] if m.get("user_email")})
            ids = []
            for email in emails:
                found = await Users.get_user_by_email(email)
                if found:
                    ids.append(found.id)
                else:
                    unmatched += 1
            group = await Groups.get_group_by_name(alias)
            if group is None:
                group = await Groups.insert_new_group(
                    owner.id if owner else "",
                    GroupForm(name=alias, description="Synced from the LiteLLM team of the same name.", data={"litellm_team_id": team_id}),
                )
                created += 1
            elif (group.data or {}).get("litellm_team_id") == team_id:
                updated += 1
            else:
                unmanaged.append(alias)  # a group someone made by hand: never overwritten
                continue
            await Groups.set_group_user_ids_by_id(group.id, ids)
        orphans = [
            g.name for g in await Groups.get_all_groups()
            if (g.data or {}).get("litellm_team_id") and g.data["litellm_team_id"] not in seen_ids
        ]
        if not report:
            return ""
        stale = await asyncio.to_thread(self._stale_keys, teams)
        lines = [
            "### Team sync finished", "",
            f"- LiteLLM teams read: {len(teams)}",
            f"- Open WebUI groups created: {created}, updated: {updated}",
            f"- Team members without an Open WebUI account yet: {unmatched}",
        ]
        if unmanaged:
            lines.append("- Skipped, a group with that name already exists and was not created by sync: " + ", ".join(f"`{n}`" for n in unmanaged))
        if orphans:
            lines.append("- Groups whose LiteLLM team no longer exists (kept, remove by hand if unneeded): " + ", ".join(f"`{n}`" for n in orphans))
        if stale:
            lines.append(f"- Keys whose owner left the key's team ({len(stale)}); ask these users to `rotate <model>`: " + ", ".join(f"`{a}`" for a in stale[:20]))
        return "\n".join(lines)

    async def _auto_sync(self):
        try:
            await self._mirror_teams_to_groups(report=False)
        except Exception as error:
            log.error("Automatic team sync failed: %s", error)

    def _schedule_auto_sync(self):
        minutes = self.valves.auto_sync_minutes
        if minutes and time.monotonic() - self._last_sync > minutes * 60:
            self._last_sync = time.monotonic()
            task = asyncio.ensure_future(self._auto_sync())
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)

    # ---- commands ---------------------------------------------------------
    def _create(self, user, model, team_id, team_alias):
        alias_name = re.sub(r"[^a-z0-9]+", "-", (user.get("email") or user["id"]).split("@")[0].lower()).strip("-")[:20] or "user"
        model_slug = re.sub(r"[^a-z0-9]+", "-", model.lower()).strip("-")[:24]
        alias = f"owui-{alias_name}-{model_slug}-{secrets.token_hex(2)}"
        payload = {
            "key_alias": alias,
            "user_id": user["id"],
            "duration": self.valves.key_duration,
            "models": [model],
            "rpm_limit": self.valves.rpm_limit,
            "tpm_limit": self.valves.tpm_limit,
            "max_parallel_requests": self.valves.max_parallel_requests,
            "metadata": {"source": "open-webui", "email": user.get("email"), "name": user.get("name"), "model": model},
        }
        if team_id:
            payload["team_id"] = team_id
        result = self._litellm("POST", "/key/generate", payload)
        key = result.get("key")
        if not key:
            raise RuntimeError("LiteLLM did not return a key.")
        base = self.valves.public_base_url.rstrip("/")
        return (
            f"### Your API key for `{model}`\n\n"
            f"```\n{key}\n```\n\n"
            "**Copy it now.** It is shown only once and cannot be retrieved later. "
            "This message is saved in this chat, so delete the chat after copying the key.\n\n"
            f"- Alias: `{alias}`\n- Model: `{model}` (this key cannot call other models)\n"
            f"- Team: {f'`{team_alias}`' if team_id else 'none'}\n"
            f"- Expires: {result.get('expires') or 'n/a'}\n"
            f"- Limits: {self.valves.rpm_limit} requests/min, {self.valves.tpm_limit} tokens/min, "
            f"{self.valves.max_parallel_requests} concurrent request(s)\n\n"
            "Example:\n\n"
            f"```bash\ncurl {base}/chat/completions \\\n  -H \"Authorization: Bearer <your-key>\" \\\n"
            "  -H \"Content-Type: application/json\" \\\n"
            f"  -d '{{\"model\":\"{model}\",\"messages\":[{{\"role\":\"user\",\"content\":\"Hello\"}}]}}'\n```\n"
        )

    def _describe(self, keys):
        if not keys:
            return "You have no active API keys. Type `models` to see what you can request, then `new <model>`."
        lines = ["### Your API keys", "", "| Model | Alias | Key | Expires |", "|---|---|---|---|"]
        for k in keys:
            lines.append(
                f"| `{self._key_model(k) or ', '.join(k.get('models') or []) or 'n/a'}` | `{k.get('key_alias')}` | "
                f"`{k.get('key_name') or 'hidden'}` | {k.get('expires') or 'never'} |"
            )
        return "\n".join(lines)

    def _models_text(self, keys):
        have = {self._key_model(k) for k in keys}
        lines = ["### Models you can request a key for", "", "| Model | Your key |", "|---|---|"]
        for model in self._models():
            lines.append(f"| `{model}` | {'yes' if model in have else 'no'} |")
        lines.append("\nType `new <model>` to create a key for one model, for example `new " + self._models()[0] + "`.")
        return "\n".join(lines)

    def _help(self):
        return (
            "### API Key Manager\n\nEach key works for **one model**. Type one of these commands:\n\n"
            "| Command | What it does |\n|---|---|\n"
            "| `models` | Show the models you can request a key for |\n"
            "| `new <model>` | Create your key for that model (shown **once**) |\n"
            "| `list` | Show your keys without revealing them |\n"
            "| `rotate <model>` | Replace your key for that model |\n"
            "| `revoke <model or alias>` | Revoke a key |\n"
            "| `help` | Show this message |\n"
        )

    async def pipe(self, body: dict, __user__: dict = None, __task__=None) -> str:
        # Open WebUI may call the selected model for titles, tags, and follow-ups; never act on those.
        if __task__:
            return "API Key Manager"

        user = __user__ or {}
        if not user.get("id") or user.get("role") not in ("user", "admin"):
            return "You must be an approved Open WebUI user to manage API keys."

        problem = self._config_problem()
        words = self._last_user_text(body).split()
        action = words[0].lower() if words else "help"
        args = words[1:]
        if action not in COMMANDS or action in ("help",):
            return self._help() if not problem else problem + "\n\n" + self._help()
        if problem and action not in ("list", "status"):
            return problem

        try:
            self._schedule_auto_sync()
            if action == "sync":
                if user.get("role") != "admin":
                    return "Only administrators can run `sync`."
                return await self._mirror_teams_to_groups()

            keys = await asyncio.to_thread(self._own_keys, user["id"])
            if action in ("list", "status"):
                return self._describe(keys)
            if action == "models":
                return self._models_text(keys)

            if action in ("new", "rotate", "revoke"):
                if not args:
                    return f"Tell me which model, for example `{action} {self._models()[0]}`.\n\n" + self._models_text(keys)

            if action == "revoke":
                target = args[0]
                targets = [k for k in keys if k.get("key_alias") == target or (self._key_model(k) or "").lower() == target.lower()]
                if not targets:
                    return "No matching key of yours was found.\n\n" + self._describe(keys)
                if await asyncio.to_thread(self._cooling_down, user["id"]):
                    return f"Please wait {self.valves.cooldown_seconds} seconds before trying again."
                for key in targets:
                    await asyncio.to_thread(self._litellm, "POST", "/key/delete", {"key_aliases": [key["key_alias"]]})
                return f"Revoked {len(targets)} key(s). Anything using it will now receive 401."

            # new / rotate
            model = self._pick_model(args[0])
            if not model:
                return f"`{args[0]}` is not available for API keys.\n\n" + self._models_text(keys)
            existing = [k for k in keys if self._key_model(k) == model]
            if action == "new":
                if existing:
                    return f"You already have a key for `{model}`. Type `rotate {model}` to replace it or `revoke {model}` to remove it."
                if len(keys) >= self.valves.max_keys_per_user:
                    return f"You already have {len(keys)} keys, the maximum is {self.valves.max_keys_per_user}.\n\n" + self._describe(keys)
            elif not existing:
                return f"You have no key for `{model}` to rotate. Type `new {model}` instead."

            current_team = existing[0].get("team_id") if existing else None
            team_id, team_alias, team_problem = await asyncio.to_thread(
                self._resolve_team, user, " ".join(args[1:]) or None, current_team
            )
            if team_problem:
                return team_problem
            if await asyncio.to_thread(self._cooling_down, user["id"]):
                return f"Please wait {self.valves.cooldown_seconds} seconds before trying again."
            for key in existing:
                await asyncio.to_thread(self._litellm, "POST", "/key/delete", {"key_aliases": [key["key_alias"]]})
            return await asyncio.to_thread(self._create, user, model, team_id, team_alias)
        except RuntimeError as error:
            return f"Sorry, the request could not be completed: {error}"
        return self._help()
