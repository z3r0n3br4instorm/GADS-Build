#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# GADS SSO proxy deploy script
# ============================================================
# Deploys GadsAuth (SSO proxy + nginx) to every node listed in a CSV.
# Run it from your own machine; it does not touch install.sh.
#
# For each node it:
#   1. Connects over SSH (key first, then the CSV password)
#   2. Updates GadsAuth on the node: git fetch+merge if it is a git checkout; otherwise,
#      the controller pushes the GadsAuth files there over scp (no GitHub needed on
#      that node). With --no-scp, a node with no git checkout fails here instead.
#   3. Merges deploy.env into the node's GadsAuth/.env
#   4. Rebuilds gads-sso-proxy and restarts gads-nginx
#   5. Checks nginx config and /healthz
#   6. Points cloudflared at nginx (port 80) if a local config.yml routes to the hub;
#      dashboard-managed tunnels take their ingress from the Cloudflare edge, so those are
#      repointed over the API (needs CLOUDFLARE_API_TOKEN in deploy.env) and re-checked
#   7. Prints a PASS/FAIL table per node
#      and saves it to deploy-reports/
#
# Usage:
#   ./deploy.sh                            # deploy.env + nodes.csv next to this script
#   ./deploy.sh -e prod.env -n prod.csv    # other files
#   ./deploy.sh --only 192.168.1.253       # a single node from the CSV
#   ./deploy.sh --branch feat/development  # deploy that branch (default: the one checked out here)
#   ./deploy.sh --install-key              # also install your SSH key on password nodes
#   ./deploy.sh --no-scp                   # fail nodes with no git checkout instead of
#                                          #   pushing the GadsAuth files to them over scp
#
# nodes.csv format (header required, password may be empty for key-only nodes):
#   username,ip,password
#   xg,192.168.1.253,secret

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/deploy.env"
NODES_FILE="$SCRIPT_DIR/nodes.csv"
ONLY_IP=""
BRANCH_ARG=""
INSTALL_KEY=false
SCP_MODE=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
node_log() { echo -e "${BLUE}[$1]${NC} $2"; }

usage() { sed -n '24,32p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ---------- Arguments ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env)      ENV_FILE="$2"; shift 2 ;;
    -n|--nodes)    NODES_FILE="$2"; shift 2 ;;
    --only)        ONLY_IP="$2"; shift 2 ;;
    -b|--branch)   BRANCH_ARG="$2"; shift 2 ;;
    --install-key) INSTALL_KEY=true; shift ;;
    --scp)         SCP_MODE=true; shift ;;
    --no-scp)      SCP_MODE=false; shift ;;
    -h|--help)     usage 0 ;;
    *)             echo "Unknown option: $1"; usage 1 ;;
  esac
done

# ---------- Prerequisite checks ----------
[[ -f "$ENV_FILE" ]]   || err "Env file not found: $ENV_FILE (copy deploy.env.example)"
[[ -f "$NODES_FILE" ]] || err "Nodes file not found: $NODES_FILE (copy nodes.csv.example)"

for f in "$ENV_FILE" "$NODES_FILE"; do
  # GNU stat first: on Linux "-f" means filesystem, succeeds, and prints a block of noise
  perms="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)"
  if [[ "$perms" != "600" && "$perms" != "400" ]]; then
    warn "$f contains secrets but is mode $perms — consider: chmod 600 $f"
  fi
done

# Deploy-only settings (DEPLOY_*, CLOUDFLARE_*) are read here and never written to the node .env
env_get() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed -e 's/^["'\'']//' -e 's/["'\'']$//' || true; }
# Branch the nodes are put on: --branch, else the branch checked out here (so running
# this from main deploys main and from feat/development deploys feat/development),
# else DEPLOY_BRANCH when this is not a git checkout or HEAD is detached, else main.
BRANCH="$BRANCH_ARG"; BRANCH_SRC="--branch"
if [[ -z "$BRANCH" ]]; then
  BRANCH="$(git -C "$SCRIPT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"; BRANCH_SRC="checked out here"
fi
if [[ -z "$BRANCH" ]]; then BRANCH="$(env_get DEPLOY_BRANCH)"; BRANCH_SRC="DEPLOY_BRANCH"; fi
if [[ -z "$BRANCH" ]]; then BRANCH="main"; BRANCH_SRC="default"; fi
REMOTE_DIR="$(env_get DEPLOY_REMOTE_DIR)"; REMOTE_DIR="${REMOTE_DIR:-GADS-Build}"
CF_TOKEN="$(env_get CLOUDFLARE_API_TOKEN)"

for key in AUTH0_DOMAIN AUTH0_CLIENT_ID AUTH0_CLIENT_SECRET; do
  [[ -n "$(env_get "$key")" ]] || err "$key is empty in $ENV_FILE"
done

log "Deploying branch: $BRANCH ($BRANCH_SRC)"

