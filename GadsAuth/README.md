# GADS SSO Proxy (GadsAuth)

Authenticates users against Auth0 and mints GADS-compatible JWTs. Sits between Cloudflare and the GADS hub, enforcing SSO on every request.

## Architecture

```
Browser → Cloudflare (HTTPS) → nginx:80 → GADS hub:10000
                                │            ↑
                                ▼            │ (auth_request JWT)
                           SSO Proxy:5050 ───┘
                                │
                                ▼
                             Auth0
```

- **nginx** — terminates TLS via Cloudflare, enforces auth via subrequest to SSO proxy, proxies to GADS hub
- **SSO Proxy (Flask)** — handles Auth0 OAuth2 flow, maintains sessions, mints JWTs
- **GADS Hub** — the GADS application (systemd service on the host)
- **MongoDB** — GADS data store (Docker container)

---

## Auth0 Setup (The Only Configurations Required)

To integrate GADS with Auth0, you only need to configure **one application** in the Auth0 Dashboard:

### 1. Create Application
- In **Auth0 Dashboard** → **Applications** → **Applications** → click **Create Application**.
- Name: `GADS` (or any preferred name).
- Application Type: **Regular Web Application**.

### 2. Application Settings
Navigate to the **Settings** tab and configure:

| Field | Value | Notes |
|-------|-------|-------|
| **Allowed Callback URLs** | `https://<domain>/auth/callback,`<br>`http://<lan-ip>/auth/callback,`<br>`http://localhost/auth/callback` | Comma-separated list. Include your Cloudflare domain, LAN IP, and localhost to authenticate from anywhere. |
| **Allowed Logout URLs** | `https://<domain>,`<br>`http://<lan-ip>,`<br>`http://localhost` | Comma-separated list matching your base URLs. |
| **Allowed Web Origins** | `https://<domain>,`<br>`http://<lan-ip>,`<br>`http://localhost` | Comma-separated list matching your base URLs. |

> **Example for a lab server:**
> - **Allowed Callback URLs:** `https://xg-lab-2.assurecraft.com/auth/callback, http://192.168.1.253/auth/callback, http://localhost/auth/callback`
> - **Allowed Logout URLs:** `https://xg-lab-2.assurecraft.com, http://192.168.1.253, http://localhost`
> - **Allowed Web Origins:** `https://xg-lab-2.assurecraft.com, http://192.168.1.253, http://localhost`

### 3. Copy Credentials to `.env`
Copy the following 3 values from the **Basic Information** section:
- **Domain** → `AUTH0_DOMAIN`
- **Client ID** → `AUTH0_CLIENT_ID`
- **Client Secret** → `AUTH0_CLIENT_SECRET`

> [!NOTE]
> **Nothing else is required in Auth0!**
> - You do **NOT** need custom Auth0 APIs, Actions, Rules, or Custom Audiences.
> - Default social connections (e.g. Google) or Database username/password work out of the box.

---

## Cloudflare Tunnel Configuration

If accessing GADS through a Cloudflare Zero Trust Tunnel:

1. **Point the tunnel service to port 80 (nginx), NOT port 10000:**
   ```yaml
   ingress:
     - hostname: xg-lab-2.assurecraft.com
       service: http://localhost:80
     - service: http_status:404
   ```
   > [!CAUTION]
   > Do **NOT** route Cloudflare Tunnel directly to `http://localhost:10000`. Port 10000 is GADS Hub directly, which completely bypasses the Nginx reverse proxy and SSO authentication!

2. **How header forwarding works:**
   - Cloudflare terminates HTTPS at the edge and forwards requests to local nginx on port 80.
   - Nginx forwards `Host`, `X-Forwarded-Host`, `X-Forwarded-Proto`, and `Cf-Visitor` headers to the SSO Proxy.
   - The SSO proxy dynamically detects whether incoming traffic is HTTPS or plain HTTP and constructs the exact callback URL.

---

## Zero-Configuration Features

The SSO Proxy provides built-in auto-detection and self-healing:

### 1. Dynamic Callback URL & Scheme Auto-Detection
- **`REDIRECT_URI` is optional**: Leave it blank in `.env`. The SSO proxy dynamically detects the scheme (`https` vs `http`) and host (`xg-lab-2.assurecraft.com`, `192.168.1.253`, or `localhost`) for every request.
- **Dynamic Cookie Security**: Automatically sets `SESSION_COOKIE_SECURE = True` for HTTPS requests (Cloudflare) and `SESSION_COOKIE_SECURE = False` for HTTP requests (LAN / localhost). This prevents session cookies from being dropped on plain HTTP, eliminating `MismatchingStateError` CSRF crashes.

