import os, time, logging, json, base64, socket, requests as http_requests
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode
from dotenv import load_dotenv
load_dotenv()
import jwt as pyjwt
import pymongo
from authlib.integrations.flask_client import OAuth
from flask import Flask, request, redirect, session, jsonify, make_response, Response

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("gads-sso-proxy")
app = Flask(__name__, static_folder=None)

FLASK_SECRET_KEY = os.environ["FLASK_SECRET_KEY"]
AUTH0_DOMAIN = os.environ["AUTH0_DOMAIN"]
AUTH0_CLIENT_ID = os.environ["AUTH0_CLIENT_ID"]
AUTH0_CLIENT_SECRET = os.environ["AUTH0_CLIENT_SECRET"]
REDIRECT_URI = os.environ.get("REDIRECT_URI", "").strip()
POST_LOGIN_DEFAULT = os.environ.get("POST_LOGIN_DEFAULT", "/")
GADS_ORIGIN = os.environ.get("GADS_ORIGIN", "sso.assurecraft.com")
GADS_JWT_SECRET = os.environ.get("GADS_JWT_SECRET", "")
GADS_USER_CLAIM = os.environ.get("GADS_USER_CLAIM", "username")
GADS_TENANT_CLAIM = os.environ.get("GADS_TENANT_CLAIM", "tenant")
GADS_TENANT_VALUE = os.environ.get("GADS_TENANT_VALUE", "assurecraft")
GADS_TOKEN_TTL_SECONDS = int(os.environ.get("GADS_TOKEN_TTL_SECONDS", "300"))
GADS_DEFAULT_ROLE = os.environ.get("GADS_DEFAULT_ROLE", "user")
GADS_ADMIN_EMAILS = {e.strip().lower() for e in os.environ.get("GADS_ADMIN_EMAILS", "").split(",") if e.strip()}
GADS_PORT = os.environ.get("GADS_PORT", "10000")
GADS_DEFAULT_SECRET = os.environ.get("GADS_DEFAULT_SECRET", "")
GADS_DEFAULT_TENANT = os.environ.get("GADS_DEFAULT_TENANT", "")
MONGO_URI = os.environ.get("MONGO_URI")
MONGO_DB_NAME = os.environ.get("MONGO_DB_NAME", "gads")

def get_request_scheme():
    """Detect whether incoming request is HTTPS (Cloudflare / TLS termination) or HTTP."""
    cf_visitor = request.headers.get("Cf-Visitor")
    if cf_visitor and '"https"' in cf_visitor:
        return "https"
    proto = request.headers.get("X-Forwarded-Proto")
    if proto:
        return proto.split(",")[0].strip()
    return request.scheme

def get_request_host():
    """Detect incoming Host header (from Cloudflare, LAN IP, or localhost)."""
    host = request.headers.get("X-Forwarded-Host") or request.headers.get("Host") or request.host
    return host.split(",")[0].strip()

def get_redirect_uri():
    """Return explicit REDIRECT_URI if configured in .env, otherwise dynamically auto-detect."""
    if REDIRECT_URI:
        return REDIRECT_URI
    scheme = get_request_scheme()
    host = get_request_host()
    return f"{scheme}://{host}/auth/callback"

def get_auth0_logout_url():
    """Auth0 logout URL that returns the browser to this site's origin (must be in Auth0 Allowed Logout URLs)."""
    return_to = get_redirect_uri().rsplit("/auth/", 1)[0]
    query = urlencode({"client_id": AUTH0_CLIENT_ID, "returnTo": return_to})
    return f"https://{AUTH0_DOMAIN}/v2/logout?{query}"

# Secure cookies only over HTTPS, or when explicitly requested via env var
cookie_secure_env = os.environ.get("SESSION_COOKIE_SECURE")
if cookie_secure_env is not None:
    SESSION_COOKIE_SECURE = cookie_secure_env.lower() in ("true", "1", "yes")
else:
    SESSION_COOKIE_SECURE = REDIRECT_URI.startswith("https://") if REDIRECT_URI else False