# Nodes pull from GitHub, so warn if local commits haven't been pushed
if git -C "$SCRIPT_DIR" rev-parse --git-dir &>/dev/null; then
  # Never prompt for credentials, and give up after 15s; this check only produces a warning
  GIT_TERMINAL_PROMPT=0 git -C "$SCRIPT_DIR" -c credential.helper= fetch -q origin "$BRANCH" </dev/null >/dev/null 2>&1 &
  fetch_pid=$!
  for _ in $(seq 1 15); do kill -0 "$fetch_pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$fetch_pid" 2>/dev/null; then
    kill "$fetch_pid" 2>/dev/null || true
    warn "Could not reach origin to check for unpushed commits (skipped)."
  fi
  wait "$fetch_pid" 2>/dev/null || true
  ahead="$(git -C "$SCRIPT_DIR" rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null || echo 0)"
  dirty="$(git -C "$SCRIPT_DIR" status --porcelain -- GadsAuth | wc -l | tr -d ' ')"
  [[ "$ahead" == "0" ]] || warn "$ahead local commit(s) not pushed to origin/$BRANCH — nodes won't get them."
  [[ "$dirty" == "0" ]] || warn "Uncommitted changes in GadsAuth/ — nodes won't get them."
fi

# Override lines sent to each node: everything except comments, blanks, DEPLOY_* and
# CLOUDFLARE_* keys (the Cloudflare token is only used locally by set-tunnel-port.py)
OVERRIDES_B64="$(grep -vE '^\s*(#|$)|^DEPLOY_|^CLOUDFLARE_' "$ENV_FILE" | base64 | tr -d '\n')"

# ---------- SSH helpers ----------
WORK_DIR="$(mktemp -d)"
trap 'for s in "$WORK_DIR"/ctl-*; do [[ -S "$s" ]] && close_connection "$s" localhost; done; rm -rf "$WORK_DIR"' EXIT

# Askpass helper: hands the password to ssh from an env var (never on the command line)
ASKPASS="$WORK_DIR/askpass.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$DEPLOY_SSH_PASS"\n' > "$ASKPASS"
chmod 700 "$ASKPASS"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ConnectionAttempts=2
          -o ServerAliveInterval=10 -o ServerAliveCountMax=12)

# Opens a shared master connection so the password (if any) is only used once per node
open_connection() {
  local target="$1" pass="$2" ctl="$3"
  if ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ControlMaster=yes -o ControlPath="$ctl" \
       -o ControlPersist=600 -fN "$target" </dev/null >/dev/null 2>&1; then
    echo "key"; return 0
  fi
  [[ -n "$pass" ]] || return 1
  if DEPLOY_SSH_PASS="$pass" SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
       ssh "${SSH_OPTS[@]}" -o PreferredAuthentications=password,keyboard-interactive \
       -o NumberOfPasswordPrompts=1 -o ControlMaster=yes -o ControlPath="$ctl" \
       -o ControlPersist=600 -fN "$target" </dev/null >/dev/null 2>&1; then
    echo "password"; return 0
  fi
  return 1
}

# Runs a command over the node's master connection
run_remote() {
  local ctl="$1" target="$2"; shift 2
  ssh -o ControlPath="$ctl" -o BatchMode=yes "$target" "$@"
}

close_connection() {
  ssh -o ControlPath="$1" -O exit "$2" </dev/null >/dev/null 2>&1 || true
}

# Runs a remote script, appending every line to a log file and printing check results.
# @@TUNNEL_BYPASS lines are machine-readable and consumed by the caller, so they stay hidden.
stream_checks() {
  local ctl="$1" target="$2" ip="$3" out_file="$4" script="$5"; shift 5
  set +e
  run_remote "$ctl" "$target" bash -s -- "$@" <<<"$script" 2>&1 \
    | while IFS= read -r line; do
        echo "$line" >> "$out_file"
        case "$line" in
          @@CHECK\|*)
            IFS='|' read -r _ name st detail <<<"$line"
            case "$st" in
              PASS) color="$GREEN" ;; WARN) color="$YELLOW" ;; *) color="$RED" ;;
            esac
            node_log "$ip" "${color}${st}${NC} ${name}: ${detail}" ;;
          @@TUNNEL_BYPASS\|*) ;;
          *) node_log "$ip" "  $line" ;;
        esac
      done
  set -e
}

install_pubkey() {
  local ctl="$1" target="$2" pub
  pub="$(ls "$HOME"/.ssh/id_ed25519.pub "$HOME"/.ssh/id_rsa.pub 2>/dev/null | head -1 || true)"
  [[ -n "$pub" ]] || { warn "No local public key found (run: ssh-keygen -t ed25519)"; return 0; }
  run_remote "$ctl" "$target" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    k="$(cat)"; grep -qxF "$k" ~/.ssh/authorized_keys || echo "$k" >> ~/.ssh/authorized_keys' < "$pub"
}

# ---------- Node-side discovery helpers (prepended to the scripts below) ----------
# The running gads-hub.service unit is the authoritative source for where GADS is
# installed and which port it listens on. GadsAuth/.env and the built-in defaults are
# only fallbacks, so a node with the hub in ~/GADS instead of ~/GADS-Build still works.
NODE_HELPERS='
# macOS runs path_helper only for login shells, so a non-interactive `ssh ... bash -s`
# session (what this script uses) never sees the Docker Desktop CLI even though it is
# installed and works fine in an interactive terminal. Harmless no-op on Linux.
if [ -x /usr/libexec/path_helper ]; then eval "$(/usr/libexec/path_helper -s)"; fi
PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin"
export PATH

