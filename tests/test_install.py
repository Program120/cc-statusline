#!/usr/bin/env python3

from __future__ import annotations

import http.server
import os
from pathlib import Path
import plistlib
import socketserver
import stat
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"
UNINSTALLER = ROOT / "uninstall.sh"
FAKE_CODEX = ROOT / "tests/fixtures/fake-codex.py"
LAUNCHD_LABEL = "com.program120.cc-statusline-codex-quota"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, _format: str, *_args: object) -> None:
        pass


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        handler = lambda *args, **kwargs: QuietHandler(*args, directory=str(ROOT), **kwargs)
        cls.server = socketserver.TCPServer(("127.0.0.1", 0), handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.home = Path(self.tempdir.name) / "home & launch tests"
        self.home.mkdir()
        self.fake_bin = Path(self.tempdir.name) / "bin"
        self.fake_bin.mkdir()
        self.launchctl_log = Path(self.tempdir.name) / "launchctl.log"
        self.plutil_log = Path(self.tempdir.name) / "plutil.log"
        FAKE_CODEX.chmod(0o755)
        self.write_fake(
            "uname",
            '#!/bin/sh\nprintf "%s\\n" "${FAKE_UNAME:-Darwin}"\n',
        )
        self.write_fake(
            "launchctl",
            """#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LAUNCHCTL_LOG"
if [ "$1" = "bootstrap" ] && [ "${FAKE_LAUNCHCTL_BOOTSTRAP_FAIL:-0}" = "1" ]; then
  exit 1
fi
exit 0
""",
        )
        self.write_fake(
            "plutil",
            """#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_PLUTIL_LOG"
[ "${FAKE_PLUTIL_FAIL:-0}" = "1" ] && exit 1
exit 0
""",
        )

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def write_fake(self, name: str, contents: str) -> None:
        path = self.fake_bin / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def environment(self, **overrides: str) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(self.home),
                "XDG_DATA_HOME": str(self.home / ".local/share"),
                "XDG_CONFIG_HOME": str(self.home / ".config"),
                "XDG_CACHE_HOME": str(self.home / ".cache"),
                "CODEX_BIN": str(FAKE_CODEX),
                "CC_STATUSLINE_RAW_BASE": (
                    f"http://127.0.0.1:{self.server.server_address[1]}"
                ),
                "FAKE_LAUNCHCTL_LOG": str(self.launchctl_log),
                "FAKE_PLUTIL_LOG": str(self.plutil_log),
                "PATH": f"{self.fake_bin}{os.pathsep}{env.get('PATH', '')}",
            }
        )
        env.update(overrides)
        return env

    def run_script(
        self,
        script: Path,
        *args: str,
        **environment: str,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(script), *args],
            text=True,
            capture_output=True,
            env=self.environment(**environment),
            timeout=15,
            check=False,
        )

    def run_install(self, *args: str, **environment: str) -> subprocess.CompletedProcess[str]:
        return self.run_script(INSTALLER, *args, **environment)

    @property
    def helper_path(self) -> Path:
        return self.home / ".local/share/cc-statusline/libexec/codex-quota-refresh.py"

    @property
    def cache_path(self) -> Path:
        return self.home / ".cache/cc-statusline/codex-quota.json"

    @property
    def plist_path(self) -> Path:
        return self.home / f"Library/LaunchAgents/{LAUNCHD_LABEL}.plist"

    def read_plist(self) -> dict[str, object]:
        with self.plist_path.open("rb") as input_file:
            return plistlib.load(input_file)

    def test_no_config_installs_files_without_settings(self) -> None:
        result = self.run_install("--no-config", FAKE_UNAME="Linux")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / ".claude/statusline.sh").is_file())
        self.assertTrue(self.helper_path.is_file())
        self.assertFalse((self.home / ".claude/settings.json").exists())

    def test_default_install_creates_settings_and_is_idempotent(self) -> None:
        first = self.run_install(FAKE_UNAME="Linux")
        self.assertEqual(first.returncode, 0, first.stderr)
        settings = self.home / ".claude/settings.json"
        self.assertIn("bash ", settings.read_text(encoding="utf-8"))
        second = self.run_install(FAKE_UNAME="Linux")
        self.assertEqual(second.returncode, 0, second.stderr)

    def test_launchagent_install_is_idempotent(self) -> None:
        first = self.run_install("--no-config")
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.run_install("--no-config")
        self.assertEqual(second.returncode, 0, second.stderr)
        calls = self.launchctl_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            [line.split()[0] for line in calls],
            [
                "bootout",
                "enable",
                "bootstrap",
                "bootout",
                "enable",
                "bootstrap",
            ],
        )

    def test_launchagent_has_safe_typed_configuration(self) -> None:
        result = self.run_install("--no-config")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = self.read_plist()
        self.assertEqual(config["Label"], LAUNCHD_LABEL)
        self.assertEqual(config["StartInterval"], 300)
        self.assertIs(config["RunAtLoad"], True)
        self.assertEqual(config["ProcessType"], "Background")
        self.assertEqual(config["Umask"], 0o77)

        arguments = config["ProgramArguments"]
        self.assertIsInstance(arguments, list)
        self.assertEqual(arguments[2], "--cache-file")
        self.assertTrue(all(Path(value).is_absolute() for value in arguments[:2]))
        self.assertEqual(arguments[1], str(self.helper_path))
        self.assertEqual(arguments[3], str(self.cache_path))
        self.assertNotIn("-c", arguments)
        self.assertNotIn("/bin/sh", arguments)

        environment = config["EnvironmentVariables"]
        self.assertEqual(environment["CODEX_BIN"], str(FAKE_CODEX))
        self.assertEqual(environment["HOME"], str(self.home))
        self.assertIn("PATH", environment)
        self.assertEqual(stat.S_IMODE(self.plist_path.stat().st_mode), 0o644)
        self.assertIn("-lint", self.plutil_log.read_text(encoding="utf-8"))

    def test_codex_home_with_xml_characters_round_trips(self) -> None:
        codex_home = self.home / "Codex <account> & data"
        result = self.run_install("--no-config", CODEX_HOME=str(codex_home))
        self.assertEqual(result.returncode, 0, result.stderr)
        environment = self.read_plist()["EnvironmentVariables"]
        self.assertEqual(environment["CODEX_HOME"], str(codex_home))

    def test_bootstrap_failure_is_nonfatal_and_keeps_manual_fallback(self) -> None:
        result = self.run_install(
            "--no-config", FAKE_LAUNCHCTL_BOOTSTRAP_FAIL="1"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.plist_path.is_file())
        self.assertIn("launchd quota setup failed", result.stderr)
        self.assertIn("Manual quota refresh:", result.stdout)
        self.assertIn("--cache-file", result.stdout)

    def test_invalid_plist_does_not_replace_existing_agent(self) -> None:
        self.plist_path.parent.mkdir(parents=True)
        self.plist_path.write_text("existing\n", encoding="utf-8")
        result = self.run_install("--no-config", FAKE_PLUTIL_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.plist_path.read_text(encoding="utf-8"), "existing\n")
        self.assertFalse(self.launchctl_log.exists())

    def test_linux_does_not_install_launchagent(self) -> None:
        result = self.run_install("--no-config", FAKE_UNAME="Linux")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.plist_path.exists())
        self.assertFalse(self.launchctl_log.exists())

    def test_uninstall_removes_agent_and_helper_but_retains_cache(self) -> None:
        installed = self.run_install("--no-config")
        self.assertEqual(installed.returncode, 0, installed.stderr)
        cache = self.cache_path
        cache.parent.mkdir(parents=True)
        cache.write_text("{}\n", encoding="utf-8")

        removed = self.run_script(UNINSTALLER, "--no-config")
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(self.plist_path.exists())
        self.assertFalse(self.helper_path.exists())
        self.assertTrue(cache.exists())

        repeated = self.run_script(UNINSTALLER, "--no-config")
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        purged = self.run_script(UNINSTALLER, "--no-config", "--purge")
        self.assertEqual(purged.returncode, 0, purged.stderr)
        self.assertFalse(cache.exists())

    def test_third_party_statusline_is_not_overwritten(self) -> None:
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(
            '{"statusLine":{"type":"command","command":"other-statusline"}}\n',
            encoding="utf-8",
        )
        result = self.run_install(FAKE_UNAME="Linux")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("other-statusline", settings.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