app.secret_key = FLASK_SECRET_KEY
app.config.update(
    SESSION_COOKIE_NAME="gads_sso_session",
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=SESSION_COOKIE_SECURE,
    SESSION_COOKIE_SAMESITE="Lax",
    PERMANENT_SESSION_LIFETIME=timedelta(hours=10),
)

@app.before_request
def adjust_session_cookie_security():
    """Dynamically adapt cookie security: Secure=True if over HTTPS (e.g. Cloudflare), False on HTTP (LAN/localhost)."""
    if os.environ.get("SESSION_COOKIE_SECURE") is None:
        app.config["SESSION_COOKIE_SECURE"] = (get_request_scheme() == "https")

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

# --- MongoDB secret retrieval & caching ---
_mongo_client = None
_key_cache = {}
_key_cache_time = 0

def decode_http_body(raw_bytes):
    if b"\r\n\r\n" not in raw_bytes:
        return 0, b""
    head, body = raw_bytes.split(b"\r\n\r\n", 1)
    status = int(head.split(b"\r\n")[0].split(b" ")[1])
    if b"chunked" in head.lower():
        result = b""
        while body:
            line_end = body.find(b"\r\n")
            if line_end == -1:
                break
            chunk_len_str = body[:line_end].strip().split(b";")[0]
            if not chunk_len_str:
                body = body[line_end + 2:]
                continue
            try:
                chunk_len = int(chunk_len_str, 16)
            except ValueError:
                break
            if chunk_len == 0:
                break
            start = line_end + 2
            end = start + chunk_len
            result += body[start:end]
            body = body[end + 2:]
        return status, result
    return status, body

def discover_mongo_ips_from_docker(container_name="gads-mongodb"):
    """Discover MongoDB container IPs via local docker socket if mounted."""
    sock_path = "/var/run/docker.sock"
    if not os.path.exists(sock_path):
        return []
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(sock_path)
        req = (
            f"GET /containers/{container_name}/json HTTP/1.1\r\n"
            f"Host: localhost\r\n"
            f"Connection: close\r\n\r\n"
        ).encode("latin1")
        s.sendall(req)
        chunks = []
        while True:
            data = s.recv(4096)
            if not data:
                break
            chunks.append(data)
        s.close()
        status, body = decode_http_body(b"".join(chunks))
        if status == 200 and body:
            info = json.loads(body.decode("utf-8"))
            networks = info.get("NetworkSettings", {}).get("Networks", {})
            return [cfg.get("IPAddress") for cfg in networks.values() if cfg.get("IPAddress")]
    except Exception as e:
        log.debug("Docker socket discovery failed: %s", e)
    return []

def get_mongo_db():
    """Connect to MongoDB using candidate hostnames/URIs."""
    global _mongo_client
    if _mongo_client is not None:
        try:
            _mongo_client.admin.command("ping")
            return _mongo_client[MONGO_DB_NAME]
        except Exception:
            _mongo_client = None

    uris = []
    if MONGO_URI:
        uris.append(MONGO_URI)
    uris.append(f"mongodb://{os.environ.get('MONGO_HOST', 'gads-mongodb')}:{os.environ.get('MONGO_PORT', '27017')}")
    for ip in discover_mongo_ips_from_docker():
        uris.append(f"mongodb://{ip}:{os.environ.get('MONGO_PORT', '27017')}")
    uris.extend([
        "mongodb://localhost:27017",
        "mongodb://host.docker.internal:27017",
        "mongodb://127.0.0.1:27017",
    ])

    for uri in uris:
        try:
            client = pymongo.MongoClient(uri, serverSelectionTimeoutMS=1500)
            client.admin.command("ping")
            log.info("Connected to MongoDB at %s", uri)
            _mongo_client = client
            return client[MONGO_DB_NAME]
        except Exception as e:
            log.debug("MongoDB connection attempt to %s failed: %s", uri, e)
            continue
    log.warning("Could not connect to MongoDB on any known candidate URI.")
    return None

