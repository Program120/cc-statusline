#!/usr/bin/env python3
"""A deterministic fake Codex app-server used by tests."""

from __future__ import annotations

import json
import os
import sys
import time


def receive() -> dict:
    line = sys.stdin.readline()
    if not line:
        raise SystemExit(3)
    return json.loads(line)


def send(message: dict) -> None:
    print(json.dumps(message, separators=(",", ":")), flush=True)


def main() -> int:
    mode = os.environ.get("FAKE_CODEX_MODE", "success")
    if sys.argv[1:] != ["app-server", "--stdio"]:
        return 2

    initialize = receive()
    if initialize.get("method") != "initialize" or initialize.get("id") != 1:
        return 4

    if mode == "timeout":
        time.sleep(30)
        return 0
    if mode == "early-exit":
        return 5

    send({"method": "account/rateLimits/updated", "params": {}})
    send({"id": 99, "result": {}})
    send({"id": 1, "result": {"userAgent": "fake"}})

    initialized = receive()
    request = receive()
    if initialized.get("method") != "initialized":
        return 6
    if request.get("method") != "account/rateLimits/read" or request.get("id") != 2:
        return 7

    if mode == "rpc-error":
        send({"id": 2, "error": {"code": -32000, "message": "secret must not leak"}})
        return 0
    if mode == "null-error":
        payload_error = None
    else:
        payload_error = "omit"

    now = int(time.time())
    payload = {
        "rateLimits": {
            "limitId": "legacy",
            "primary": {
                "usedPercent": 99,
                "windowDurationMins": 10080,
                "resetsAt": now + 99999,
            },
        },
        "rateLimitsByLimitId": {
            "codex": {
                "limitId": "codex",
                "primary": {
                    "usedPercent": 4,
                    "windowDurationMins": 300,
                    "resetsAt": now + 7200,
                },
                "secondary": {
                    "usedPercent": 32,
                    "windowDurationMins": 10080,
                    "resetsAt": now + 604800,
                },
            },
            "codex-spark": {
                "limitId": "codex-spark",
                "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 10080,
                    "resetsAt": now + 500000,
                },
            },
        },
    }
    send({"method": "account/rateLimits/updated", "params": {"ignored": True}})
    response = {"id": 2, "result": payload}
    if payload_error is None:
        response["error"] = None
    send(response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