GADS_HUB_PLIST="$HOME/Library/LaunchAgents/com.gads.hub.plist"

# Hub command line: the systemd unit on Linux, the launchd plist on macOS
gads_hub_exec() {
  local out
  out="$(systemctl show -p ExecStart --value gads-hub.service 2>/dev/null)"
  if [ -z "$out" ] && [ -f "$GADS_HUB_PLIST" ]; then
    out="$(sed -n "s/.*<string>\(.*\)<\/string>.*/\1/p" "$GADS_HUB_PLIST" | tr "\n" " ")"
  fi
  printf "%s\n" "$out"
}

# Hub install directory: WorkingDirectory if set, else the directory of its binary
gads_hub_dir() {
  local d bin
  d="$(systemctl show -p WorkingDirectory --value gads-hub.service 2>/dev/null)"
  if [ -z "$d" ]; then
    bin="$(gads_hub_exec | sed -n "s/.*argv\[\]=\([^ ]*\).*/\1/p" | head -1)"
    [ -n "$bin" ] && d="$(dirname "$bin")"
  fi
  # macOS: launchd plist, then the usual install location
  if [ -z "$d" ] && [ -f "$GADS_HUB_PLIST" ]; then
    d="$(awk "/<key>WorkingDirectory<\\/key>/{getline; gsub(/.*<string>|<\\/string>.*/,\"\"); print; exit}" "$GADS_HUB_PLIST")"
  fi
  if [ -z "$d" ] && [ -x "$HOME/Documents/GADS/GADS" ]; then d="$HOME/Documents/GADS"; fi
  printf "%s\n" "$d"
}

# Hub listen port from the unit, accepting --port=N or --port N
gads_hub_port() {
  gads_hub_exec | sed -n "s/.*--port[= ]\([0-9]\{1,\}\).*/\1/p" | head -1
}

# First candidate that actually holds the GadsAuth deployment. An explicit
# DEPLOY_REMOTE_DIR wins; otherwise the unit tells us where to look.
resolve_repo_dir() {
  local prefer="$1" c
  for c in ${prefer:+"$HOME/$prefer"} "$HOME/GADS-Build" "$(gads_hub_dir)" "$HOME/GADS" "$HOME/Documents/GADS"; do
    [ -n "$c" ] || continue
    if [ -f "$c/GadsAuth/docker-compose.yml" ]; then
      printf "%s\n" "$c"; return 0
    fi
  done
  return 1
}

# How this deployment is updated: "git <dir>" when the resolve_repo_dir match is a git
# checkout (fetch+merge applies), otherwise "scp <dir>" - <dir> is that match, or for a
# first-ever scp push the folder GADS itself is installed in, else $HOME/<prefer>.
resolve_repo_mode() {
  local prefer="$1" d
  d="$(resolve_repo_dir "$prefer")"
  if [ -n "$d" ] && [ -d "$d/.git" ]; then
    printf "git %s\n" "$d"; return
  fi
  [ -n "$d" ] || d="$(gads_hub_dir)"
  [ -d "$d" ] || d="$HOME/$prefer"
  printf "scp %s\n" "$d"
}

# Hub port with documented precedence: unit, then .env, then the default
resolve_gads_port() {
  local p
  p="$(gads_hub_port)"
  if [ -n "$p" ]; then printf "%s unit\n" "$p"; return; fi
  p="$(sed -n "s/^GADS_PORT=//p" .env 2>/dev/null | tail -1)"
  if [ -n "$p" ]; then printf "%s .env\n" "$p"; return; fi
  printf "10000 default\n"
}
'

# ---------- Remote deploy steps (runs on the node) ----------
# Args: branch, remote dir, base64 env overrides
# Each check prints "@@CHECK|<name>|PASS|FAIL|WARN|<detail>"; the first FAIL stops the node.
REMOTE_SCRIPT='
BRANCH="$1"; REMOTE_DIR="$2"; OVERRIDES_B64="$3"; MODE="${4:-git}"; SCP_DIR="$5"; SCP_ERR="$6"
check() { printf "@@CHECK|%s|%s|%s\n" "$1" "$2" "$3"; }
fail()  { check "$1" FAIL "$2"; exit 1; }
cd ~ || fail PREREQ "no home directory"

# PREREQ: tools and docker access. git is only needed on a git-managed node; an
# scp-managed node (MODE=scp, enabled by the --scp flag) never touches git.
tools="docker python3 curl"; [ "$MODE" = "git" ] && tools="git $tools"
for tool in $tools; do
  command -v "$tool" >/dev/null || fail PREREQ "$tool is not installed"
done
if docker ps >/dev/null 2>&1; then DOCKER="docker"
elif sudo -n docker ps >/dev/null 2>&1; then DOCKER="sudo -n docker"
else fail PREREQ "user cannot run docker (add it to the docker group)"; fi
if $DOCKER compose version >/dev/null 2>&1; then COMPOSE="$DOCKER compose"
else COMPOSE="${DOCKER%docker}docker-compose"; fi
check PREREQ PASS "docker, python3, curl$([ "$MODE" = "git" ] && echo ", git")"

if [ "$MODE" = "scp" ]; then
  # REPO/PULL: the controller already pushed the GadsAuth files here via scp (--scp),
  # since this node has no git checkout. Nothing to fetch; just confirm they arrived.
  [ -z "$SCP_ERR" ] || fail REPO "$SCP_ERR"
  REPO_DIR="$SCP_DIR"
  [ -f "$REPO_DIR/GadsAuth/docker-compose.yml" ] || fail REPO "scp did not deliver $REPO_DIR/GadsAuth/docker-compose.yml"
  cd "$REPO_DIR" || fail REPO "cannot enter $REPO_DIR"
  check REPO PASS "${REPO_DIR#$HOME/} (scp-managed, no git on this node)"
  check PULL PASS "files pushed from the controller via scp (no git on this node)"
else
  # REPO: must already exist on the node; never cloned here. Located from the gads-hub
  # unit when it is not at the expected path, so an install in ~/GADS still deploys.
  REPO_DIR="$(resolve_repo_dir "$REMOTE_DIR")" || fail REPO "no GadsAuth checkout found (tried ~/$REMOTE_DIR, ~/GADS-Build, $(gads_hub_dir) from gads-hub.service, ~/GADS); each must be a git repo containing GadsAuth/docker-compose.yml."
  cd "$REPO_DIR" || fail REPO "cannot enter $REPO_DIR"
  check REPO PASS "${REPO_DIR#$HOME/}$([ "$REPO_DIR" = "$HOME/$REMOTE_DIR" ] || echo " (discovered, not ~/$REMOTE_DIR)")"

  # PULL: back up local edits, then fast-forward to origin
  note=""
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    stash_msg="deploy.sh backup $(date +%Y%m%d-%H%M%S)"
    git stash push -q -m "$stash_msg" || fail PULL "could not stash local edits"
    note=" (local edits stashed: $stash_msg)"
  fi
  out="$(git fetch -q origin "$BRANCH" 2>&1)" || fail PULL "fetch failed: $(echo "$out" | tail -1)"
  git checkout -q "$BRANCH" 2>/dev/null || fail PULL "cannot check out $BRANCH"
  out="$(git merge -q --ff-only "origin/$BRANCH" 2>&1)" || fail PULL "not a fast-forward: $(echo "$out" | tail -1)"
  check PULL PASS "$(git log --oneline -1 | cut -c1-60)$note"
fi

# ENV: keep existing node values, override with non-empty deploy.env values
cd GadsAuth
echo "$OVERRIDES_B64" | base64 -d > .env.overrides || fail ENV "could not decode deploy.env"
env_out="$(python3 - <<"PY" 2>&1
import os, re, secrets
def parse(path):
    out = {}
    if os.path.exists(path):
        for line in open(path):
            m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$", line.rstrip("\n"))
            if m:
                out[m.group(1)] = m.group(2).strip()
    return out
current = parse(".env")
overrides = {k: v for k, v in parse(".env.overrides").items() if v.strip("\"\x27")}
changed = sorted(k for k, v in overrides.items() if current.get(k) != v)
current.update(overrides)
if not current.get("FLASK_SECRET_KEY"):
    current["FLASK_SECRET_KEY"] = secrets.token_hex(32)
    changed.append("FLASK_SECRET_KEY(generated)")
fd = os.open(".env.tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("# Managed by deploy.sh; values from deploy.env override this file on every deploy\n")
    for k, v in current.items():
        f.write(f"{k}={v}\n")
os.replace(".env.tmp", ".env")
print("changed: " + (" ".join(changed) if changed else "none"))
PY
)"
rc=$?
rm -f .env.overrides
[ $rc -eq 0 ] || fail ENV "merge failed: $(echo "$env_out" | tail -1)"
chmod 600 .env
check ENV PASS "$env_out"

# BUILD: rebuild the proxy and nginx images (app.py and the nginx config are baked in)
# Both steps are time-limited and echo their progress, so a stuck image pull or build
# shows where it stopped instead of hanging the whole deploy with no output.
bounded() {
  local limit="$1" log="$2" pid waited=0 shown=0 total
  shift 2
  "$@" >"$log" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5; waited=$((waited + 5))
    total="$(wc -l < "$log" | tr -d " ")"
    if [ "$total" -gt "$shown" ]; then
      sed -n "$((shown + 1)),${total}p" "$log" | grep -E "^#[0-9]+ (\[|DONE|CACHED|ERROR)|[Ee]rror|Pull|Container" | tail -3
      shown="$total"
    fi
    if [ "$waited" -ge "$limit" ]; then
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      return 124
    fi
  done
  wait "$pid"
}
# macOS: over SSH the login keychain is locked, and Docker Desktop asks it for registry
# credentials even for public images, which stalls or fails the pull. Use a copy of the
# docker config without the keychain helper; contexts and plugins stay the same.
if [ "$(uname)" = "Darwin" ] && grep -q "credsStore" "$HOME/.docker/config.json" 2>/dev/null; then
  DOCKER_CONFIG="$(mktemp -d)"; export DOCKER_CONFIG
  python3 - <<"PY"
import json, os
cfg = json.load(open(os.path.expanduser("~/.docker/config.json")))
cfg.pop("credsStore", None); cfg.pop("credHelpers", None)
json.dump(cfg, open(os.path.join(os.environ["DOCKER_CONFIG"], "config.json"), "w"))
PY
  for d in contexts cli-plugins; do
    [ -e "$HOME/.docker/$d" ] && ln -s "$HOME/.docker/$d" "$DOCKER_CONFIG/$d"
  done
  echo "macOS: using docker config without the keychain credential helper"
fi
build_log="$(mktemp)"
BUILDKIT_PROGRESS=plain; export BUILDKIT_PROGRESS
bounded "${BUILD_TIMEOUT:-900}" "$build_log" $COMPOSE build gads-sso-proxy nginx; rc=$?
[ $rc -ne 124 ] || fail BUILD "build timed out after ${BUILD_TIMEOUT:-900}s; last output: $(grep -v "^[[:space:]]*$" "$build_log" | tail -1)"
[ $rc -eq 0 ] || fail BUILD "build failed: $(tail -1 "$build_log")"
bounded 300 "$build_log" $COMPOSE up -d; rc=$?
[ $rc -ne 124 ] || fail BUILD "compose up timed out after 300s; last output: $(grep -v "^[[:space:]]*$" "$build_log" | tail -1)"
[ $rc -eq 0 ] || fail BUILD "compose up failed: $(grep -v "gads-net exists" "$build_log" | tail -1)"
rm -f "$build_log"
$DOCKER restart gads-nginx >/dev/null 2>&1 || fail BUILD "could not restart gads-nginx"
sleep 4
for c in gads-sso-proxy gads-nginx; do
  state="$($DOCKER inspect -f "{{.State.Status}}" "$c" 2>/dev/null || echo missing)"
  [ "$state" = "running" ] || fail BUILD "$c is $state"
done
check BUILD PASS "gads-sso-proxy and gads-nginx running"

# NGINX: config test inside the container
out="$($DOCKER exec gads-nginx nginx -t 2>&1)" || fail NGINX "$(echo "$out" | grep -i emerg | tail -1)"
check NGINX PASS "config ok"

# HEALTH: proxy answers through nginx
port="$(sed -n "s/^NGINX_PORT=//p" .env | tail -1)"; port="${port:-80}"
health="$(curl -s -o /dev/null -w "%{http_code}" -m 10 "http://localhost:${port}/healthz" || true)"
[ "$health" = "200" ] || fail HEALTH "http://localhost:${port}/healthz returned ${health:-no response}"
check HEALTH PASS "localhost:${port}/healthz 200"

# HUB: GADS hub behind the proxy (warning only). Port comes from the running unit.
gport_info="$(resolve_gads_port)"; gport="${gport_info%% *}"; gport_src="${gport_info#* }"
if curl -s -o /dev/null -m 5 "http://localhost:${gport}/"; then check HUB PASS "localhost:${gport} answering (port from $gport_src)"
else check HUB WARN "GADS hub not answering on localhost:${gport} (port from $gport_src)"; fi
'

# ---------- Tunnel check (runs on the node, separately so it can be re-run) ----------
# Args: remote dir. Prints "@@CHECK|TUNNEL|..." and, when routes bypass SSO,
# "@@TUNNEL_BYPASS|<nginx port>|<hostnames>" so the caller can fix them over the API.
TUNNEL_SCRIPT='
REMOTE_DIR="$1"
check() { printf "@@CHECK|%s|%s|%s\n" "$1" "$2" "$3"; }
# nginx port lives in GadsAuth/.env; the hub port comes from the gads-hub unit. Missing
# checkout is not fatal here: the tunnel can still be checked against the unit port.
REPO_DIR="$(resolve_repo_dir "$REMOTE_DIR")" && cd "$REPO_DIR/GadsAuth" 2>/dev/null
port="$(sed -n "s/^NGINX_PORT=//p" .env 2>/dev/null | tail -1)"; port="${port:-80}"
gport_info="$(resolve_gads_port)"; gport="${gport_info%% *}"
if ! command -v cloudflared >/dev/null && ! systemctl cat cloudflared >/dev/null 2>&1; then
  check TUNNEL WARN "cloudflared not installed on this node"
  exit 0
fi
SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo -n"
tunnel_out="$(NGINX_PORT="$port" GADS_PORT="$gport" SUDO="$SUDO" python3 - <<"PY" 2>&1
import json, os, re, subprocess, sys, tempfile, time
ng, gp = os.environ["NGINX_PORT"], os.environ["GADS_PORT"]
sudo = os.environ["SUDO"].split()

def run(cmd, **kw):
    # Degrade like the bash helpers do on a node with no systemd (e.g. macOS): treat a
    # missing binary as a failed command instead of crashing the whole check.
    try:
        return subprocess.run(cmd, capture_output=True, text=True, **kw)
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, 127, "", f"{cmd[0]}: not found")