def refresh_mongo_keys():
    """Fetch secret keys and default workspace tenant from MongoDB (cached for 60s)."""
    global _key_cache, _key_cache_time
    now = time.time()
    if _key_cache and (now - _key_cache_time < 60):
        return _key_cache

    db = get_mongo_db()
    if db is None:
        return _key_cache

    try:
        keys_col = db["secret_keys"]
        origin_doc = keys_col.find_one({"origin": GADS_ORIGIN, "disabled": {"$ne": True}})
        default_doc = keys_col.find_one({"is_default": True, "disabled": {"$ne": True}})

        cache = {}
        if origin_doc:
            cache["origin_secret"] = origin_doc.get("key")
            cache["user_claim"] = origin_doc.get("user_identifier_claim")
            cache["tenant_claim"] = origin_doc.get("tenant_identifier_claim")
            log.info("Loaded secret key for origin '%s' from MongoDB", GADS_ORIGIN)
        else:
            log.warning("No active secret key found in MongoDB for origin '%s'", GADS_ORIGIN)

        if default_doc:
            cache["default_secret"] = default_doc.get("key")
            log.info("Loaded default secret key from MongoDB")

        # Dynamically load default tenant from workspaces collection
        ws_col = db["workspaces"]
        default_ws = ws_col.find_one({"is_default": True}) or ws_col.find_one()
        if default_ws and default_ws.get("tenant"):
            cache["default_tenant"] = default_ws["tenant"]
            log.info("Loaded default workspace tenant from MongoDB: %s", default_ws["tenant"])

        _key_cache = cache
        _key_cache_time = now
        return _key_cache
    except Exception as e:
        log.error("Failed to query secret keys/tenant from MongoDB: %s", e)
        return _key_cache

def get_origin_signing_info():
    """Resolve origin signing secret and claims, prioritizing MongoDB default with fallback."""
    keys = refresh_mongo_keys()
    secret = (
        keys.get("default_secret")
        or (GADS_DEFAULT_SECRET if GADS_DEFAULT_SECRET else None)
        or keys.get("origin_secret")
        or (GADS_JWT_SECRET if GADS_JWT_SECRET else None)
        or "tjsqEmu80WIMiyGJtP1WVdr3s81GIR3NttVgLj6mWUo="
    )
    user_claim = keys.get("user_claim") or GADS_USER_CLAIM
    tenant_claim = keys.get("tenant_claim") or GADS_TENANT_CLAIM
    tenant_val = (
        keys.get("default_tenant")
        or (GADS_DEFAULT_TENANT if GADS_DEFAULT_TENANT else None)
        or GADS_TENANT_VALUE
    )
    return secret, user_claim, tenant_claim, tenant_val

def get_default_signing_info():
    """Resolve default signing secret and tenant, prioritizing MongoDB with env fallback."""
    keys = refresh_mongo_keys()
    secret = (
        keys.get("default_secret")
        or (GADS_DEFAULT_SECRET if GADS_DEFAULT_SECRET else None)
        or "tjsqEmu80WIMiyGJtP1WVdr3s81GIR3NttVgLj6mWUo="
    )
    tenant = (
        keys.get("default_tenant")
        or (GADS_DEFAULT_TENANT if GADS_DEFAULT_TENANT else None)
        or "5qnpXIGzC4Rqk_wb5DIYLKFBkfhLwtZ72ZUZlkQvO5A="
    )
    return secret, tenant

def mint_gads_jwt(email):
    """Mint a GADS-compatible JWT (for the React frontend to store and for proxying)."""
    now = datetime.now(timezone.utc)
    role = "admin" if email in GADS_ADMIN_EMAILS else GADS_DEFAULT_ROLE
    scopes = ["user", "admin"] if role == "admin" else ["user"]
    secret, tenant = get_default_signing_info()
    payload = {
        "iss": "gads", "sub": email,
        "exp": int((now + timedelta(hours=12)).timestamp()),
        "iat": int(now.timestamp()),
        "username": email, "role": role, "scope": scopes,
        "tenant": tenant,
    }
    return pyjwt.encode(payload, secret, algorithm="HS256")

