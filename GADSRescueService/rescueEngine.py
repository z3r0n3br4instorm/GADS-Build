#!/usr/bin/env python3
"""
GADS Provider Log Monitor
Watches all pi-provider-*/provider.log files for error-level entries
and restarts gads-provider.service when 3 errors occur within 5 minutes.
"""

import collections
import glob
import json
import os
import select
import subprocess
import sys
import time
import logging

# ── Configuration ────────────────────────────────────────────────────────────
BASE_DIR        = os.path.expanduser("~/GADS")   # adjust if needed
LOG_PATTERN     = "pi-provider-*/provider.log"
TARGET_SERVICE  = "gads-provider.service"
ERROR_THRESHOLD = 3     # number of errors that trigger a restart
ERROR_WINDOW    = 300   # sliding window in seconds (5 minutes)
COOLDOWN_SECS   = 120   # minimum seconds between restarts after threshold hit
# ─────────────────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger("gads-monitor")


def find_log_files():
    pattern = os.path.join(BASE_DIR, LOG_PATTERN)
    files = glob.glob(pattern)
    if not files:
        log.warning("No log files matched pattern: %s", pattern)
    return files


def is_error_line(line: str) -> bool:
    """Return True if the JSON log line has level == 'error'."""
    line = line.strip()
    if not line:
        return False
    try:
        entry = json.loads(line)
        return str(entry.get("level", "")).lower() == "error"
    except json.JSONDecodeError:
        # Fall back to plain-text check for malformed lines
        return '"level":"error"' in line or '"level": "error"' in line


def restart_service(service: str):
    log.info("Restarting %s ...", service)
    result = subprocess.run(
        ["sudo", "systemctl", "restart", service],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        log.info("Successfully restarted %s", service)
    else:
        log.error(
            "Failed to restart %s (exit %d): %s",
            service, result.returncode, result.stderr.strip()
        )


def tail_files(paths: list[str]):
    """
    Open tail -F processes for all given paths and yield (path, line) tuples.
    Uses select() so a single thread handles all files without blocking.
    """
    procs = {}
    for path in paths:
        try:
            p = subprocess.Popen(
                ["tail", "-F", "-n", "0", path],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            procs[p.stdout] = (p, path)
            log.info("Watching: %s", path)
        except Exception as exc:
            log.error("Could not tail %s: %s", path, exc)

    if not procs:
        log.error("No files to watch — exiting.")
        sys.exit(1)

    try:
        while True:
            fds = list(procs.keys())
            readable, _, _ = select.select(fds, [], [], 5.0)
            for fd in readable:
                _, path = procs[fd]
                line = fd.readline()
                if line:
                    yield path, line
    finally:
        for p, _ in procs.values():
            p.terminate()


def main():
    log.info("GADS log monitor starting — base dir: %s", BASE_DIR)
    log.info(
        "Target service: %s | Threshold: %d errors in %ds | Cooldown: %ds",
        TARGET_SERVICE, ERROR_THRESHOLD, ERROR_WINDOW, COOLDOWN_SECS,
    )

    log_files = find_log_files()
    if not log_files:
        log.error("Exiting: no log files found.")
        sys.exit(1)

    # Sliding window: stores timestamps of recent errors
    error_times: collections.deque[float] = collections.deque()
    last_restart = 0.0

    for path, line in tail_files(log_files):
        if not is_error_line(line):
            continue

        now = time.time()
        log.warning("ERROR detected in %s:\n  %s", path, line.strip())

        # Record this error and drop any outside the window
        error_times.append(now)
        cutoff = now - ERROR_WINDOW
        while error_times and error_times[0] < cutoff:
            error_times.popleft()

        count = len(error_times)
        log.info(
            "Error count in last %ds: %d/%d",
            ERROR_WINDOW, count, ERROR_THRESHOLD,
        )

        if count >= ERROR_THRESHOLD:
            if now - last_restart >= COOLDOWN_SECS:
                log.warning(
                    "Threshold reached (%d errors in %ds) — restarting %s",
                    count, ERROR_WINDOW, TARGET_SERVICE,
                )
                restart_service(TARGET_SERVICE)
                last_restart = now
                error_times.clear()   # reset window after restart
            else:
                remaining = int(COOLDOWN_SECS - (now - last_restart))
                log.info(
                    "Threshold reached but cooldown active (%ds remaining).",
                    remaining,
                )


if __name__ == "__main__":
    main()
