"""Explicit optional configuration; serving startup never reads this file."""
import json
import os
import re
from pathlib import Path
from urllib.parse import urlsplit

from .contracts import GovernanceError, identifier, require
from .http import Api
from .runtime import OllamaRuntime


def load_settings(path):
    try: value = json.loads(Path(path).read_text("utf-8"))
    except FileNotFoundError: raise GovernanceError("config_not_found") from None
    except (ValueError, OSError): raise GovernanceError("invalid_config") from None
    allowed = {"api_base", "admin_token_env", "agent_token_env", "target_id", "state_dir", "test_loopback_http", "runtime"}
    require(isinstance(value, dict) and set(value) <= allowed and "api_base" in value, "invalid_config")
    require(type(value.get("test_loopback_http", False)) is bool, "invalid_config")
    Api(value["api_base"], allow_loopback=value.get("test_loopback_http", False))
    for key in ("admin_token_env", "agent_token_env"):
        if key in value: require(isinstance(value[key], str) and re.fullmatch(r"[A-Z][A-Z0-9_]*", value[key]), "invalid_secret_reference")
    if "target_id" in value: require(identifier(value["target_id"]), "invalid_target")
    if "state_dir" in value: require(isinstance(value["state_dir"], str) and value["state_dir"], "invalid_state_directory")
    return value


def secret(name):
    require(isinstance(name, str) and re.fullmatch(r"[A-Z][A-Z0-9_]*", name), "invalid_secret_reference")
    value = os.environ.get(name, "")
    require(len(value) >= 16 and "\n" not in value and "\r" not in value, "missing_or_weak_secret")
    return value


def api(settings, role):
    token = secret(settings.get(role + "_token_env"))
    return Api(settings["api_base"], token, allow_loopback=settings.get("test_loopback_http", False))


def runtime(settings, group):
    config = settings.get("runtime", {})
    require(isinstance(config, dict) and set(config) == {"ollama_base", "litellm_base", "webui_base", "litellm_token_env", "webui_token_env", "allowed_groups"}, "invalid_runtime_config")
    require(isinstance(config["allowed_groups"], list) and group in config["allowed_groups"] and identifier(group), "group_not_authorized")
    for key in ("ollama_base", "litellm_base", "webui_base"):
        require(urlsplit(config[key]).hostname in {"127.0.0.1", "localhost", "::1"}, "local_runtime_required")
    return OllamaRuntime(Api(config["ollama_base"], allow_loopback=True, timeout=600),
                         Api(config["litellm_base"], secret(config["litellm_token_env"]), allow_loopback=True),
                         Api(config["webui_base"], secret(config["webui_token_env"]), allow_loopback=True))