def mint_origin_jwt(email):
    """Mint a JWT for GADS requests."""
    return mint_gads_jwt(email)

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
        role = ensure_gads_user(email)
        secret, tenant = get_default_signing_info()
        tenant_str = tenant or ""
        script = f'<script>try{{localStorage.setItem("accessToken","{gadstoken}");localStorage.setItem("username","{email}");localStorage.setItem("userRole","{role}");if("{tenant_str}")localStorage.setItem("tenant","{tenant_str}");}}catch(e){{}}</script>'.encode()
        body = body.replace(b"</head>", script + b"</head>")
    return Response(body, status=resp.status_code, content_type=ct)

# --- Auth routes ---

def ensure_gads_user(email):
    """Ensure that the authenticated user exists in MongoDB 'users' collection."""
    if not email:
        return GADS_DEFAULT_ROLE
    db = get_mongo_db()
    role = "admin" if email in GADS_ADMIN_EMAILS else GADS_DEFAULT_ROLE
    if db is None:
        log.warning("Cannot ensure GADS user in MongoDB: database connection unavailable")
        return role

    try:
        user_col = db["users"]
        user = user_col.find_one({"username": email})

        # Retrieve default workspace ID if user is not admin
        workspace_ids = None
        if role != "admin":
            workspaces_col = db["workspaces"]
            default_ws = workspaces_col.find_one({"is_default": True})
            if not default_ws:
                default_ws = workspaces_col.find_one()
            if default_ws:
                workspace_ids = [str(default_ws["_id"])]
            else:
                workspace_ids = []

        if user is None:
            user_doc = {
                "username": email,
                "password": "",  # Empty password for SSO users
                "role": role,
                "workspace_ids": workspace_ids,
            }
            user_col.insert_one(user_doc)
            log.info("Auto-created GADS user in MongoDB: '%s' (role: %s, workspaces: %s)", email, role, workspace_ids)
        else:
            # Sync user role or workspaces if empty
            updates = {}
            if email in GADS_ADMIN_EMAILS and user.get("role") != "admin":
                updates["role"] = "admin"
                updates["workspace_ids"] = None
            elif role != "admin" and not user.get("workspace_ids"):
                if workspace_ids:
                    updates["workspace_ids"] = workspace_ids
            if updates:
                user_col.update_one({"_id": user["_id"]}, {"$set": updates})
                log.info("Updated GADS user '%s' in MongoDB: %s", email, updates)
            role = user.get("role", role)
        return role
    except Exception as e:
        log.error("Failed to ensure GADS user '%s' in MongoDB: %s", email, e)
        return role

@app.route("/auth/login")
def login():
    session.clear()
    session["post_login_redirect"] = request.args.get("redirect", POST_LOGIN_DEFAULT)
    redirect_uri = get_redirect_uri()
    log.info("Initiating Auth0 login redirect with callback: %s", redirect_uri)
    resp = auth0.authorize_redirect(redirect_uri=redirect_uri, prompt="login")
    resp.delete_cookie("gads_legacy", path="/")
    return resp

@app.route("/auth/callback")
def callback():
    try:
        token = auth0.authorize_access_token()
    except Exception as e:
        log.error("Auth0 token exchange failed: %s", e, exc_info=True)
        return jsonify({"error": "authentication_failed", "details": str(e)}), 400

    userinfo = token.get("userinfo")
    if not userinfo:
        log.warning("No userinfo returned in token: %s", token)
        return jsonify({"error": "no_userinfo"}), 400
    email = (userinfo.get("email") or "").lower()
    if not email:
        log.warning("No email found in userinfo: %s", userinfo)
        return jsonify({"error": "no_email"}), 400

    session.permanent = True
    session["user_email"] = email
    session["user_name"] = userinfo.get("name", email)
    session["authenticated_at"] = int(time.time())
    dest = session.pop("post_login_redirect", POST_LOGIN_DEFAULT)

    # 1. Auto-create or sync user in GADS MongoDB
    role = ensure_gads_user(email)

    # 2. Mint GADS JWT token and fetch tenant info for React app
    gadstoken = mint_gads_jwt(email)
    secret, tenant = get_default_signing_info()

    log.info("Successfully authenticated user '%s' (role: %s), auto-logging into GADS and redirecting to '%s'", email, role, dest)

    # 3. Return HTML page that initializes localStorage before redirecting to GADS SPA
    html = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Signing in to GADS...</title>
