#!/usr/bin/env python3
"""
GADS Software Update Engine
----------------------------
Polls the configured git remote (read from .git/config) on the current branch.
On detecting new commits, performs a git pull and restarts the GADS services.
When the pull changed GadsAuth/, the Auth0 SSO proxy and nginx are rebuilt as well.
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
GADSAUTH_DIR  = os.path.join(REPO_DIR, "GadsAuth")

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


def changed_paths(old: str, new: str) -> list[str]:
    result = run(["git", "diff", "--name-only", old, new], check=False)
    return result.stdout.split() if result.returncode == 0 else []


def rebuild_gadsauth() -> None:
    """Rebuild the SSO proxy and nginx so a pulled GadsAuth change takes effect."""
    if not os.path.exists(os.path.join(GADSAUTH_DIR, ".env")):
        log.warning(
            "GadsAuth changed but %s/.env is missing; run deploy.sh for this node.",
            GADSAUTH_DIR,
        )
        return
    for docker in (["docker"], ["sudo", "-n", "docker"]):
        try:
            if subprocess.run(docker + ["ps"], capture_output=True).returncode != 0:
                continue
            log.info("Rebuilding GadsAuth containers …")
            result = subprocess.run(
                docker + ["compose", "up", "-d", "--build"],
                cwd=GADSAUTH_DIR, capture_output=True, text=True, timeout=1200,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
            log.error("GadsAuth rebuild could not run: %s", exc)
            return
        if result.returncode == 0:
            log.info("GadsAuth containers rebuilt.")
        else:
            lines = (result.stderr.strip() or result.stdout.strip()).splitlines()
            log.error("GadsAuth rebuild failed: %s", lines[-1] if lines else "no output")
        return
    log.error("GadsAuth changed but this user cannot run docker.")


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
                if any(p.startswith("GadsAuth/") for p in changed_paths(local, local_commit())):
                    rebuild_gadsauth()
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