def done(status, msg):
    print(msg)
    sys.exit({"PASS": 0, "WARN": 2, "FAIL": 1}[status])

def read(path):
    try:
        return open(path).read()
    except PermissionError:
        r = run(sudo + ["cat", path])
        return r.stdout if r.returncode == 0 else None
    except FileNotFoundError:
        return None

LOCAL = r"(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])"
def port_of(service):
    m = re.match(r"^\w+://" + LOCAL + r":(\d+)", service or "")
    return m.group(1) if m else None

exec_start = run(["systemctl", "show", "-p", "ExecStart", "--value", "cloudflared"]).stdout
unit_env = run(["systemctl", "show", "-p", "Environment", "--value", "cloudflared"]).stdout
token_mode = "--token" in exec_start or "TUNNEL_TOKEN" in unit_env

m = re.search(r"--config[ =](\S+)", exec_start)
paths = ([m.group(1)] if m else []) + [
    "/etc/cloudflared/config.yml", "/etc/cloudflared/config.yaml",
    os.path.expanduser("~/.cloudflared/config.yml"), os.path.expanduser("~/.cloudflared/config.yaml"),
]
config_path = next((p for p in paths if (read(p) or "").find("ingress") >= 0), None)

if config_path and not token_mode:
    # Locally managed: rewrite rules that target the hub port, validate, restart
    text = read(config_path)
    rule = re.compile(r"^(\s*-?\s*service:\s*)[\"]?(\w+)://(" + LOCAL + r"):" + re.escape(gp) + r"[\"]?(\s*(#.*)?)$")
    lines, moved = [], 0
    for line in text.splitlines(keepends=True):
        mm = rule.match(line.rstrip("\n"))
        if mm:
            line = mm.group(1) + "http://localhost:" + ng + (mm.group(4) or "") + "\n"
            moved += 1
        lines.append(line)
    services = re.findall(r"service:\s*[\"]?(\S+?)[\"]?\s*(?:#.*)?$", text, re.M)
    if not moved:
        if any(port_of(s) == ng for s in services):
            done("PASS", f"{config_path}: already routes to localhost:{ng}")
        listed = ", ".join(services) or "none"
        done("WARN", f"{config_path}: no rule targets localhost:{gp} or :{ng} (services: {listed})")
    backup = config_path + ".bak-deploy-" + time.strftime("%Y%m%d-%H%M%S")
    with tempfile.NamedTemporaryFile("w", delete=False) as tmp:
        tmp.write("".join(lines))
    writer = [] if os.access(os.path.dirname(config_path), os.W_OK) else sudo
    for cmd in (writer + ["cp", "-p", config_path, backup], writer + ["cp", tmp.name, config_path]):
        r = run(cmd)
        if r.returncode:
            why = (r.stderr or "permission denied").strip()
            done("FAIL", f"cannot write {config_path} ({why}); needs passwordless sudo")
    os.unlink(tmp.name)
    v = run(writer + ["cloudflared", "tunnel", "--config", config_path, "ingress", "validate"])
    if v.returncode:
        run(writer + ["cp", "-p", backup, config_path])
        last = ((v.stderr or v.stdout).strip().splitlines() or ["no output"])[-1]
        done("FAIL", f"new config failed validation, restored backup: {last}")
    r = run(sudo + ["systemctl", "restart", "cloudflared"])
    if r.returncode:
        done("FAIL", f"updated {config_path} but could not restart cloudflared: {r.stderr.strip()}")
    time.sleep(3)
    state = run(["systemctl", "is-active", "cloudflared"]).stdout.strip()
    if state != "active":
        run(writer + ["cp", "-p", backup, config_path]); run(sudo + ["systemctl", "restart", "cloudflared"])
        done("FAIL", f"cloudflared {state} after change, restored backup")
    done("PASS", f"{config_path}: moved {moved} rule(s) localhost:{gp} -> localhost:{ng}, restarted (backup {os.path.basename(backup)})")

