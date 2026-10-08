#!/usr/bin/env python3
"""Point a Cloudflare Tunnel hostname at a local port, without touching the node.

Works for remotely-managed tunnels (created in the Cloudflare dashboard and run
with `cloudflared ... --token`). The ingress rules for those live at Cloudflare,
so changing them here takes effect as soon as cloudflared is connected; if the
node is offline it picks up the new rules when it reconnects. Tunnels that use a
local config.yml can't be changed this way and are reported as such.

Usage:
  ./set-tunnel-port.py xg-lab-2.assurecraft.com                  # show current route
  ./set-tunnel-port.py xg-lab-2.assurecraft.com --port 80        # show the planned change
  ./set-tunnel-port.py xg-lab-2.assurecraft.com --port 80 --apply
  ./set-tunnel-port.py host1.example.com host2.example.com --port 80 --apply

Needs CLOUDFLARE_API_TOKEN in deploy.env (or the environment) with permissions:
  Account > Cloudflare Tunnel > Edit
  Zone > DNS > Read
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.cloudflare.com/client/v4"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TUNNEL_CNAME = re.compile(r"^([0-9a-f-]{36})\.cfargotunnel\.com\.?$", re.I)

GREEN, YELLOW, RED, NC = "\033[0;32m", "\033[1;33m", "\033[0;31m", "\033[0m"


class CloudflareError(Exception):
    pass


def load_token(env_file):
    token = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if not token and os.path.exists(env_file):
        for line in open(env_file):
            m = re.match(r"\s*CLOUDFLARE_API_TOKEN\s*=\s*(.*)$", line.rstrip("\n"))
            if m:
                token = m.group(1).strip().strip("\"'")
    if not token:
        sys.exit(f"{RED}[ERROR]{NC} CLOUDFLARE_API_TOKEN is not set (add it to {env_file} or the environment)")
    return token


def cf(token, method, path, body=None):
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        try:
            data = json.load(e)
        except ValueError:
            raise CloudflareError(f"{method} {path}: HTTP {e.code}")
    except urllib.error.URLError as e:
        raise CloudflareError(f"{method} {path}: {e.reason}")
    if not data.get("success"):
        msgs = "; ".join(f"{err.get('code')}: {err.get('message')}" for err in data.get("errors", []))
        raise CloudflareError(f"{method} {path}: {msgs or 'request failed'}")
    return data["result"]


def find_zone(token, hostname):
    """Walk up the hostname until a zone in this account matches."""
    parts = hostname.split(".")
    for i in range(len(parts) - 1):
        name = ".".join(parts[i:])
        zones = cf(token, "GET", f"/zones?name={name}")
        if zones:
            return zones[0]
    raise CloudflareError(f"no Cloudflare zone found for {hostname} (check the token's zone access)")


def find_tunnel_id(token, zone, hostname):
    records = cf(token, "GET", f"/zones/{zone['id']}/dns_records?name={hostname}")
    for rec in records:
        m = TUNNEL_CNAME.match(rec.get("content", ""))
        if rec.get("type") == "CNAME" and m:
            return m.group(1)
    kinds = ", ".join(f"{r['type']} {r['content']}" for r in records) or "no DNS record"
    raise CloudflareError(f"{hostname} is not routed to a tunnel ({kinds})")


def describe(rule):
    path = f" path={rule['path']}" if rule.get("path") else ""
    return f"{rule.get('service')}{path}"


def process(token, hostname, service, apply):
    zone = find_zone(token, hostname)
    account_id = zone["account"]["id"]
    tunnel_id = find_tunnel_id(token, zone, hostname)
    tunnel = cf(token, "GET", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}")
    conns = len(tunnel.get("connections") or [])
    print(f"  tunnel:  {tunnel.get('name')} ({tunnel_id})")
    print(f"  status:  {tunnel.get('status')} ({conns} connection{'s' if conns != 1 else ''})")

    if tunnel.get("config_src", "cloudflare" if tunnel.get("remote_config") else "local") != "cloudflare":
        raise CloudflareError(
            "tunnel is locally managed (config.yml on the node); its ingress can only be changed on the node"
        )

    cfg = cf(token, "GET", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations")
    config = cfg.get("config") or {}
    ingress = config.get("ingress") or []
    matches = [r for r in ingress if r.get("hostname") == hostname]
    for r in matches:
        print(f"  current: {hostname} -> {describe(r)}")
    if not matches:
        print(f"  current: {hostname} has no ingress rule (falls through to the catch-all)")

    if service is None:
        return "SHOWN"

    if matches and all(r.get("service") == service for r in matches):
        print(f"  {GREEN}already pointing at {service}{NC}")
        return "UNCHANGED"

    if matches:
        for r in matches:
            r["service"] = service
    else:
        # Catch-all (no hostname) must stay last
        pos = next((i for i, r in enumerate(ingress) if not r.get("hostname")), len(ingress))
        ingress.insert(pos, {"hostname": hostname, "service": service, "originRequest": {}})
        if not any(not r.get("hostname") for r in ingress):
            ingress.append({"service": "http_status:404"})
    config["ingress"] = ingress
    print(f"  new:     {hostname} -> {service}")

    if not apply:
        print(f"  {YELLOW}dry run, nothing changed (add --apply){NC}")
        return "PLANNED"

    cf(token, "PUT", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations", {"config": config})
    after = cf(token, "GET", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations")
    live = [r for r in (after.get("config") or {}).get("ingress", []) if r.get("hostname") == hostname]
    if not live or any(r.get("service") != service for r in live):
        raise CloudflareError("update was accepted but the saved config does not match")
    note = "" if conns else " (node offline; applies when cloudflared reconnects)"
    print(f"  {GREEN}updated{NC}{note}")
    return "UPDATED"


def main():
    p = argparse.ArgumentParser(description="Point Cloudflare Tunnel hostnames at a local port.")
    p.add_argument("hostnames", nargs="+", help="public hostname(s), e.g. xg-lab-2.assurecraft.com")
    g = p.add_mutually_exclusive_group()
    g.add_argument("--port", type=int, help="local port to route to (uses http://localhost:<port>)")
    g.add_argument("--service", help="full origin service, e.g. http://localhost:80")
    p.add_argument("--apply", action="store_true", help="save the change (default is a dry run)")
    p.add_argument("-e", "--env", default=os.path.join(SCRIPT_DIR, "deploy.env"), help="env file with CLOUDFLARE_API_TOKEN")
    args = p.parse_args()

    service = args.service or (f"http://localhost:{args.port}" if args.port else None)
    token = load_token(args.env)

    results = []
    for host in args.hostnames:
        host = host.strip().lower().rstrip(".")
        print(f"\n{host}")
        try:
            results.append((host, process(token, host, service, args.apply), ""))
        except CloudflareError as e:
            print(f"  {RED}FAIL{NC} {e}")
            results.append((host, "FAIL", str(e)))

    print("\nSummary")
    for host, status, err in results:
        color = RED if status == "FAIL" else GREEN
        print(f"  {color}{status:<9}{NC} {host}{'  (' + err + ')' if err else ''}")
    sys.exit(1 if any(s == "FAIL" for _, s, _ in results) else 0)


if __name__ == "__main__":
    main()
