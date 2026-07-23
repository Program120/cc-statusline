#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "libexec/codex-quota-refresh.py"
FAKE_CODEX = ROOT / "tests/fixtures/fake-codex.py"

spec = importlib.util.spec_from_file_location("codex_quota_refresh", HELPER)
assert spec and spec.loader
quota = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quota)


class WindowSelectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = 1_800_000_000

    def window(self, used: object = 32, minutes: object = 10080, reset: object = None) -> dict:
        return {
            "usedPercent": used,
            "windowDurationMins": minutes,
            "resetsAt": self.now + 500 if reset is None else reset,
        }

    def result(self, snapshot: dict) -> dict:
        return {"rateLimitsByLimitId": {"codex": snapshot}}

    def test_selects_primary_weekly_window(self) -> None:
        selected = quota.select_codex_weekly_window(
            self.result({"primary": self.window(), "secondary": self.window(minutes=300)}),
            self.now,
        )
        self.assertEqual(selected["remaining_percent"], 68)

    def test_selects_secondary_weekly_window(self) -> None:
        selected = quota.select_codex_weekly_window(
            self.result({"primary": self.window(minutes=300), "secondary": self.window(used=9)}),
            self.now,
        )
        self.assertEqual(selected["remaining_percent"], 91)

    def test_ignores_other_limit_ids(self) -> None:
        result = self.result({"primary": self.window(used=27)})
        result["rateLimitsByLimitId"]["codex-spark"] = {"primary": self.window(used=0)}
        self.assertEqual(
            quota.select_codex_weekly_window(result, self.now)["remaining_percent"], 73
        )

    def test_map_without_codex_is_rejected(self) -> None:
        with self.assertRaises(quota.RefreshError):
            quota.select_codex_weekly_window(
                {"rateLimitsByLimitId": {"codex-spark": {"primary": self.window()}}},
                self.now,
            )

    def test_legacy_snapshot_is_supported_conservatively(self) -> None:
        result = {
            "rateLimitsByLimitId": None,
            "rateLimits": {"limitId": "codex", "primary": self.window(used=40)},
        }
        self.assertEqual(
            quota.select_codex_weekly_window(result, self.now)["remaining_percent"], 60
        )

    def test_other_legacy_limit_is_rejected(self) -> None:
        with self.assertRaises(quota.RefreshError):
            quota.select_codex_weekly_window(
                {
                    "rateLimitsByLimitId": None,
                    "rateLimits": {"limitId": "codex-spark", "primary": self.window()},
                },
                self.now,
            )

    def test_missing_or_ambiguous_week_is_rejected(self) -> None:
        for snapshot in (
            {"primary": self.window(minutes=300)},
            {"primary": self.window(), "secondary": self.window()},
        ):
            with self.subTest(snapshot=snapshot), self.assertRaises(quota.RefreshError):
                quota.select_codex_weekly_window(self.result(snapshot), self.now)

    def test_invalid_used_percent_is_rejected(self) -> None:
        for value in (True, -1, 101, "32"):
            with self.subTest(value=value), self.assertRaises(quota.RefreshError):
                quota.select_codex_weekly_window(
                    self.result({"primary": self.window(used=value)}), self.now
                )

    def test_expired_reset_is_rejected(self) -> None:
        with self.assertRaises(quota.RefreshError):
            quota.select_codex_weekly_window(
                self.result({"primary": self.window(reset=self.now)}), self.now
            )


class RefreshIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.cache = self.root / "cache/cc-statusline/codex-quota.json"
        FAKE_CODEX.chmod(0o755)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_helper(self, mode: str = "success", timeout: float = 3) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "CODEX_BIN": str(FAKE_CODEX),
                "FAKE_CODEX_MODE": mode,
                "CC_STATUSLINE_CACHE_FILE": str(self.cache),
            }
        )
        return subprocess.run(
            [sys.executable, str(HELPER), "--timeout", str(timeout)],
            text=True,
            capture_output=True,
            env=env,
            timeout=8,
            check=False,
        )

    def test_single_sample_end_to_end(self) -> None:
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        data = json.loads(self.cache.read_text(encoding="utf-8"))
        self.assertEqual(set(data), {"schema_version", "fetched_at", "weekly"})
        self.assertEqual(
            set(data["weekly"]),
            {"remaining_percent", "window_duration_mins", "resets_at"},
        )
        self.assertEqual(data["weekly"]["remaining_percent"], 68)
        self.assertEqual(data["weekly"]["window_duration_mins"], 10080)
        self.assertGreater(data["weekly"]["resets_at"], data["fetched_at"])
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.cache.parent.stat().st_mode), 0o700)

    def test_null_error_member_is_success(self) -> None:
        result = self.run_helper(mode="null-error")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.cache.exists())

    def test_failure_preserves_last_good(self) -> None:
        self.cache.parent.mkdir(parents=True)
        self.cache.write_bytes(b'{"last":"good"}\n')
        before = self.cache.read_bytes()
        result = self.run_helper(mode="rpc-error")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.cache.read_bytes(), before)
        self.assertNotIn("secret", result.stderr)

    def test_timeout_preserves_last_good(self) -> None:
        self.cache.parent.mkdir(parents=True)
        self.cache.write_bytes(b'{"last":"good"}\n')
        started = time.monotonic()
        result = self.run_helper(mode="timeout", timeout=0.2)
        elapsed = time.monotonic() - started
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(elapsed, 3)
        self.assertEqual(self.cache.read_bytes(), b'{"last":"good"}\n')

    def test_early_exit_fails_without_cache(self) -> None:
        result = self.run_helper(mode="early-exit")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.cache.exists())


if __name__ == "__main__":
    unittest.main()