if token_mode:
    # Dashboard-managed: routes live at Cloudflare; read the last config cloudflared received
    log = ""
    for cmd in (sudo + ["journalctl", "-u", "cloudflared", "--no-pager", "-o", "cat", "-n", "5000"],
                ["journalctl", "-u", "cloudflared", "--no-pager", "-o", "cat", "-n", "5000"]):
        r = run(cmd)
        if r.returncode == 0 and r.stdout.strip():
            log = r.stdout
            break
    updates = [l for l in log.splitlines() if "Updated to new configuration" in l]
    if not updates:
        done("WARN", "dashboard-managed tunnel; routes not found in cloudflared logs (check the dashboard)")
    raw = updates[-1]
    mm = re.search(r"config=\"(.*)\"\s+version=", raw)
    routes = []
    if mm:
        try:
            cfg = json.loads(mm.group(1).replace("\\\"", "\""))
            routes = [(r.get("hostname") or "*", r.get("service", "")) for r in cfg.get("ingress", [])]
        except ValueError:
            pass
    if not routes:
        routes = [("?", s) for s in re.findall(r"service\W+(\w+://[^\\\"]+)", raw)]
    bad = [f"{h} -> {s}" for h, s in routes if port_of(s) == gp]
    good = [f"{h} -> {s}" for h, s in routes if port_of(s) == ng]
    if not bad:
        if good:
            done("PASS", "dashboard-managed: " + "; ".join(good))
        done("WARN", "dashboard-managed; no route to localhost:" + ng
             + " (" + "; ".join(f"{h} -> {s}" for h, s in routes) + ")")

    # cloudflared cannot override this from the node: for a dashboard-managed tunnel the
    # connector fetches its ingress from the edge on every start and ignores local ingress
    # rules. So hand the hostnames back and let the caller fix them over the Cloudflare API.
    bad_hosts = sorted({h for h, s in routes if port_of(s) == gp and h not in ("*", "?")})
    if bad_hosts:
        print("BYPASS:" + " ".join(bad_hosts))
    done("FAIL", "dashboard-managed tunnel bypasses SSO: " + "; ".join(bad)
         + f". Needs its ingress changed at Cloudflare to HTTP localhost:{ng}"
         + " (deploy.sh does that automatically when CLOUDFLARE_API_TOKEN is set)")

