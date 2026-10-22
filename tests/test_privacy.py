import copy
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("verify_privacy", ROOT / "scripts/verify-privacy.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RuntimeTopologyTests(unittest.TestCase):
    def setUp(self):
        self.container = {
            "State": {"Running": True},
            "HostConfig": {"NetworkMode": "private", "PortBindings": {
                "4000/tcp": [{"HostIp": "127.0.0.1", "HostPort": "4000"}],
            }},
            "NetworkSettings": {"Networks": {"private": {}}},
        }
        self.networks = {"private": {"Internal": True}, "edge": {"Internal": False}}

    def test_accepts_isolated_backend(self):
        MODULE.validate_backend(self.container, self.networks)

    def test_rejects_extra_external_network(self):
        self.container["NetworkSettings"]["Networks"]["edge"] = {}
        with self.assertRaises(RuntimeError):
            MODULE.validate_backend(self.container, self.networks)

    def test_rejects_host_networking_stopped_containers_and_exposed_ports(self):
        bad = copy.deepcopy(self.container)
        bad["HostConfig"]["NetworkMode"] = "host"
        with self.assertRaises(RuntimeError):
            MODULE.validate_backend(bad, self.networks)
        bad = copy.deepcopy(self.container)
        bad["State"]["Running"] = False
        with self.assertRaises(RuntimeError):
            MODULE.validate_backend(bad, self.networks)
        for address in ("", "0.0.0.0", "::", "172.16.11.159"):
            bad = copy.deepcopy(self.container)
            bad["HostConfig"]["PortBindings"]["4000/tcp"][0]["HostIp"] = address
            with self.subTest(address=address), self.assertRaises(RuntimeError):
                MODULE.validate_backend(bad, self.networks)


class ComposePrivacyTests(unittest.TestCase):
    def render(self, *files, extra_env=None):
        env = dict(os.environ)
        env.update({
            "POSTGRES_DB": "privacy-test", "POSTGRES_USER": "privacy-test",
            "POSTGRES_PASSWORD": "test-only", "LITELLM_MASTER_KEY": "test-only",
            "LITELLM_SALT_KEY": "test-only", "WEBUI_SECRET_KEY": "test-only",
            "GRAFANA_ADMIN_USER": "test-only", "GRAFANA_ADMIN_PASSWORD": "test-only",
            "OLLAMA_MODEL": "test/model:tag", "OLLAMA_OCR_MODEL": "test/ocr:tag",
        })
        env.update(extra_env or {})
        cmd = ["docker", "compose"]
        for file in files:
            cmd.extend(["-f", str(ROOT / file)])
        result = subprocess.run(cmd + ["config", "--format", "json"], env=env,
                                cwd=ROOT, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, "Compose rendering failed (output withheld to avoid exposing secrets)")
        return json.loads(result.stdout)

    def test_both_docker_profiles_isolate_all_backends_and_preserve_proxy_ingress(self):
        for nvidia in (False, True):
            files = ["docker-compose.yml"]
            if nvidia:
                files.append("docker-compose.nvidia.yml")
            files.extend(["docker-compose.proxy.yml", "docker-compose.privacy.yml"])
            with self.subTest(nvidia=nvidia):
                config = self.render(*files)
                self.assertTrue(config["networks"]["ai-net"]["internal"])
                self.assertFalse(config["networks"]["privacy-edge"].get("internal", False))
                for name, service in config["services"].items():
                    if name == "nginx":
                        self.assertEqual(set(service["networks"]), {"ai-net", "privacy-edge"})
                    else:
                        self.assertEqual(set(service["networks"]), {"ai-net"}, name)
                        for port in service.get("ports", []):
                            self.assertEqual(port["host_ip"], "127.0.0.1", name)
                init = config["services"]["model-init"]["command"][0]
                self.assertIn("ollama show", init)
                self.assertNotIn("ollama pull", init)
                web = config["services"]["open-webui"]["environment"]
                self.assertEqual(web["OFFLINE_MODE"], "true")
                self.assertEqual(web["ENABLE_PERSISTENT_CONFIG"], "false")
                self.assertEqual(web["OPENAI_API_BASE_URLS"], "http://litellm:4000/v1")
                self.assertEqual(web["TOOL_SERVER_CONNECTIONS"], "[]")
                self.assertEqual(web["ENABLE_SIGNUP"], "false")

    def test_defaults_preserve_online_bootstrap_and_disable_optional_reporting(self):
        for file in ("docker-compose.yml", "docker-compose.native-ollama.yml"):
            config = self.render(file)
            expected_bind = "0.0.0.0" if file == "docker-compose.yml" else "127.0.0.1"
            for service in config["services"].values():
                for port in service.get("ports", []):
                    self.assertEqual(port["host_ip"], expected_bind)
            self.assertFalse(config["networks"]["ai-net"].get("internal", False))
            web = config["services"]["open-webui"]["environment"]
            self.assertEqual(web["ENABLE_VERSION_UPDATE_CHECK"], "false")
            self.assertEqual(web["HF_HUB_DISABLE_TELEMETRY"], "1")
            self.assertEqual(web["ENABLE_PIP_INSTALL_FRONTMATTER_REQUIREMENTS"], "false")
            grafana = config["services"]["grafana"]["environment"]
            self.assertEqual(grafana["GF_ANALYTICS_REPORTING_ENABLED"], "false")
            if "ollama" in config["services"]:
                self.assertEqual(config["services"]["ollama"]["environment"]["OLLAMA_NO_CLOUD"], "1")

    def test_server_tuning_can_be_preserved_without_editing_compose(self):
        tuning = {
            "OLLAMA_CONTEXT_LENGTH": "16384", "OLLAMA_KEEP_ALIVE": "30m",
            "OLLAMA_MAX_LOADED_MODELS": "4", "OLLAMA_NUM_PARALLEL": "8",
            "OLLAMA_FLASH_ATTENTION": "true", "OLLAMA_KV_CACHE_TYPE": "f16",
            "OLLAMA_SCHED_SPREAD": "false", "NVIDIA_GPU_COUNT": "all",
            "BACKEND_BIND_ADDRESS": "172.16.11.159",
        }
        files = ["docker-compose.yml", "docker-compose.nvidia.yml", "docker-compose.proxy.yml"]
        config = self.render(*files, extra_env=tuning)
        ollama = config["services"]["ollama"]
        for key, value in tuning.items():
            if key.startswith("OLLAMA_"):
                self.assertEqual(ollama["environment"][key], value, key)
        for name in ("ollama", "nvidia-exporter"):
            devices = config["services"][name]["deploy"]["resources"]["reservations"]["devices"]
            self.assertEqual(len(devices), 1)
            self.assertEqual(devices[0]["count"], -1)
        self.assertEqual(ollama["ports"][0]["host_ip"], tuning["BACKEND_BIND_ADDRESS"])
        private = self.render(*files, "docker-compose.privacy.yml", extra_env=tuning)
        for key in tuning:
            if key.startswith("OLLAMA_"):
                self.assertEqual(private["services"]["ollama"]["environment"][key], tuning[key])
        self.assertEqual(private["services"]["ollama"]["ports"][0]["host_ip"], "127.0.0.1")


class RuntimeProbeTests(unittest.TestCase):
    def run_probe(self, models, allow_external=False, allow_internal=True):
        class Opener:
            def open(self, request, timeout):
                return io.StringIO(json.dumps({"data": models}))

        def connect(address, timeout):
            host, _ = address
            internal = host in ("postgres", "ollama")
            if (internal and not allow_internal) or (not internal and not allow_external):
                raise OSError("test-only blocked connection")
            return contextlib.nullcontext()

        output = io.StringIO()
        with patch("socket.create_connection", side_effect=connect), \
             patch("urllib.request.build_opener", return_value=Opener()), \
             patch.dict(os.environ, {"LITELLM_MASTER_KEY": "test-only-secret", "OLLAMA_API_BASE": "http://ollama:11434"}), \
             contextlib.redirect_stdout(output):
            exec(MODULE.PROBE, {})
        return output.getvalue()

    def test_probe_checks_every_model_and_never_prints_key(self):
        model = {"litellm_params": {"model": "ollama_chat/example:tag", "api_base": "os.environ/OLLAMA_API_BASE"}}
        output = self.run_probe([model, model])
        self.assertIn("PASS", output)
        self.assertNotIn("test-only-secret", output)
        external = {"litellm_params": {"model": "openai/example", "api_base": "https://external.example/v1"}}
        with self.assertRaises(RuntimeError):
            self.run_probe([model, external])

    def test_probe_rejects_external_connectivity_and_requires_internal_positive_control(self):
        model = {"litellm_params": {"model": "ollama_chat/example:tag", "api_base": "http://ollama:11434"}}
        with self.assertRaises(RuntimeError):
            self.run_probe([model], allow_external=True)
        with self.assertRaises(OSError):
            self.run_probe([model], allow_internal=False)

    def test_probe_rejects_empty_catalog(self):
        with self.assertRaises(RuntimeError):
            self.run_probe([])


if __name__ == "__main__":
    unittest.main()
