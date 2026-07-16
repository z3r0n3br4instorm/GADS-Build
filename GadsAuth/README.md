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
import os, time, logging, json, requests as http_requests
from datetime import datetime, timedelta, timezone
from dotenv import load_dotenv
load_dotenv()
import jwt as pyjwt
from authlib.integrations.flask_client import OAuth
from flask import Flask, request, redirect, session, jsonify, make_response, Response
```

`load_dotenv()` runs before the config reads so the app works both as `python app.py` and `gunicorn app:app`. The `requests` library is aliased to `http_requests` to avoid shadowing Flask's own `request` proxy. `json` is used in `/auth/logout` to safely serialize the redirect URL into a JavaScript string literal.

## App creation

```python
app = Flask(__name__, static_folder=None)
```

`static_folder=None` disables Flask's built-in `/static/<path>` route. Without this, Flask intercepts all `/static/*` requests, tries to serve them from the container's (nonexistent) `static/` directory, and returns 404 — before the catch-all proxy route ever sees them. nginx now handles static files by proxying them directly to GADS hub.

## Configuration

All configuration comes from environment variables loaded by `dotenv`. There are no defaults for secrets — missing required vars cause a hard crash on startup, which is intentional (fail fast, clear message).

```python
FLASK_SECRET_KEY = os.environ["FLASK_SECRET_KEY"]
```

This key signs the Flask session cookie. If it changes, all existing sessions become invalid (users must re-login). The installer generates a 64-char hex string via `secrets.token_hex(32)`.

```python
GADS_ADMIN_EMAILS = {e.strip().lower() for e in os.environ.get("GADS_ADMIN_EMAILS", "").split(",") if e.strip()}
```

Builds a set of lowercase admin emails. Used by both JWT minting functions to decide whether a user gets `role: "admin"` with scopes `["user", "admin"]`, or just `role: "user"` with scopes `["user"]`.

```python
GADS_DEFAULT_SECRET = "tjsqEmu80WIMiyGJtP1WVdr3s81GIR3NttVgLj6mWUo="
```

GADS ships with a compiled-in default signing key. When a JWT arrives with `"iss": "gads"` and no `origin` claim, GADS falls back to this built-in secret for verification. This hardcoded value matches that compiled-in default. It's used only by `mint_gads_jwt` (the React-facing token), not by `mint_origin_jwt` (which uses the admin-configured `GADS_JWT_SECRET`).

## Session cookie configuration

```python
app.config.update(
    SESSION_COOKIE_NAME="gads_sso_session",
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_SAMESITE="Lax",
    PERMANENT_SESSION_LIFETIME=timedelta(hours=10),
)
```

| Setting | Value | Reason |
|---------|-------|--------|
| `SESSION_COOKIE_NAME` | `gads_sso_session` | Namespaced — won't collide with GADS's own session cookie if it uses one |
| `SESSION_COOKIE_HTTPONLY` | `True` | JavaScript can't read the cookie — XSS can't steal the session |
| `SESSION_COOKIE_SECURE` | `True` | Cookie only sent over HTTPS. Cloudflare provides TLS at the edge |
| `SESSION_COOKIE_SAMESITE` | `Lax` | Cookies are sent for top-level navigations from Auth0 (the OAuth redirect) but not for cross-site subrequests |
| `PERMANENT_SESSION_LIFETIME` | `10 hours` | Covers a full workday. When `session.permanent = True` (set after login), the cookie expires 10 hours from last request |

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

## JWT functions

### `mint_gads_jwt(email)`

```python
def mint_gads_jwt(email):
    now = datetime.now(timezone.utc)
    role = "admin" if email in GADS_ADMIN_EMAILS else GADS_DEFAULT_ROLE
    scopes = ["user", "admin"] if role == "admin" else ["user"]
    payload = {
        "iss": "gads", "sub": email,
        "exp": int((now + timedelta(hours=1)).timestamp()),
        "iat": int(now.timestamp()),
        "username": email, "role": role, "scope": scopes,
        "tenant": "5qnpXIGzC4Rqk_wb5DIYLKFBkfhLwtZ72ZUZlkQvO5A=",
    }
    return pyjwt.encode(payload, GADS_DEFAULT_SECRET, algorithm="HS256")
```

Creates the JWT that the **React frontend** stores in `localStorage.accessToken` and sends with API calls.

- **Issuer** is `"gads"` — GADS recognizes this and uses its built-in default secret for verification (since no `origin` claim is present to route to a custom key).
- **TTL is 1 hour** — longer than the origin JWT because the browser holds onto this. A new one is minted on each page load.
- **Tenant** is a hardcoded base64 string matching GADS's built-in default tenant.
- **Role** is `"admin"` if the user's email is in `GADS_ADMIN_EMAILS`, otherwise falls back to `GADS_DEFAULT_ROLE` (usually `"user"`).
- **Scopes** expand to `["user", "admin"]` for admins, `["user"]` otherwise.
- **Secret** is `GADS_DEFAULT_SECRET` — the compiled-in GADS default. This means these tokens work out of the box without configuring anything in GADS's "Add New Secret Key" form.

### `mint_origin_jwt(email)`

```python
def mint_origin_jwt(email):
    now = datetime.now(timezone.utc)
    role = "admin" if email in GADS_ADMIN_EMAILS else GADS_DEFAULT_ROLE
    payload = {
        "sub": email, "username": email, "role": role, "scope": [role],
        "tenant": GADS_TENANT_VALUE,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(seconds=GADS_TOKEN_TTL_SECONDS)).timestamp()),
        "iss": "gads-sso-proxy", "origin": GADS_ORIGIN,
        GADS_USER_CLAIM: email, GADS_TENANT_CLAIM: GADS_TENANT_VALUE,
    }
    return pyjwt.encode(payload, GADS_JWT_SECRET, algorithm="HS256")
```

Creates the JWT for **server-to-server** communication — nginx injects this as the `Authorization: Bearer` header on every upstream request to GADS hub.

- **Issuer** is `"gads-sso-proxy"` — identifies this proxy as the token source.
- **Origin claim** is critical: GADS's `ValidateJWT` reads `origin` from the payload to determine which secret key to verify against. Without it, GADS falls back to issuer-based lookup which may use the wrong key.
- **TTL is short** (default 300s / 5 min) — a fresh token is minted on every request via `/auth/verify`, so it only needs to survive one upstream round-trip.
- **Dynamic claim names** — `GADS_USER_CLAIM` and `GADS_TENANT_CLAIM` are configurable. The keys in the JWT payload must match exactly what was entered in GADS's "Add New Secret Key" form (User Identifier Claim / Tenant Identifier Claim fields).
- **Secret** is `GADS_JWT_SECRET` from `.env` — this must match the "Secret Key" value in GADS's form.

### Why two different JWTs?

| | GADS JWT | Origin JWT |
|---|---|---|
| **Consumer** | React browser app | GADS hub (server) |
| **Secret** | GADS compiled-in default | Admin-configured key |
| **Issuer** | `"gads"` | `"gads-sso-proxy"` |
| **Has origin?** | No | Yes |
| **TTL** | 1 hour | 5 minutes (configurable) |
| **Stored in** | `localStorage.accessToken` | Never stored; minted per-request |
| **Purpose** | API calls from the UI | Proxied page loads and API forwarding |

The separation exists because the GADS hub validates these differently. Origin-scoped JWTs (with an `origin` claim) route to the admin's custom secret key. Issuer-scoped JWTs (without `origin`) use the compiled-in default. This lets the proxy talk to GADS with a strong custom secret while the React app uses the zero-config default.

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
    return auth0.authorize_redirect(redirect_uri=REDIRECT_URI)
```

Called when nginx's `@force_login` redirects an unauthenticated user here, or when a user clicks "Login."

1. **Clears any stale session** — ensures no leftover data from a previous login attempt.
2. **Stores the redirect target** in the session — after Auth0 callback, the user will be sent back to the page they originally requested. For example, if someone bookmarks `/devices`, they'll land there after login, not at `/`.
3. **Redirects to Auth0** — `auth0.authorize_redirect()` builds the Auth0 `/authorize` URL with the correct `client_id`, `redirect_uri`, `scope`, `state` (CSRF token), and `nonce` (OIDC replay protection). Authlib handles all of this automatically.

### `GET /auth/callback`

```python
@app.route("/auth/callback")
def callback():
    token = auth0.authorize_access_token()
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

1. **`authorize_access_token()`** — authlib exchanges the authorization `code` for tokens (access token + id_token), validates the `state` parameter against what was stored in the session (CSRF protection), validates the `nonce` (replay protection), and fetches `userinfo` from Auth0's `/userinfo` endpoint. If `state` doesn't match (e.g., session lost due to restart, or cross-site request), it raises `MismatchingStateError`.
2. **Extracts email** — the user's verified email from Auth0 becomes their GADS identity. Lowercased for consistency with `GADS_ADMIN_EMAILS`.
3. **Creates the session** — `session.permanent = True` activates the 10-hour lifetime. Stores email, display name, and authentication timestamp.
4. **Redirects** — pops the stored redirect target (consuming it so it's not reused) and sends the user there. Defaults to `/`.

### `GET /auth/logout`

```python
@app.route("/auth/logout")
def logout():
    session.clear()
    return_to = REDIRECT_URI.rsplit("/auth/", 1)[0]
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

1. **Clears the Flask session** — removes `user_email`, `user_name`, `authenticated_at`. The session cookie is effectively invalidated.
2. **Builds the Auth0 logout URL** — Auth0's `/v2/logout` clears the Auth0 session and redirects back to the GADS root. `return_to` is extracted from `REDIRECT_URI` by stripping the `/auth/callback` suffix (e.g., `https://gads-lab-pi.assurecraft.com/auth/callback` becomes `https://gads-lab-pi.assurecraft.com`).
3. **Returns an HTML page, not a redirect** — the page calls `localStorage.clear()` (wiping the React JWT and any other client-side state) **before** redirecting to Auth0. A plain 302 redirect can't execute JavaScript, so the old approach left stale tokens in localStorage. `json.dumps()` safely serializes the URL for embedding in JavaScript.

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

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `FLASK_SECRET_KEY` | Yes | — | Session cookie signing key |
| `AUTH0_DOMAIN` | Yes | — | Auth0 tenant domain |
| `AUTH0_CLIENT_ID` | Yes | — | Auth0 application client ID |
| `AUTH0_CLIENT_SECRET` | Yes | — | Auth0 application client secret |
| `REDIRECT_URI` | Yes | — | Auth0 callback URL (must match Allowed Callback URLs) |
| `GADS_ORIGIN` | Yes | — | Origin claim value (matches GADS secret key form) |
| `GADS_JWT_SECRET` | Yes | — | Signing key for origin JWTs (matches GADS secret key form) |
| `POST_LOGIN_DEFAULT` | No | `/` | Where to redirect after login |
| `GADS_USER_CLAIM` | No | `username` | JWT claim name for user identifier |
| `GADS_TENANT_CLAIM` | No | `tenant` | JWT claim name for tenant identifier |
| `GADS_TENANT_VALUE` | No | `assurecraft` | Tenant value in origin JWTs |
| `GADS_TOKEN_TTL_SECONDS` | No | `300` | Origin JWT lifetime in seconds |
| `GADS_DEFAULT_ROLE` | No | `user` | Role assigned to non-admin users |
| `GADS_ADMIN_EMAILS` | No | — | Comma-separated admin emails |
| `GADS_PORT` | No | `10000` | GADS hub port |
| `NGINX_PORT` | No | `80` | nginx public port |

---

## Routes

### SSO Proxy (Flask, port 5050)

| Route | Method | Auth | Purpose |
|-------|--------|------|---------|
| `/auth/login` | GET | No | Clear session, redirect to Auth0 authorize |
| `/auth/callback` | GET | No | Exchange Auth0 code for tokens, create session |
| `/auth/logout` | GET | No | Clear localStorage + session, redirect to Auth0 logout |
| `/auth/verify` | GET | nginx only | Return 401 or 200 + `X-GADS-Auth-Token` header |
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

## Deployment

```bash
cd GadsAuth
cp .env.example .env
# Edit .env with your Auth0 and GADS configuration
docker compose build
docker compose up -d
```

Or via the installer:
```bash
./install.sh
```