</head>
<body>
    <script>
        try {{
            localStorage.setItem("accessToken", {json.dumps(gadstoken)});
            localStorage.setItem("username", {json.dumps(email)});
            localStorage.setItem("userRole", {json.dumps(role)});
            if ({json.dumps(tenant)}) {{
                localStorage.setItem("tenant", {json.dumps(tenant)});
            }}
        }} catch (e) {{
            console.error("Failed to set localStorage", e);
        }}
        window.location.replace({json.dumps(dest)});
    </script>
    <p style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; text-align: center; margin-top: 60px; color: #444;">
        Logging in to GADS...
    </p>
</body>
</html>"""
    resp = make_response(html, 200, {"Content-Type": "text/html; charset=utf-8"})
    resp.delete_cookie("gads_legacy", path="/")
    return resp

@app.route("/auth/logout")
def logout():
    session.clear()
    auth0_logout = get_auth0_logout_url()
    html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Logging Out...</title></head><body>
<script>
try {{ localStorage.clear(); }} catch(e) {{}}
window.location.href = {json.dumps(auth0_logout)};
</script>
<p style="font-family: sans-serif; text-align: center; margin-top: 60px; color: #444;">Logging out...</p>
</body></html>"""
    resp = make_response(html, 200, {"Content-Type": "text/html; charset=utf-8"})
    resp.delete_cookie("gads_sso_session", path="/")
    resp.delete_cookie("gads_legacy", path="/")
    return resp

@app.route("/auth/verify")
def verify():
    email = session.get("user_email")
    if email:
        role = ensure_gads_user(email)
        token = mint_gads_jwt(email)
        secret, tenant = get_default_signing_info()

        resp = make_response("", 200)
        resp.headers["X-GADS-Auth-Token"] = token
        resp.headers["X-GADS-React-Token"] = token
        resp.headers["X-GADS-User"] = email
        resp.headers["X-GADS-Role"] = role
        resp.headers["X-GADS-Tenant"] = tenant or ""
        resp.headers["X-GADS-Mode"] = "sso"
        return resp

    # Allow request if user is in legacy auth mode
    if request.cookies.get("gads_legacy") == "1":
        resp = make_response("", 200)
        resp.headers["X-GADS-Mode"] = "legacy"
        return resp

    return jsonify({"error": "not_authenticated"}), 401

@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"}), 200

# Intercept GADS native login - return JWT for SSO-authenticated users, or forward for legacy
@app.route("/authenticate", methods=["POST"])
def authenticate():
    email = session.get("user_email")
    if not email:
        headers = {
            "Host": request.host,
            "Content-Type": request.content_type or "application/json",
        }
        if request.headers.get("Authorization"):
            headers["Authorization"] = request.headers["Authorization"]
        resp = http_requests.post(
            f"http://host.docker.internal:{GADS_PORT}/authenticate",
            headers=headers,
            data=request.get_data(),
            timeout=30
        )
        return Response(
            resp.content,
            status=resp.status_code,
            content_type=resp.headers.get("Content-Type", "application/json")
        )
    role = ensure_gads_user(email)
    gadstoken = mint_gads_jwt(email)
    secret, tenant = get_default_signing_info()
    return jsonify({
        "success": True, "message": "",
        "result": {
            "access_token": gadstoken,
            "accessToken": gadstoken,
            "token_type": "Bearer",
            "expires_in": 43200,
            "username": email,
            "role": role,
            "tenant": tenant or "",
        }
    })