### 2. Automatic MongoDB Secret Retrieval
- **`GADS_JWT_SECRET` and `GADS_DEFAULT_SECRET` are optional**:
  - The proxy connects directly to MongoDB (auto-discovering via `gads-mongodb` container, Docker host socket, or localhost).
  - Fetches the origin signing key and claims for `GADS_ORIGIN` (e.g. `sso.assurecraft.com`).
  - Fetches the bootstrap default signing key (`is_default: true`) and tenant.
  - Caches keys in memory for 60 seconds.
  - Manual database inspection (`mongosh`) and copy-pasting keys into `.env` is no longer needed.

---

## Files

| File | Purpose |
|------|---------|
| `app.py` | Flask SSO proxy application |
| `nginx-gads.conf` | nginx reverse proxy config (envsubst template) |
| `docker-compose.yml` | Docker Compose stack (proxy + nginx) |
| `Dockerfile` | Python container for the SSO proxy |
| `requirements.txt` | Python dependencies |
| `.env.example` | Environment variable template |

---

# Code Walkthrough (`app.py`)

## Imports and bootstrap

```python
import os, time, logging, json, base64, socket, requests as http_requests
from datetime import datetime, timedelta, timezone
from dotenv import load_dotenv
load_dotenv()
import jwt as pyjwt
import pymongo
from authlib.integrations.flask_client import OAuth
from flask import Flask, request, redirect, session, jsonify, make_response, Response
```

`load_dotenv()` runs before config reads. `pymongo` is imported for direct queries to MongoDB for GADS secret keys. `socket` is used to communicate directly with `/var/run/docker.sock` to discover the internal container IP of `gads-mongodb`.

## Configuration

Only 4 core variables are mandatory in `.env`: `FLASK_SECRET_KEY`, `AUTH0_DOMAIN`, `AUTH0_CLIENT_ID`, and `AUTH0_CLIENT_SECRET`.

All other variables (`REDIRECT_URI`, `GADS_JWT_SECRET`, `GADS_DEFAULT_SECRET`, `GADS_DEFAULT_TENANT`) have dynamic auto-detection or database lookup routines.

```python
FLASK_SECRET_KEY = os.environ["FLASK_SECRET_KEY"]
AUTH0_DOMAIN = os.environ["AUTH0_DOMAIN"]
AUTH0_CLIENT_ID = os.environ["AUTH0_CLIENT_ID"]
AUTH0_CLIENT_SECRET = os.environ["AUTH0_CLIENT_SECRET"]
REDIRECT_URI = os.environ.get("REDIRECT_URI", "").strip()
GADS_ORIGIN = os.environ.get("GADS_ORIGIN", "sso.assurecraft.com")
GADS_JWT_SECRET = os.environ.get("GADS_JWT_SECRET", "")
```

## Dynamic Scheme, Host & Redirect URI Detection

Instead of requiring a single hardcoded callback URL, the SSO proxy inspects each incoming request:

```python
def get_request_scheme():
    cf_visitor = request.headers.get("Cf-Visitor")
    if cf_visitor and '"https"' in cf_visitor:
        return "https"
    proto = request.headers.get("X-Forwarded-Proto")
    if proto:
        return proto.split(",")[0].strip()
    return request.scheme

def get_request_host():
    host = request.headers.get("X-Forwarded-Host") or request.headers.get("Host") or request.host
    return host.split(",")[0].strip()

def get_redirect_uri():
    if REDIRECT_URI:
        return REDIRECT_URI
    scheme = get_request_scheme()
    host = get_request_host()
    return f"{scheme}://{host}/auth/callback"
```

- When accessed through Cloudflare, `Cf-Visitor` or `X-Forwarded-Proto` reveals `https://`, generating `https://xg-lab-2.assurecraft.com/auth/callback`.
- When accessed locally on LAN, it generates `http://192.168.1.253/auth/callback`.
- When tested locally on the machine, it generates `http://localhost/auth/callback`.

## Dynamic Session Cookie Configuration

