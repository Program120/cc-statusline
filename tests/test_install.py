#!/usr/bin/env python3

from __future__ import annotations

import http.server
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"
FAKE_CODEX = ROOT / "tests/fixtures/fake-codex.py"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, _format: str, *_args: object) -> None:
        pass


class InstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.home = Path(self.tempdir.name) / "home"
        self.home.mkdir()
        FAKE_CODEX.chmod(0o755)
        handler = lambda *args, **kwargs: QuietHandler(*args, directory=str(ROOT), **kwargs)
        self.server = socketserver.TCPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.tempdir.cleanup()

    def run_install(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(self.home),
                "XDG_DATA_HOME": str(self.home / ".local/share"),
                "XDG_CONFIG_HOME": str(self.home / ".config"),
                "XDG_CACHE_HOME": str(self.home / ".cache"),
                "CODEX_BIN": str(FAKE_CODEX),
                "CC_STATUSLINE_RAW_BASE": f"http://127.0.0.1:{self.server.server_address[1]}",
            }
        )
        return subprocess.run(
            ["bash", str(INSTALLER), *args],
            text=True,
            capture_output=True,
            env=env,
            timeout=15,
            check=False,
        )

    def test_no_config_installs_files_without_settings(self) -> None:
        result = self.run_install("--no-config")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / ".claude/statusline.sh").is_file())
        self.assertTrue(
            (self.home / ".local/share/cc-statusline/libexec/codex-quota-refresh.py").is_file()
        )
        self.assertFalse((self.home / ".claude/settings.json").exists())

    def test_default_install_creates_settings_and_is_idempotent(self) -> None:
        first = self.run_install()
        self.assertEqual(first.returncode, 0, first.stderr)
        settings = self.home / ".claude/settings.json"
        self.assertIn("bash ", settings.read_text(encoding="utf-8"))
        second = self.run_install()
        self.assertEqual(second.returncode, 0, second.stderr)

    def test_third_party_statusline_is_not_overwritten(self) -> None:
        settings = self.home / ".claude/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(
            '{"statusLine":{"type":"command","command":"other-statusline"}}\n',
            encoding="utf-8",
        )
        result = self.run_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("other-statusline", settings.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
