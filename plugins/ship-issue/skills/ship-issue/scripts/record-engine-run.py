#!/usr/bin/env python3
"""Atomically append one run record and recompute per-engine token totals."""

from __future__ import annotations

import fcntl
import json
import os
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: record-engine-run.py <ledger.json> <entry.json>", file=sys.stderr)
        raise SystemExit(64)

    ledger_path = Path(sys.argv[1])
    entry_path = Path(sys.argv[2])
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = ledger_path.with_suffix(ledger_path.suffix + ".lock")

    with lock_path.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if ledger_path.exists():
            ledger = json.loads(ledger_path.read_text())
        else:
            ledger = {"runs": [], "totals": {"codex": 0, "claude": 0}}
        entry = json.loads(entry_path.read_text())
        ledger.setdefault("runs", []).append(entry)
        ledger["totals"] = {
            engine: sum(
                run.get("tokens") or 0
                for run in ledger["runs"]
                if run.get("engine") == engine
            )
            for engine in ("codex", "claude")
        }
        temp_path = ledger_path.with_suffix(ledger_path.suffix + f".{os.getpid()}.tmp")
        temp_path.write_text(json.dumps(ledger, indent=2) + "\n")
        os.replace(temp_path, ledger_path)


if __name__ == "__main__":
    main()
