#!/usr/bin/env python3
"""Refresh the Codex weekly quota cache used by cc-statusline."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

SCHEMA_VERSION = 1
WEEKLY_WINDOW_MINS = 7 * 24 * 60


class RefreshError(RuntimeError):
    """A safe-to-report refresh failure."""


def resolve_codex_binary() -> str:
    candidates: list[str] = []
    configured = os.environ.get("CODEX_BIN")
    if configured:
        candidates.append(configured)

    on_path = shutil.which("codex")
    if on_path:
        candidates.append(on_path)

    home = Path.home()
    candidates.extend(
        [
            str(home / ".npm-global/bin/codex"),
            str(home / ".local/bin/codex"),
        ]
    )

    for candidate in candidates:
        resolved = Path(candidate).expanduser()
        if not resolved.is_absolute():
            found = shutil.which(str(resolved))
            if not found:
                continue
            resolved = Path(found)
        try:
            mode = resolved.stat().st_mode
        except OSError:
            continue
        if stat.S_ISREG(mode) and os.access(resolved, os.X_OK):
            return str(resolved.resolve())

    raise RefreshError("codex executable not found")


def _send(process: subprocess.Popen[str], message: dict[str, Any]) -> None:
    if process.stdin is None:
        raise RefreshError("app-server stdin unavailable")
    try:
        process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        process.stdin.flush()
    except (BrokenPipeError, OSError) as exc:
        raise RefreshError("app-server closed its input") from exc


def _reader(stream: Any, events: queue.Queue[tuple[str, str | None]]) -> None:
    try:
        for line in stream:
            events.put(("stdout", line))
    finally:
        events.put(("stdout", None))


def _drain(stream: Any) -> None:
    for _line in stream:
        pass


def _wait_for_response(
    process: subprocess.Popen[str],
    events: queue.Queue[tuple[str, str | None]],
    expected_id: int,
    deadline: float,
) -> dict[str, Any]:
    stdout_closed = False
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RefreshError("app-server timed out")
        try:
            kind, line = events.get(timeout=remaining)
        except queue.Empty as exc:
            raise RefreshError("app-server timed out") from exc

        if line is None:
            if kind == "stdout":
                stdout_closed = True
            if stdout_closed and process.poll() is not None:
                raise RefreshError("app-server exited before replying")
            continue
        if kind != "stdout":
            continue

        try:
            message = json.loads(line)
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(message, dict) or message.get("id") != expected_id:
            continue
        if message.get("error") is not None:
            raise RefreshError(f"RPC id {expected_id} returned an error")
        result = message.get("result")
        if not isinstance(result, dict):
            raise RefreshError(f"RPC id {expected_id} returned an invalid result")
        return result


def _stop_process(process: subprocess.Popen[str]) -> None:
    if process.stdin is not None:
        try:
            process.stdin.close()
        except OSError:
            pass
    if process.poll() is not None:
        process.wait()
        return
    process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def fetch_rate_limits(codex_binary: str, timeout_seconds: float) -> dict[str, Any]:
    try:
        process = subprocess.Popen(
            [codex_binary, "app-server", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            shell=False,
        )
    except OSError as exc:
        raise RefreshError("unable to start codex app-server") from exc

    assert process.stdout is not None
    assert process.stderr is not None
    events: queue.Queue[tuple[str, str | None]] = queue.Queue()
    stdout_reader = threading.Thread(target=_reader, args=(process.stdout, events), daemon=True)
    stderr_reader = threading.Thread(target=_drain, args=(process.stderr,), daemon=True)
    stdout_reader.start()
    stderr_reader.start()
    deadline = time.monotonic() + timeout_seconds

    try:
        _send(
            process,
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "cc_statusline",
                        "title": "cc-statusline",
                        "version": "1.2.0",
                    },
                    "capabilities": {"experimentalApi": True},
                },
            },
        )
        _wait_for_response(process, events, 1, deadline)
        _send(process, {"method": "initialized"})
        _send(process, {"id": 2, "method": "account/rateLimits/read"})
        return _wait_for_response(process, events, 2, deadline)
    finally:
        _stop_process(process)


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _redacted_window(window: dict[str, Any], duration_mins: int, resets_at: int) -> dict[str, int]:
    return {
        "remaining_percent": 100 - window["usedPercent"],
        "window_duration_mins": duration_mins,
        "resets_at": resets_at,
    }


def select_codex_windows(result: dict[str, Any], now: int) -> dict[str, dict[str, int]]:
    by_limit_id = result.get("rateLimitsByLimitId")
    if isinstance(by_limit_id, dict):
        snapshot = by_limit_id.get("codex")
        if not isinstance(snapshot, dict):
            raise RefreshError("Codex rate-limit bucket not found")
    elif by_limit_id is None:
        snapshot = result.get("rateLimits")
        if not isinstance(snapshot, dict):
            raise RefreshError("rate-limit snapshot not found")
        limit_id = snapshot.get("limitId")
        if limit_id not in (None, "codex"):
            raise RefreshError("legacy snapshot belongs to another limit")
        limit_name = snapshot.get("limitName")
        if isinstance(limit_name, str):
            normalized = limit_name.casefold()
            if "spark" in normalized or "review" in normalized:
                raise RefreshError("legacy snapshot belongs to another limit")
    else:
        raise RefreshError("invalid rate-limit bucket map")

    candidates: list[dict[str, Any]] = []
    for key in ("primary", "secondary"):
        window = snapshot.get(key)
        if isinstance(window, dict) and window.get("windowDurationMins") == WEEKLY_WINDOW_MINS:
            candidates.append(window)

    if len(candidates) != 1:
        raise RefreshError("weekly Codex window is missing or ambiguous")

    weekly = candidates[0]
    used_percent = weekly.get("usedPercent")
    resets_at = weekly.get("resetsAt")
    if not _is_int(used_percent) or not 0 <= used_percent <= 100:
        raise RefreshError("weekly used percentage is invalid")
    if not _is_int(resets_at) or resets_at <= now:
        raise RefreshError("weekly reset time is invalid")

    windows = {"weekly": _redacted_window(weekly, WEEKLY_WINDOW_MINS, resets_at)}

    # The shorter rolling window (usually five hours) is optional: an invalid or
    # absent session window never fails a refresh that has a valid weekly one.
    for key in ("primary", "secondary"):
        window = snapshot.get(key)
        if not isinstance(window, dict) or window is weekly:
            continue
        duration_mins = window.get("windowDurationMins")
        session_used = window.get("usedPercent")
        session_resets = window.get("resetsAt")
        if (
            _is_int(duration_mins)
            and 0 < duration_mins != WEEKLY_WINDOW_MINS
            and _is_int(session_used)
            and 0 <= session_used <= 100
            and _is_int(session_resets)
            and session_resets > now
        ):
            windows["session"] = _redacted_window(window, duration_mins, session_resets)
        break

    return windows


def make_snapshot(result: dict[str, Any], fetched_at: int) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "fetched_at": fetched_at,
        **select_codex_windows(result, fetched_at),
    }


def default_cache_file() -> Path:
    override = os.environ.get("CC_STATUSLINE_CACHE_FILE")
    if override:
        return Path(override).expanduser()
    cache_home = os.environ.get("XDG_CACHE_HOME")
    root = Path(cache_home).expanduser() if cache_home else Path.home() / ".cache"
    return root / "cc-statusline/codex-quota.json"


def write_snapshot_atomic(path: Path, snapshot: dict[str, Any]) -> None:
    path = path.expanduser()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(snapshot, output, separators=(",", ":"), sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--timeout",
        type=float,
        default=12.0,
        help="total RPC timeout in seconds (default: 12)",
    )
    parser.add_argument(
        "--cache-file",
        type=Path,
        default=None,
        help="override the quota cache path",
    )
    return parser.parse_args()


def main() -> int:
    os.umask(0o077)
    args = parse_args()
    if not 0 < args.timeout <= 120:
        print("cc-statusline quota refresh failed: invalid timeout", file=sys.stderr)
        return 2

    try:
        codex_binary = resolve_codex_binary()
        result = fetch_rate_limits(codex_binary, args.timeout)
        fetched_at = int(time.time())
        snapshot = make_snapshot(result, fetched_at)
        write_snapshot_atomic(args.cache_file or default_cache_file(), snapshot)
    except RefreshError as exc:
        print(f"cc-statusline quota refresh failed: {exc}", file=sys.stderr)
        return 1
    except OSError:
        print("cc-statusline quota refresh failed: cache write error", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
