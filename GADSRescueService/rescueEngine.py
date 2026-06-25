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
import re
import select
import subprocess
import sys
import threading
import time
import logging

# ── Configuration ────────────────────────────────────────────────────────────
BASE_DIR        = os.path.expanduser("~/GADS")   # adjust if needed
LOG_PATTERN     = "pi-provider-*/provider.log"
TARGET_SERVICE  = "gads-provider.service"
ERROR_THRESHOLD = 3     # number of errors that trigger a restart
ERROR_WINDOW    = 300   # sliding window in seconds (5 minutes)
COOLDOWN_SECS   = 120   # minimum seconds between restarts after threshold hit
USB_CHECK_INTERVAL = 30  # seconds between USB debugging-mode polls
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



def check_usb_debug_devices():
    """
    Detect all USB devices currently in Android debugging mode, resolve their
    ADB serials, and restart the ADB server if any connected device is offline.

    Steps:
      1. Run `lsusb` and find all lines containing '(debugging mode)'.
      2. Extract the unique VID:PID from each such line automatically.
      3. For each VID:PID run `sudo lsusb -v -d <VID:PID>` to get iSerial values.
      4. Run `adb devices` and build a serial -> status map.
      5. For each USB serial: if it appears as 'offline' in adb, restart the
         adb server.
    """

    log.info("[USB] Scanning for devices in debugging mode ...")

    # ── Step 1: find all lsusb lines that mention '(debugging mode)' ──────────
    try:
        lsusb_out = subprocess.run(
            ["lsusb"],
            capture_output=True, text=True, timeout=10,
        )
    except Exception as exc:
        log.error("[USB] lsusb failed: %s", exc)
        return

    debug_lines = [
        line for line in lsusb_out.stdout.splitlines()
        if "debugging mode" in line.lower()
    ]

    if not debug_lines:
        log.info("[USB] No devices in debugging mode detected.")
        return

    log.info("[USB] Found %d device(s) in debugging mode:", len(debug_lines))
    for dl in debug_lines:
        log.info("[USB]   %s", dl.strip())

    # ── Step 2: extract unique VID:PID values from those lines ────────────────
    # lsusb format: "Bus 001 Device 035: ID 04e8:6866 Samsung ..."
    vid_pids: set[str] = set()
    for line in debug_lines:
        match = re.search(r"ID\s+([0-9a-fA-F]{4}:[0-9a-fA-F]{4})", line)
        if match:
            vid_pids.add(match.group(1))

    if not vid_pids:
        log.warning("[USB] Could not parse VID:PID from lsusb output.")
        return

    log.info("[USB] Detected VID:PID(s): %s", sorted(vid_pids))

    # ── Step 3: get iSerial for every discovered VID:PID ──────────────────────
    usb_serials: list[str] = []
    for vid_pid in sorted(vid_pids):
        try:
            verbose_out = subprocess.run(
                ["sudo", "lsusb", "-v", "-d", vid_pid],
                capture_output=True, text=True, timeout=15,
            )
        except Exception as exc:
            log.error("[USB] verbose lsusb for %s failed: %s", vid_pid, exc)
            continue

        for line in verbose_out.stdout.splitlines():
            if "iserial" in line.lower():
                # "  iSerial   3 RFCY809VA8W"
                parts = line.strip().split()
                if len(parts) >= 3:
                    usb_serials.append(parts[2])

    if not usb_serials:
        log.warning("[USB] Could not parse any serials from verbose lsusb output.")
        return

    log.info("[USB] Serials detected via lsusb: %s", usb_serials)

    # ── Step 4: query adb devices ─────────────────────────────────────────────
    try:
        adb_out = subprocess.run(
            ["adb", "devices"],
            capture_output=True, text=True, timeout=10,
        )
    except Exception as exc:
        log.error("[USB] `adb devices` failed: %s", exc)
        return

    # Build serial -> status map; lines: "RFCY809VA8W\tdevice" / "...\toffline"
    adb_status: dict[str, str] = {}
    for line in adb_out.stdout.splitlines()[1:]:  # skip header
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) >= 2:
            adb_status[parts[0]] = parts[1]

    log.info("[USB] ADB device statuses: %s", adb_status)

    # ── Step 5: check for offline devices and restart adb if needed ───────────
    offline_found = False
    for serial in usb_serials:
        status = adb_status.get(serial, "not found")
        log.info("[USB] Serial %s -> adb status: %s", serial, status)
        if status == "offline":
            log.warning(
                "[USB] Device %s is connected via USB but offline in ADB.",
                serial,
            )
            offline_found = True

    if offline_found:
        log.warning("[USB] Offline device(s) detected — restarting ADB server.")
        try:
            kill_result = subprocess.run(
                ["adb", "kill-server"],
                capture_output=True, text=True, timeout=10,
            )
            log.info("[USB] adb kill-server: %s", kill_result.stdout.strip() or "ok")

            start_result = subprocess.run(
                ["adb", "start-server"],
                capture_output=True, text=True, timeout=15,
            )
            log.info("[USB] adb start-server: %s", start_result.stdout.strip() or "ok")
        except Exception as exc:
            log.error("[USB] Failed to restart ADB server: %s", exc)
    else:
        log.info("[USB] All detected USB devices are online in ADB.")


def _usb_watcher_loop(stop_event: threading.Event):
    """Background thread: polls check_usb_debug_devices() every USB_CHECK_INTERVAL seconds."""
    log.info("[USB] Watcher thread started — polling every %ds.", USB_CHECK_INTERVAL)
    while not stop_event.is_set():
        try:
            check_usb_debug_devices()
        except Exception as exc:
            log.error("[USB] Watcher loop error: %s", exc)
        stop_event.wait(USB_CHECK_INTERVAL)
    log.info("[USB] Watcher thread stopped.")


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

    # Start the USB debug-device watcher in a daemon background thread
    stop_usb = threading.Event()
    usb_thread = threading.Thread(
        target=_usb_watcher_loop, args=(stop_usb,), daemon=True, name="usb-watcher"
    )
    usb_thread.start()

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