```python
@app.before_request
def adjust_session_cookie_security():
    """Dynamically adapt cookie security: Secure=True if over HTTPS (e.g. Cloudflare), False on HTTP (LAN/localhost)."""
    if os.environ.get("SESSION_COOKIE_SECURE") is None:
        app.config["SESSION_COOKIE_SECURE"] = (get_request_scheme() == "https")
```

| Setting | Value | Reason |
|---------|-------|--------|
| `SESSION_COOKIE_NAME` | `gads_sso_session` | Namespaced — won't collide with GADS's internal cookies |
| `SESSION_COOKIE_HTTPONLY` | `True` | JavaScript cannot read the cookie — XSS protection |
| `SESSION_COOKIE_SECURE` | **Dynamic** (`True` on HTTPS, `False` on HTTP) | Crucial fix: Browsers reject `Secure` cookies over plain HTTP (LAN `192.168.1.253`), which would cause session loss and `MismatchingStateError` CSRF crashes |
| `SESSION_COOKIE_SAMESITE` | `Lax` | Sent for top-level OAuth callback navigation from Auth0 |
| `PERMANENT_SESSION_LIFETIME` | `10 hours` | Session valid for 10 hours from last activity |

## Auth0 OAuth client setup

```python
oauth = OAuth(app)
auth0 = oauth.register(
    "auth0",
    client_id=AUTH0_CLIENT_ID,
    client_secret=AUTH0_CLIENT_SECRET,
    api_base_url=f"https://{AUTH0_DOMAIN}",
    access_token_url=f"https://{AUTH0_DOMAIN}/oauth/token",
    authorize_url=f"https://{AUTH0_DOMAIN}/authorize",
    server_metadata_url=f"https://{AUTH0_DOMAIN}/.well-known/openid-configuration",
    client_kwargs={"scope": "openid profile email"},
)
```

Registers Auth0 as an OAuth client via authlib. The `server_metadata_url` points to Auth0's OpenID Connect discovery document, so authlib auto-configures endpoints. The `scope` requests the user's email and profile info — `openid` is required for the OIDC `id_token`, `email` is needed because we use email as the GADS user identifier.

---

### Automatic MongoDB Secret Discovery & Caching

Instead of requiring manual database inspection and copying keys into `.env`, the SSO proxy resolves keys on the fly from MongoDB:

```python
def refresh_mongo_keys():
    """Fetch secret keys from MongoDB secret_keys collection (cached for 60s)."""
    # 1. Check in-memory cache (60s TTL)
    # 2. Query MongoDB 'secret_keys' collection:
    #    - Find origin_doc matching {"origin": GADS_ORIGIN, "disabled": {"$ne": True}}
    #    - Find default_doc matching {"is_default": True, "disabled": {"$ne": True}}
    # 3. Store keys, user claims, and tenant claims in cache
```

Candidate connection addresses are attempted in order:
1. `MONGO_URI` (if explicitly provided in `.env`)
2. `mongodb://gads-mongodb:27017` (Docker Compose network)
3. IP address discovered from Docker daemon via `/var/run/docker.sock`
4. `mongodb://localhost:27017` and `mongodb://host.docker.internal:27017`

### Helper Resolvers:
- **`get_origin_signing_info()`**: Returns `(secret, user_claim, tenant_claim, tenant_val)` prioritizing the active key in MongoDB for `GADS_ORIGIN`, falling back to `GADS_JWT_SECRET` in `.env`, or default key.
- **`get_default_signing_info()`**: Returns `(secret, tenant)` prioritizing the active default key in MongoDB (`is_default: true`), falling back to `GADS_DEFAULT_SECRET` in `.env`.

---

## JWT functions

### `mint_gads_jwt(email)`

```python
def mint_gads_jwt(email):
    now = datetime.now(timezone.utc)
    role = "admin" if email in GADS_ADMIN_EMAILS else GADS_DEFAULT_ROLE
    scopes = ["user", "admin"] if role == "admin" else ["user"]
    secret, tenant = get_default_signing_info()
    payload = {
        "iss": "gads", "sub": email,
        "exp": int((now + timedelta(hours=1)).timestamp()),
        "iat": int(now.timestamp()),
        "username": email, "role": role, "scope": scopes,
        "tenant": tenant,
    }
    return pyjwt.encode(payload, secret, algorithm="HS256")
```

Creates the JWT that the **React frontend** stores in `localStorage.accessToken` and sends with API calls.

