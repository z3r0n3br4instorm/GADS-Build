#!/usr/bin/env python3
"""
GADS Software Update Engine
----------------------------
Polls the configured git remote (read from .git/config) on the current branch.
On detecting new commits, performs a git pull and restarts the GADS services.
"""

import subprocess
import time
import logging
import sys
import os

# ── Configuration ────────────────────────────────────────────────────────────
REPO_DIR      = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
POLL_INTERVAL = 60          # seconds between remote checks
SERVICES      = [
    "gads-rescue.service",
    "gads-provider.service",
    "gads-hub.service",
]

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger("gads-software-update")


# ── Helpers ───────────────────────────────────────────────────────────────────

def run(cmd: list[str], check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    """Run a command inside REPO_DIR."""
    return subprocess.run(
        cmd,
        cwd=REPO_DIR,
        check=check,
        capture_output=capture,
        text=True,
    )


def current_branch() -> str:
    result = run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    return result.stdout.strip()


def local_commit() -> str:
    result = run(["git", "rev-parse", "HEAD"])
    return result.stdout.strip()


def remote_commit(branch: str) -> str:
    """Fetch quietly then return the remote HEAD for the current branch."""
    run(["git", "fetch", "--quiet", "origin", branch])
    result = run(["git", "rev-parse", f"origin/{branch}"])
    return result.stdout.strip()


def pull(branch: str) -> None:
    log.info("Pulling latest changes from origin/%s …", branch)
    result = run(["git", "pull", "origin", branch], capture=False)
    if result.returncode != 0:
        raise RuntimeError("git pull failed")
    log.info("Pull complete.")


def restart_services() -> None:
    for svc in SERVICES:
        log.info("Restarting %s …", svc)
        result = subprocess.run(
            ["sudo", "systemctl", "restart", svc],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            log.info("%s restarted successfully.", svc)
        else:
            log.error(
                "Failed to restart %s: %s",
                svc,
                result.stderr.strip() or result.stdout.strip(),
            )


# ── Main loop ─────────────────────────────────────────────────────────────────

def main() -> None:
    log.info("GADS Software Update Engine starting.")
    log.info("Repository : %s", REPO_DIR)
    log.info("Poll interval : %ds", POLL_INTERVAL)
    log.info("Services to restart : %s", ", ".join(SERVICES))

    while True:
        try:
            branch = current_branch()
            local  = local_commit()
            remote = remote_commit(branch)

            log.debug("Local : %s  Remote : %s", local[:12], remote[:12])

            if local != remote:
                log.info(
                    "Update detected on branch '%s': %s → %s",
                    branch, local[:12], remote[:12],
                )
                pull(branch)
                restart_services()
            else:
                log.debug("No update detected. Branch '%s' is up to date.", branch)

        except subprocess.CalledProcessError as exc:
            log.error("Git command failed: %s", exc)
        except Exception as exc:
            log.exception("Unexpected error: %s", exc)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