done("WARN", "cloudflared found but no config.yml or tunnel token; cannot tell where it routes")
PY
)"
rc=$?
first="$(printf "%s" "$tunnel_out" | head -1)"
case "$first" in
  BYPASS:*)
    printf "@@TUNNEL_BYPASS|%s|%s\n" "$port" "${first#BYPASS:}"
    tunnel_out="$(printf "%s" "$tunnel_out" | tail -n +2)" ;;
esac
case $rc in
  0) check TUNNEL PASS "$tunnel_out" ;;
  2) check TUNNEL WARN "$tunnel_out" ;;
  *) check TUNNEL FAIL "$tunnel_out" ;;
esac
'

CHECKS=(SSH PREREQ REPO PULL ENV BUILD NGINX HEALTH HUB TUNNEL)

# ---------- Main loop ----------
REPORT_DIR="$SCRIPT_DIR/deploy-reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/deploy-$(date +%Y%m%d-%H%M%S).csv"
echo "node,result,$(IFS=,; echo "${CHECKS[*]}"),detail" > "$REPORT"

declare -a NODES=() STATUSES=() RESULTS=() DETAILS=()
count=0

# Records one node's outcome. Statuses are space-separated, one per entry in CHECKS.
record() {
  NODES+=("$1"); STATUSES+=("$2"); RESULTS+=("$3"); DETAILS+=("$4")
  local csv_detail="${4//\"/\'}"
  echo "$1,$3,${2// /,},\"$csv_detail\"" >> "$REPORT"
}