- **Issuer** is `"gads"` — since no `origin` claim is present, GADS falls back to its auto-generated default key for verification.
- **TTL is 1 hour** — longer than the origin JWT because the browser holds onto this. A new one is minted on each page load.
- **Tenant** is dynamically fetched from MongoDB's default secret doc (or `GADS_DEFAULT_TENANT`).
- **Role** is `"admin"` if the user's email is in `GADS_ADMIN_EMAILS`, otherwise falls back to `GADS_DEFAULT_ROLE` (usually `"user"`).
- **Scopes** expand to `["user", "admin"]` for admins, `["user"]` otherwise.
- **Secret** is automatically retrieved from MongoDB (`is_default: true`).

### `mint_origin_jwt(email)`

```python
def mint_origin_jwt(email):
    now = datetime.now(timezone.utc)
    role = "admin" if email in GADS_ADMIN_EMAILS else GADS_DEFAULT_ROLE
    secret, user_claim, tenant_claim, tenant_val = get_origin_signing_info()
    payload = {
        "sub": email, "username": email, "role": role, "scope": [role],
        "tenant": tenant_val,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(seconds=GADS_TOKEN_TTL_SECONDS)).timestamp()),
        "iss": "gads-sso-proxy", "origin": GADS_ORIGIN,
        user_claim: email, tenant_claim: tenant_val,
    }
    return pyjwt.encode(payload, secret, algorithm="HS256")
```

Creates the JWT for **server-to-server** communication — nginx injects this as the `Authorization: Bearer` header on every upstream request to GADS hub.

- **Issuer** is `"gads-sso-proxy"` — identifies this proxy as the token source.
- **Origin claim** is critical: GADS's `ValidateJWT` reads `origin` from the payload to determine which secret key to verify against.
- **TTL is short** (default 300s / 5 min) — a fresh token is minted on every request via `/auth/verify`, surviving one upstream round-trip.
- **Dynamic claim names & secret** — resolved automatically from MongoDB (`secret_keys` collection for `origin: GADS_ORIGIN`), matching the key created in GADS UI.

### Why two different JWTs?

| | GADS JWT | Origin JWT |
|---|---|---|
| **Consumer** | React browser app | GADS hub (server) |
| **Secret** | Auto-retrieved from MongoDB (`is_default: true`) | Auto-retrieved from MongoDB (`origin: GADS_ORIGIN`) |
| **Issuer** | `"gads"` | `"gads-sso-proxy"` |
| **Has origin?** | No | Yes |
| **TTL** | 1 hour | 5 minutes (configurable) |
| **Stored in** | `localStorage.accessToken` | Never stored; minted per-request |
| **Purpose** | API calls from the UI | Proxied page loads and API forwarding |

---

## Where the default key comes from

`GADS_DEFAULT_SECRET` is auto-generated by GADS on first startup and stored in MongoDB.

When GADS hub starts, it initializes a `SecretCache` (`secretcache.go`). The cache calls `Refresh()`, which checks MongoDB's `secret_keys` collection for existing keys. If the collection is empty (fresh install):

```go
// secretcache.go lines 67-87
if len(secretKeys) == 0 {
    randomKey, err := generateRandomKey(32) // 32 bytes from crypto/rand
    defaultKey := &SecretKey{
        Origin:    "default",
        Key:       randomKey,               // base64-encoded random bytes
        IsDefault: true,
        UserIdentifierClaim: "username",
    }
    c.store.AddSecretKey(defaultKey, "system", "Auto-generated default key")
}
```

`generateRandomKey(32)` uses Go's `crypto/rand.Read()` — cryptographically secure random bytes, base64-encoded. **Every GADS installation gets a different key.**

### Automatic vs Manual Retrieval

- **Automatic (Default):** The SSO proxy now reads this key and origin keys directly from MongoDB at runtime. You do not need to do anything!
- **Manual Verification (Optional):** If you wish to inspect the key manually:
  ```bash
  docker exec gads-mongodb mongosh --quiet --eval \
    "db.getSiblingDB('gads').secret_keys.findOne({is_default: true}).key"
  ```

---

## `proxy_to_gads(path)`