# Legacy auth entry point: logs user out from current SSO session and sends to native GADS login
@app.route("/authenticate/legacy")
@app.route("/authenticate/legacy/")
@app.route("/legacy/auth")
@app.route("/legacy/auth/")
@app.route("/auth/legacy")
@app.route("/auth/legacy/")
def legacy_auth():
    session.clear()
    log.info("Switching user to GADS legacy auth mode")
    html = """<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Switching to GADS Login...</title>
</head>
<body>
    <script>
        try {
            localStorage.clear();
        } catch (e) {}
        window.location.replace("/login");
    </script>
    <p style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; text-align: center; margin-top: 60px; color: #444;">
        Switching to GADS login...
    </p>
</body>
</html>"""
    resp = make_response(html, 200, {"Content-Type": "text/html; charset=utf-8"})
    resp.delete_cookie("gads_sso_session", path="/")
    resp.set_cookie(
        "gads_legacy", "1",
        max_age=86400,
        path="/",
        httponly=True,
        secure=app.config["SESSION_COOKIE_SECURE"],
        samesite="Lax"
    )
    return resp

# Logout endpoint: clears session in proxy, forwards to GADS hub, and clears cookies
@app.route("/logout", methods=["GET", "POST"])
def gads_logout():
    auth_header = request.headers.get("Authorization")
    if auth_header:
        try:
            http_requests.post(
                f"http://host.docker.internal:{GADS_PORT}/logout",
                headers={"Authorization": auth_header, "Host": request.host},
                timeout=5
            )
        except Exception as e:
            log.warning("Failed to forward logout to GADS hub: %s", e)

    session.clear()
    log.info("User logged out from GADS and SSO proxy")

    if request.method == "POST":
        resp = jsonify({"success": True, "message": "logged out"})
    else:
        auth0_logout = get_auth0_logout_url()
        html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Logging Out...</title></head><body>
<script>
try {{ localStorage.clear(); }} catch(e) {{}}
window.location.href = {json.dumps(auth0_logout)};
</script>
<p style="font-family: sans-serif; text-align: center; margin-top: 60px; color: #444;">Logging out...</p>
</body></html>"""
        resp = make_response(html, 200, {"Content-Type": "text/html; charset=utf-8"})

    resp.delete_cookie("gads_sso_session", path="/")
    resp.delete_cookie("gads_legacy", path="/")
    return resp

# Catch-all: proxy to GADS with JWT injection
@app.route("/", defaults={"path": ""})
@app.route("/<path:path>")
def catch_all(path):
    if request.cookies.get("gads_legacy") == "1" and not session.get("user_email"):
        gads_url = f"http://host.docker.internal:{GADS_PORT}/{path}"
        if request.query_string:
            gads_url += f"?{request.query_string.decode()}"
        headers = {"Host": request.host}
        if request.headers.get("Authorization"):
            headers["Authorization"] = request.headers["Authorization"]
        resp = http_requests.get(gads_url, headers=headers, timeout=30)
        return Response(resp.content, status=resp.status_code, content_type=resp.headers.get("Content-Type", "text/html"))
    email = session.get("user_email")
    if not email:
        if path == "" or path in ("health", "favicon.ico") or path.startswith("admin/") or path.startswith("api/"):
            return jsonify({"error": "not_authenticated"}), 401
        return redirect(f"/auth/login?redirect=/{path}")
    return proxy_to_gads(path)

def inspect_cloudflared_token():
    """Inspect local Cloudflare tunnel tokens and log auto-detection info."""
    token_path = "/etc/cloudflared/token"
    if os.path.exists(token_path):
        try:
            with open(token_path, "r") as f:
                raw = f.read().strip()
            decoded = json.loads(base64.b64decode(raw + "==").decode("utf-8"))
            log.info("Detected Cloudflare Tunnel on host (Tunnel ID: %s, Account: %s)", decoded.get("t"), decoded.get("a"))
        except Exception as e:
            log.debug("Could not inspect cloudflared token: %s", e)
    if REDIRECT_URI:
        log.info("Static REDIRECT_URI in .env: %s", REDIRECT_URI)
    else:
        log.info("REDIRECT_URI will be automatically detected per-request based on incoming Host & Scheme (Cloudflare/LAN/localhost)")

inspect_cloudflared_token()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5050)