while IFS=, read -r user ip pass || [[ -n "${user:-}" ]]; do
  user="$(echo "${user:-}" | tr -d '\r' | xargs)"
  ip="$(echo "${ip:-}" | tr -d '\r' | xargs)"
  pass="$(printf '%s' "${pass:-}" | tr -d '\r')"
  [[ -z "$user" || "$user" == \#* || "$user" == "username" ]] && continue
  [[ -n "$ONLY_IP" && "$ip" != "$ONLY_IP" ]] && continue
  [[ -n "$ip" ]] || { warn "Skipping row for '$user': no ip"; continue; }
  count=$((count + 1))

  target="$user@$ip"
  ctl="$WORK_DIR/ctl-$count"
  out_file="$WORK_DIR/out-$count"
  echo ""
  log "━━━━━━━━ $target ━━━━━━━━"

  if ! method="$(open_connection "$target" "$pass" "$ctl")"; then
    node_log "$ip" "${RED}FAIL${NC} SSH: could not connect (network, key or password)"
    statuses="FAIL"; for _ in "${CHECKS[@]:1}"; do statuses+=" SKIP"; done
    record "$target" "$statuses" "FAIL" "SSH: could not connect"
    continue
  fi
  node_log "$ip" "${GREEN}PASS${NC} SSH: $method auth"

  if [[ "$method" == "password" && "$INSTALL_KEY" == true ]]; then
    install_pubkey "$ctl" "$target" && node_log "$ip" "installed SSH key for future deploys"
  fi

  # With --scp, a node that has no git checkout gets GadsAuth'"'"'s files pushed from
  # here instead of failing REPO. A node that already has a git checkout is untouched
  # and keeps updating via git, so --scp only ever adds a fallback, never overrides git.
  # A push failure is handed to REMOTE_SCRIPT as SCP_ERR rather than reported here, so
  # PREREQ still runs and reports first - same FAIL/SKIP ordering as every other node.
  MODE="git"; SCP_DIR=""; SCP_ERR=""
  if [[ "$SCP_MODE" == true ]]; then
    probe="$(run_remote "$ctl" "$target" bash -s -- "$REMOTE_DIR" \
      <<<"$NODE_HELPERS"'resolve_repo_mode "$1"' 2>/dev/null)"
    read -r MODE SCP_DIR <<<"$probe"
    if [[ "$MODE" == "scp" ]]; then
      node_log "$ip" "no git checkout found; pushing GadsAuth files via scp to $SCP_DIR"
      if ! run_remote "$ctl" "$target" "mkdir -p '$SCP_DIR/GadsAuth'" 2>/dev/null; then
        SCP_ERR="could not create $SCP_DIR/GadsAuth on the node"
      elif scp -o ControlPath="$ctl" -o BatchMode=yes \
           "$SCRIPT_DIR"/GadsAuth/{docker-compose.yml,nginx-gads.conf,Dockerfile,Dockerfile.nginx,app.py,requirements.txt} \
           "$target:$SCP_DIR/GadsAuth/" >/dev/null 2>"$WORK_DIR/scp-err-$count"; then
        node_log "$ip" "pushed docker-compose.yml, nginx-gads.conf, Dockerfile, Dockerfile.nginx, app.py, requirements.txt"
      else
        SCP_ERR="scp push failed: $(tail -1 "$WORK_DIR/scp-err-$count")"
      fi
    fi
  fi

  : > "$out_file"
  stream_checks "$ctl" "$target" "$ip" "$out_file" "$NODE_HELPERS$REMOTE_SCRIPT" \
    "$BRANCH" "$REMOTE_DIR" "$OVERRIDES_B64" "$MODE" "$SCP_DIR" "$SCP_ERR"

  # TUNNEL runs on its own so a dashboard route that bypasses SSO can be repointed over
  # the Cloudflare API and then re-checked, rather than just reported
  if grep -q "^@@CHECK|HEALTH|PASS" "$out_file"; then
    stream_checks "$ctl" "$target" "$ip" "$out_file" "$NODE_HELPERS$TUNNEL_SCRIPT" "$REMOTE_DIR"
    bypass_line="$(grep "^@@TUNNEL_BYPASS|" "$out_file" | tail -1 || true)"
    if [[ -n "$bypass_line" ]]; then
      IFS='|' read -r _ ng_port bypass_hosts <<<"$bypass_line"
      if [[ -z "$CF_TOKEN" ]]; then
        node_log "$ip" "  set CLOUDFLARE_API_TOKEN in ${ENV_FILE##*/} to let deploy.sh fix this"
      else
        node_log "$ip" "  repointing tunnel over the Cloudflare API: $bypass_hosts -> localhost:$ng_port"
        set +e
        # bypass_hosts is deliberately unquoted: it may hold several hostnames
        cf_out="$("$SCRIPT_DIR/set-tunnel-port.py" $bypass_hosts --port "$ng_port" \
                  --apply -e "$ENV_FILE" 2>&1)"
        cf_rc=$?
        set -e
        while IFS= read -r l; do [[ -z "$l" ]] || node_log "$ip" "  $l"; done <<<"$cf_out"
        if [[ $cf_rc -eq 0 ]]; then
          sleep 8   # let the edge push the new ingress to the connector
          stream_checks "$ctl" "$target" "$ip" "$out_file" "$NODE_HELPERS$TUNNEL_SCRIPT" "$REMOTE_DIR"
        fi
      fi
    fi
  fi
  close_connection "$ctl" "$target"

  # Build the status row; checks never reached are SKIP
  statuses="PASS"; result="PASS"; detail=""
  for name in "${CHECKS[@]:1}"; do
    line="$(grep -E "^@@CHECK\|$name\|" "$out_file" | tail -1 || true)"
    if [[ -z "$line" ]]; then
      st="SKIP"
    else
      IFS='|' read -r _ _ st d <<<"$line"
      if [[ "$st" == "FAIL" ]]; then result="FAIL"; detail="$name: $d"; fi
      if [[ "$st" == "WARN" && -z "$detail" ]]; then detail="$name: $d"; fi
    fi
    statuses+=" $st"
  done
  # Lost connection or crash before HEALTH reported anything
  if [[ "$result" == "PASS" ]] && ! grep -q "^@@CHECK|HEALTH|PASS" "$out_file"; then
    result="FAIL"; detail="connection lost or script stopped: $(grep -v '^@@CHECK' "$out_file" | tail -1)"
  fi
  record "$target" "$statuses" "$result" "$detail"
done < "$NODES_FILE"

[[ $count -gt 0 ]] || err "No nodes to deploy${ONLY_IP:+ matching $ONLY_IP} in $NODES_FILE"

# ---------- Summary ----------
color_status() {
  case "$1" in
    PASS) printf "${GREEN}%-7s${NC}" "$1" ;;
    FAIL) printf "${RED}%-7s${NC}" "$1" ;;
    WARN) printf "${YELLOW}%-7s${NC}" "$1" ;;
    *)    printf "%-7s" "$1" ;;
  esac
}

echo ""
log "━━━━━━━━ Summary ━━━━━━━━"
width=4
for n in "${NODES[@]}"; do (( ${#n} > width )) && width=${#n}; done
printf "  %-${width}s  %-7s" "NODE" "RESULT"
for c in "${CHECKS[@]}"; do printf " %-7s" "$c"; done
echo ""
failed=0
for i in "${!NODES[@]}"; do
  printf "  %-${width}s  " "${NODES[$i]}"
  color_status "${RESULTS[$i]}"
  for st in ${STATUSES[$i]}; do printf " "; color_status "$st"; done
  echo ""
  [[ "${RESULTS[$i]}" == "PASS" ]] || failed=$((failed + 1))
done
echo ""
for i in "${!NODES[@]}"; do
  [[ -n "${DETAILS[$i]}" ]] && echo -e "  ${NODES[$i]}: ${DETAILS[$i]}"
done
echo ""
log "$(( ${#NODES[@]} - failed ))/${#NODES[@]} nodes passed. Report: ${REPORT#$SCRIPT_DIR/}"
[[ $failed -eq 0 ]] || exit 1
