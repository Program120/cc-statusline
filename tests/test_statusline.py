#!/usr/bin/env python3

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
STATUSLINE = ROOT / "statusline.sh"
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def payload(total_input: int = 12345, session_id: str = "test-session") -> dict:
    return {
        "model": {"id": "gpt-test", "display_name": "Codex Test"},
        "session_id": session_id,
        "workspace": {"current_dir": "/tmp"},
        "context_window": {
            "total_input_tokens": total_input,
            "used_percentage": 12,
            "context_window_size": 100000,
            "current_usage": {
                "input_tokens": 100,
                "output_tokens": 20,
                "cache_creation_input_tokens": 10,
                "cache_read_input_tokens": 890,
            },
        },
    }


class StatuslineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.cache_home = self.root / "cache"
        self.quota_file = self.cache_home / "cc-statusline/codex-quota.json"
        self.marker = self.root / "codex-called"
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        fake_codex = fake_bin / "codex"
        fake_codex.write_text(f"#!/bin/sh\ntouch '{self.marker}'\n", encoding="utf-8")
        fake_codex.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(
            {
                "HOME": str(self.root / "home"),
                "XDG_CACHE_HOME": str(self.cache_home),
                "PATH": f"{fake_bin}:{self.env.get('PATH', '')}",
            }
        )

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def write_quota(
        self,
        *,
        age: int = 0,
        reset_delta: int = 3600,
        remaining: object = 68,
        schema: int = 1,
    ) -> None:
        now = int(time.time())
        self.quota_file.parent.mkdir(parents=True, exist_ok=True)
        self.quota_file.write_text(
            json.dumps(
                {
                    "schema_version": schema,
                    "fetched_at": now - age,
                    "weekly": {
                        "remaining_percent": remaining,
                        "window_duration_mins": 10080,
                        "resets_at": now + reset_delta,
                    },
                }
            ),
            encoding="utf-8",
        )

    def render(self, data: dict) -> str:
        result = subprocess.run(
            ["bash", str(STATUSLINE)],
            input=json.dumps(data),
            text=True,
            capture_output=True,
            env=self.env,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.marker.exists(), "statusline must never launch codex")
        return ANSI.sub("", result.stdout)

    def test_fresh_quota_is_shown_as_remaining(self) -> None:
        self.write_quota(age=30, remaining=68)
        output = self.render(payload())
        self.assertIn("Codex W: 68% left", output)
        self.assertIn("Reset ~", output)

    def test_stale_quota_is_marked(self) -> None:
        self.write_quota(age=901)
        self.assertIn("Codex W*: 68% left", self.render(payload()))

    def test_old_or_expired_quota_is_hidden(self) -> None:
        for age, reset_delta in ((3601, 3600), (0, -1)):
            with self.subTest(age=age, reset_delta=reset_delta):
                self.write_quota(age=age, reset_delta=reset_delta)
                self.assertNotIn("Codex W", self.render(payload()))

    def test_missing_malformed_or_unknown_quota_is_hidden(self) -> None:
        self.assertNotIn("Codex W", self.render(payload()))
        self.quota_file.parent.mkdir(parents=True, exist_ok=True)
        self.quota_file.write_text("not-json\n", encoding="utf-8")
        self.assertNotIn("Codex W", self.render(payload()))
        self.write_quota(schema=2)
        self.assertNotIn("Codex W", self.render(payload()))
        self.write_quota(remaining=101)
        self.assertNotIn("Codex W", self.render(payload()))

    def test_claude_fields_still_render_without_rate_limits(self) -> None:
        output = self.render(payload())
        self.assertIn("Model: Codex Test", output)
        self.assertIn("Ctx: 12.3k", output)
        self.assertIn("Cache  89%", output)
        self.assertIn("Session: test-session", output)
        self.assertNotIn("Weekly:", output)

    def test_transient_zero_reuses_session_snapshot(self) -> None:
        first = self.render(payload(total_input=23456, session_id="stable-session"))
        self.assertIn("Ctx: 23.4k", first)
        zero = payload(total_input=0, session_id="stable-session")
        zero["context_window"]["used_percentage"] = 0
        zero["context_window"]["current_usage"] = {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
        }
        second = self.render(zero)
        self.assertIn("Ctx: 23.4k", second)
        self.assertIn("Session: stable-session", second)

    def test_new_zero_session_hides_synthetic_usage(self) -> None:
        zero = payload(total_input=0, session_id="new-zero")
        zero["context_window"]["used_percentage"] = 0
        zero["context_window"]["current_usage"] = {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
        }
        output = self.render(zero)
        self.assertNotIn("Ctx: 0", output)
        self.assertNotIn("Read 0", output)


if __name__ == "__main__":
    unittest.main()
