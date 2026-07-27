#!/usr/bin/env python3
"""Phase 7 corpus scan: runs corpus-scan-probe against every .milk file in a directory tree,
one subprocess per preset (crash-resilient - a segfault on one preset can't take down the run),
with a timeout guard, parallelized across a thread pool (subprocess.run releases the GIL while
waiting). Writes a results log and prints periodic progress.
"""
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

PROBE = "/tmp/corpus-scan-probe"
CORPUS_ROOT = Path.home() / "Desktop/BestMilkdropPresetsPack/Presets"
LOG_PATH = Path("/tmp/corpus-scan-results.log")
TIMEOUT_SECONDS = 15
WORKERS = 8

log_lock = threading.Lock()

def scan_one(preset: Path):
    try:
        result = subprocess.run(
            [PROBE, str(preset)],
            capture_output=True, text=True, timeout=TIMEOUT_SECONDS
        )
        if result.returncode == 0:
            return ("pass", preset, "")
        elif result.returncode < 0:
            return ("crash", preset, f"signal {-result.returncode}: {result.stderr.strip()}")
        else:
            return ("fail", preset, result.stderr.strip())
    except subprocess.TimeoutExpired:
        return ("timeout", preset, "")

def main():
    presets = sorted(CORPUS_ROOT.rglob("*.milk"))
    total = len(presets)
    print(f"Found {total} presets under {CORPUS_ROOT}, scanning with {WORKERS} workers")

    counts = {"pass": 0, "fail": 0, "crash": 0, "timeout": 0}
    start = time.time()
    completed = 0

    with LOG_PATH.open("w") as log, ThreadPoolExecutor(max_workers=WORKERS) as pool:
        futures = {pool.submit(scan_one, p): p for p in presets}
        for future in as_completed(futures):
            status, preset, detail = future.result()
            counts[status] += 1
            completed += 1
            if status != "pass":
                with log_lock:
                    log.write(f"{status.upper()}\t{preset}\t{detail}\n")
                    log.flush()

            if completed % 250 == 0 or completed == total:
                elapsed = time.time() - start
                rate = completed / elapsed if elapsed > 0 else 0
                eta = (total - completed) / rate if rate > 0 else 0
                print(
                    f"[{completed}/{total}] pass={counts['pass']} fail={counts['fail']} "
                    f"crash={counts['crash']} timeout={counts['timeout']} "
                    f"({rate:.1f}/s, ETA {eta / 60:.1f}m)",
                    flush=True,
                )

    elapsed = time.time() - start
    print(f"\nDone in {elapsed / 60:.1f} minutes.")
    print(f"pass={counts['pass']} fail={counts['fail']} crash={counts['crash']} timeout={counts['timeout']} total={total}")
    print(f"Pass rate: {100 * counts['pass'] / total:.2f}%")
    print(f"Full log: {LOG_PATH}")

if __name__ == "__main__":
    main()