```python
def proxy_to_gads(path):
    email = session.get("user_email")
    if not email:
        return None
    token = mint_origin_jwt(email)
    gads_url = f"http://host.docker.internal:{GADS_PORT}/{path}"
    if request.query_string:
        gads_url += f"?{request.query_string.decode()}"
    headers = {"Authorization": f"Bearer {token}", "Host": request.host}
    if request.method == "POST":
        resp = http_requests.post(gads_url, headers=headers, data=request.get_data(), timeout=30)
    else:
        resp = http_requests.get(gads_url, headers=headers, timeout=30)
    ct = resp.headers.get("Content-Type", "text/html")
    body = resp.content
    if "text/html" in ct and b"</head>" in body:
        gadstoken = mint_gads_jwt(email)
        script = f'<script>localStorage.setItem("accessToken","{gadstoken}");localStorage.setItem("user","{email}");</script>'.encode()
        body = body.replace(b"</head>", script + b"</head>")
    return Response(body, status=resp.status_code, content_type=ct)
```

Forwards an incoming request to GADS hub and returns the response. Used by the `catch_all` route.

Step by step:
1. **Guard**: returns `None` if no session email (caller must check this).
2. **Mints an origin JWT** for the current user — GADS hub validates this to authorize the request.
3. **Builds the GADS URL** using `host.docker.internal` (resolves to the Docker host gateway, reaching GADS on the Pi's host network). Appends any query string from the original request.
4. **Forwards the request** with the JWT as a Bearer token and the original `Host` header (so GADS knows which domain it's serving).
5. **Injects the React JWT** into HTML responses: replaces `</head>` with a `<script>` that writes the GADS JWT and user email to `localStorage`. The key is `accessToken` (camelCase) — matching what the GADS React bundle reads. The script always overwrites (no `if` check for existing token) to prevent stale-token issues.
6. **Returns the response** with the original status code and content type.

When the nginx config routes requests directly to GADS hub (current setup), this function is only invoked for requests that explicitly hit the catch-all route — typically only `/` when accessed directly through the proxy rather than through nginx.

---

## Route handlers

### `GET /auth/login`

```python
@app.route("/auth/login")
def login():
    session.clear()
    session["post_login_redirect"] = request.args.get("redirect", POST_LOGIN_DEFAULT)
    redirect_uri = get_redirect_uri()
    log.info("Initiating Auth0 login redirect with callback: %s", redirect_uri)
    return auth0.authorize_redirect(redirect_uri=redirect_uri)
```

Called when nginx's `@force_login` redirects an unauthenticated user here, or when a user clicks "Login."

1. **Clears any stale session** — ensures no leftover data from a previous login attempt.
2. **Stores the redirect target** in the session — after Auth0 callback, the user will be sent back to the page they originally requested. For example, if someone bookmarks `/devices`, they'll land there after login, not at `/`.
3. **Dynamically resolves `redirect_uri`** — using `get_redirect_uri()`, matches the scheme (`https` or `http`) and host header of the incoming request.
4. **Redirects to Auth0** — `auth0.authorize_redirect(redirect_uri=redirect_uri)` builds the Auth0 `/authorize` URL with the correct `client_id`, dynamic `redirect_uri`, `scope`, `state` (CSRF token), and `nonce` (OIDC replay protection).

### `GET /auth/callback`

```python
@app.route("/auth/callback")
def callback():
    try:
        token = auth0.authorize_access_token()
    except Exception as e:
        log.error("Auth0 token exchange failed: %s", e, exc_info=True)
        return jsonify({"error": "authentication_failed", "details": str(e)}), 400

    userinfo = token.get("userinfo")
    if not userinfo:
        return jsonify({"error": "no_userinfo"}), 400
    email = (userinfo.get("email") or "").lower()
    if not email:
        return jsonify({"error": "no_email"}), 400
    session.permanent = True
    session["user_email"] = email
    session["user_name"] = userinfo.get("name", email)
    session["authenticated_at"] = int(time.time())
    dest = session.pop("post_login_redirect", POST_LOGIN_DEFAULT)
    return redirect(dest)
```

The URL Auth0 redirects to after the user authenticates. The query string contains `?code=...&state=...`.

1. **`authorize_access_token()`** — authlib exchanges the authorization `code` for tokens (access token + id_token) using the redirect URI saved in the session's state. It validates the `state` parameter against what was stored in the session (CSRF protection), validates the `nonce` (replay protection), and fetches `userinfo`.
2. **Extracts email** — the user's verified email from Auth0 becomes their GADS identity. Lowercased for consistency with `GADS_ADMIN_EMAILS`.
3. **Creates the session** — `session.permanent = True` activates the 10-hour lifetime. Stores email, display name, and authentication timestamp.
4. **Redirects** — pops the stored redirect target (consuming it so it's not reused) and sends the user there. Defaults to `/`.

### `GET /auth/logout`

```python
@app.route("/auth/logout")
def logout():
    session.clear()
    redirect_uri = get_redirect_uri()
    return_to = redirect_uri.rsplit("/auth/", 1)[0]
    auth0_logout = f"https://{AUTH0_DOMAIN}/v2/logout?client_id={AUTH0_CLIENT_ID}&returnTo={return_to}"
    html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"></head><body>
<script>
localStorage.clear();
window.location.href = {json.dumps(auth0_logout)};
</script>
<p>Logging out...</p>
</body></html>"""
    return html, 200, {"Content-Type": "text/html; charset=utf-8"}
```

1. **Clears the Flask session** — removes `user_email`, `user_name`, `authenticated_at`.
2. **Builds the Auth0 logout URL** — extracts the base origin dynamically via `redirect_uri.rsplit("/auth/", 1)[0]`. Auth0 clears the session and returns the user to the dynamic origin (e.g. `https://xg-lab-2.assurecraft.com` or `http://192.168.1.253`).
3. **Wipes localStorage before redirecting** — `localStorage.clear()` removes the client-side JWT before browser redirects to Auth0 logout.

### `GET /auth/verify`

```python
@app.route("/auth/verify")
def verify():
    email = session.get("user_email")
    if not email:
        return jsonify({"error": "not_authenticated"}), 401
    token = mint_origin_jwt(email)
    resp = make_response("", 200)
    resp.headers["X-GADS-Auth-Token"] = token
    return resp
```

Called by nginx as an **internal subrequest** (`auth_request /auth/verify`) on every protected request. This is the enforcement point.

- **No session** → returns 401 JSON → nginx's `error_page 401 = @force_login` fires → user is redirected to `/auth/login`.
- **Valid session** → mints a fresh origin JWT, returns it in `X-GADS-Auth-Token` header → nginx reads it via `auth_request_set $gads_token $upstream_http_x_gads_auth_token` and injects it as `Authorization: Bearer <token>` on the upstream request to GADS.

This endpoint is `internal` in the nginx config, meaning it cannot be called directly from outside — nginx only invokes it via `auth_request`.

### `POST /authenticate`

```python
@app.route("/authenticate", methods=["POST"])
def authenticate():
    email = session.get("user_email")
    if not email:
        resp = http_requests.post(f"http://host.docker.internal:{GADS_PORT}/authenticate",
                                   headers={"Host": request.host},
                                   data=request.get_data(), timeout=30)
        return Response(resp.content, status=resp.status_code, content_type=resp.headers.get("Content-Type", "text/html"))
    gadstoken = mint_gads_jwt(email)
    role = "admin" if email in GADS_ADMIN_EMAILS else GADS_DEFAULT_ROLE
    return jsonify({
        "success": True, "message": "",
        "result": {
            "accessToken": gadstoken, "token_type": "Bearer",
            "expires_in": 3600, "username": email, "role": role,
        }
    })
```

Intercepts GADS's native login endpoint. The React app calls `POST /authenticate` to get a JWT. This route is explicitly proxied to the SSO proxy by nginx (`location = /authenticate`).

- **SSO-authenticated user** (has session cookie) → skips GADS entirely, returns a GADS JWT directly in the format GADS expects. The React app stores it as `localStorage.accessToken`.
- **Unauthenticated user** → forwards the request through to GADS hub, which handles it with its native auth flow (username/password or whatever GADS supports).

This is how the React app acquires a JWT when nginx proxies directly to GADS hub (bypassing the HTML injection path). On the first page load after SSO login, the React app calls this endpoint, the proxy sees the session cookie, and returns a valid token.

### `GET /healthz`

```python
@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"}), 200
```

Simple health check — no auth required. nginx routes this directly to the proxy. Used by monitoring tools and Docker health checks.

### `GET /auth/legacy`

```python
@app.route("/auth/legacy")
def legacy_login():
    session.clear()
    resp = make_response(redirect("/"))
    resp.set_cookie("gads_legacy", "1", max_age=3600, httponly=True, secure=True, samesite="Lax")
    return resp
```

Sets a `gads_legacy` cookie for non-SSO (direct) GADS access. When the catch-all route sees this cookie and no valid SSO session, it forwards requests to GADS hub without auth — allowing GADS's native login to handle authentication.

### Catch-all: `/` and `/<path:path>`

```python
@app.route("/", defaults={"path": ""})
@app.route("/<path:path>")
def catch_all(path):
    if request.cookies.get("gads_legacy") == "1" and not session.get("user_email"):
        gads_url = f"http://host.docker.internal:{GADS_PORT}/{path}"
        if request.query_string:
            gads_url += f"?{request.query_string.decode()}"
        resp = http_requests.get(gads_url, headers={"Host": request.host}, timeout=30)
        return Response(resp.content, status=resp.status_code, content_type=resp.headers.get("Content-Type", "text/html"))
    email = session.get("user_email")
    if not email:
        if path == "" or path in ("health", "favicon.ico") or path.startswith("admin/") or path.startswith("api/"):
            return jsonify({"error": "not_authenticated"}), 401
        return redirect(f"/auth/login?redirect=/{path}")
    return proxy_to_gads(path)
```

Matches any URL not caught by a more specific route. With the current nginx config (which routes protected paths directly to GADS hub), this catch-all is mainly a **fallback for direct proxy access**. However, it also handles these cases:

1. **Legacy access** — if the `gads_legacy` cookie is set and there's no SSO session, forwards the request to GADS hub without auth (GADS's native login handles it).

2. **Unauthenticated user** — for page paths (not API paths), redirects to `/auth/login` with the original path as the `redirect` parameter. For API paths (`api/`, `admin/`) and special paths (`health`, `favicon.ico`), returns a 401 JSON response. This distinction prevents API calls from getting HTML redirect responses.

3. **Authenticated user** — calls `proxy_to_gads(path)` which forwards the request to GADS hub with an origin JWT and injects the React JWT into HTML responses.

---

## Authentication Flow

### Login

1. User visits any protected URL → nginx issues `auth_request` to `/auth/verify`
2. No valid session → 401 → nginx `@force_login` redirects to `/auth/login?redirect=<original_url>`
3. `/auth/login` clears any stale session, stores the redirect target, redirects to Auth0 `/authorize`
4. User authenticates with Auth0 (Google, etc.)
5. Auth0 redirects to `/auth/callback?code=...&state=...`
6. Callback exchanges the code for tokens, extracts email from `userinfo`, creates session
7. Redirects user to the stored `post_login_redirect` URL (or `/`)
8. nginx auth_request now passes → proxies to GADS hub with bearer JWT

### Authenticated Requests

1. Every request to a non-auth path triggers `auth_request /auth/verify`
2. SSO proxy checks the session cookie (`gads_sso_session`)
3. If valid: mints a short-lived **origin JWT** (signed with `GADS_JWT_SECRET`), returns it in `X-GADS-Auth-Token` header
4. nginx injects that JWT as `Authorization: Bearer <token>` on the upstream request to GADS
5. GADS validates the JWT against its configured secret key for the origin

### React App Token Acquisition

1. GADS hub returns the React SPA HTML shell
2. React boots, checks localStorage for `accessToken` — not found on first visit
3. React calls `POST /authenticate` (routed to SSO proxy by nginx)
4. SSO proxy checks session → if valid, returns a **GADS JWT** (`iss: "gads"`)
5. React stores it as `localStorage.accessToken` and uses it for all API calls

### Logout

1. `/auth/logout` returns an HTML page that calls `localStorage.clear()` to wipe the React JWT
2. Then redirects to Auth0 `/v2/logout` which clears the Auth0 session
3. Auth0 redirects back to the GADS root

---

## Environment Variables

### Required Variables (Only 4 needed!)

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `FLASK_SECRET_KEY` | **Yes** | — | Flask session cookie signing key (`secrets.token_hex(32)`) |
| `AUTH0_DOMAIN` | **Yes** | — | Auth0 tenant domain (from Auth0 Application settings) |
| `AUTH0_CLIENT_ID` | **Yes** | — | Auth0 application Client ID |
| `AUTH0_CLIENT_SECRET` | **Yes** | — | Auth0 application Client Secret |

### Optional / Auto-Detected Variables

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `REDIRECT_URI` | No | Auto-detected | Leave empty to automatically detect callback URL based on incoming request scheme & host (`https://xg-lab-2.assurecraft.com/auth/callback`, `http://192.168.1.253/auth/callback`, `http://localhost/auth/callback`) |
| `GADS_ORIGIN` | No | `sso.assurecraft.com` | Origin identifier claim used to query MongoDB and mint origin JWTs |
| `GADS_JWT_SECRET` | No | Auto-retrieved | Secret key for `GADS_ORIGIN`. Auto-retrieved from MongoDB `secret_keys` collection if left blank |
| `GADS_DEFAULT_SECRET` | No | Auto-retrieved | GADS fallback signing key (`is_default: true`). Auto-retrieved from MongoDB if left blank |
| `GADS_DEFAULT_TENANT` | No | Auto-retrieved | Tenant identifier. Auto-retrieved from MongoDB if left blank |
| `POST_LOGIN_DEFAULT` | No | `/` | Where to redirect user after successful login |
| `GADS_USER_CLAIM` | No | `username` | JWT claim name for user identifier (overridden if found in MongoDB) |
| `GADS_TENANT_CLAIM` | No | `tenant` | JWT claim name for tenant identifier (overridden if found in MongoDB) |
| `GADS_TENANT_VALUE` | No | `assurecraft` | Tenant value in origin JWTs |
| `GADS_TOKEN_TTL_SECONDS` | No | `300` | Origin JWT lifetime in seconds |
| `GADS_DEFAULT_ROLE` | No | `user` | Role assigned to non-admin users |
| `GADS_ADMIN_EMAILS` | No | — | Comma-separated admin emails (assigned `admin` role and scopes) |
| `GADS_PORT` | No | `10000` | GADS hub port on the host |
| `NGINX_PORT` | No | `80` | nginx public port (service target for Cloudflare Tunnel) |
| `MONGO_URI` | No | Auto-discovered | MongoDB connection URI (tries `gads-mongodb:27017`, Docker socket discovery, `localhost:27017`) |
| `MONGO_DB_NAME` | No | `gads` | GADS database name in MongoDB |
| `SESSION_COOKIE_SECURE` | No | Auto-detected | Overrides cookie security. When omitted, dynamically adapts to `True` for HTTPS (Cloudflare) and `False` for plain HTTP (LAN) |

---

## Routes

### SSO Proxy (Flask, port 5050)

| Route | Method | Auth | Purpose |
|-------|--------|------|---------|
| `/auth/login` | GET | No | Clear session, dynamically generate redirect URI, redirect to Auth0 authorize |
| `/auth/callback` | GET | No | Exchange Auth0 code for tokens with dynamic redirect URI, create session |
| `/auth/logout` | GET | No | Clear localStorage + session, redirect to Auth0 logout |
| `/auth/verify` | GET | nginx only | Return 401 or 200 + `X-GADS-Auth-Token` header (minted via MongoDB secret) |
| `/auth/legacy` | GET | No | Set legacy cookie for non-SSO access |
| `/authenticate` | POST | Session | Return GADS JWT for SSO-authenticated users; forward to GADS otherwise |
| `/healthz` | GET | No | Health check |
| `/` `/<path>` | Any | Session | Catch-all: proxy to GADS hub with JWT injection |

### nginx (port 80)

| Location | Target | Auth Required |
|----------|--------|---------------|
| `= /auth/verify` | SSO Proxy (internal only) | — |
| `/auth/` | SSO Proxy | No |
| `= /healthz` | SSO Proxy | No |
| `= /authenticate` | SSO Proxy | No |
| `/` (everything else) | GADS Hub | Yes — `auth_request /auth/verify` |

Unauthenticated users hitting any protected route get caught by `error_page 401 = @force_login`, which issues a 302 redirect to `/auth/login?redirect=$request_uri`.

---

## Quick Deployment

```bash
cd GadsAuth
cp .env.example .env

# Edit .env and enter only the 4 required values:
# 1. FLASK_SECRET_KEY (generate via python3 -c "import secrets; print(secrets.token_hex(32))")
# 2. AUTH0_DOMAIN
# 3. AUTH0_CLIENT_ID
# 4. AUTH0_CLIENT_SECRET
# (Leave REDIRECT_URI, GADS_JWT_SECRET, and GADS_DEFAULT_SECRET empty for auto-detection!)

# Start or rebuild the SSO stack
docker compose up -d --build
```
