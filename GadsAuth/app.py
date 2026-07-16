import os, time, logging, json, requests as http_requests
from datetime import datetime, timedelta, timezone
from dotenv import load_dotenv
load_dotenv()
import jwt as pyjwt
from authlib.integrations.flask_client import OAuth
from flask import Flask, request, redirect, session, jsonify, make_response, Response

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("gads-sso-proxy")
app = Flask(__name__, static_folder=None)

FLASK_SECRET_KEY = os.environ["FLASK_SECRET_KEY"]
AUTH0_DOMAIN = os.environ["AUTH0_DOMAIN"]
AUTH0_CLIENT_ID = os.environ["AUTH0_CLIENT_ID"]
AUTH0_CLIENT_SECRET = os.environ["AUTH0_CLIENT_SECRET"]
REDIRECT_URI = os.environ["REDIRECT_URI"]
POST_LOGIN_DEFAULT = os.environ.get("POST_LOGIN_DEFAULT", "/")
GADS_ORIGIN = os.environ["GADS_ORIGIN"]
GADS_JWT_SECRET = os.environ["GADS_JWT_SECRET"]
GADS_USER_CLAIM = os.environ.get("GADS_USER_CLAIM", "username")
GADS_TENANT_CLAIM = os.environ.get("GADS_TENANT_CLAIM", "tenant")
GADS_TENANT_VALUE = os.environ.get("GADS_TENANT_VALUE", "assurecraft")
GADS_TOKEN_TTL_SECONDS = int(os.environ.get("GADS_TOKEN_TTL_SECONDS", "300"))
GADS_DEFAULT_ROLE = os.environ.get("GADS_DEFAULT_ROLE", "user")
GADS_ADMIN_EMAILS = {e.strip().lower() for e in os.environ.get("GADS_ADMIN_EMAILS", "").split(",") if e.strip()}
GADS_PORT = os.environ.get("GADS_PORT", "10000")
GADS_DEFAULT_SECRET = "tjsqEmu80WIMiyGJtP1WVdr3s81GIR3NttVgLj6mWUo="

app.secret_key = FLASK_SECRET_KEY
app.config.update(
    SESSION_COOKIE_NAME="gads_sso_session",
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=True,
    SESSION_COOKIE_SAMESITE="Lax",
    PERMANENT_SESSION_LIFETIME=timedelta(hours=10),
)

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

def mint_gads_jwt(email):
    """Mint a GADS-compatible JWT (for the React frontend to store)."""
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

def mint_origin_jwt(email):
    """Mint an origin-based JWT (for server-to-server with GADS)."""
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
        # Always overwrite the token — no stale-token check
        script = f'<script>localStorage.setItem("accessToken","{gadstoken}");localStorage.setItem("user","{email}");</script>'.encode()
        body = body.replace(b"</head>", script + b"</head>")
    return Response(body, status=resp.status_code, content_type=ct)

# --- Auth routes ---

@app.route("/auth/login")
def login():
    session.clear()
    session["post_login_redirect"] = request.args.get("redirect", POST_LOGIN_DEFAULT)
    return auth0.authorize_redirect(redirect_uri=REDIRECT_URI)

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

@app.route("/auth/verify")
def verify():
    email = session.get("user_email")
    if not email:
        return jsonify({"error": "not_authenticated"}), 401
    token = mint_origin_jwt(email)
    resp = make_response("", 200)
    resp.headers["X-GADS-Auth-Token"] = token
    return resp

@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"}), 200

# Intercept GADS native login - return JWT for SSO-authenticated users
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

@app.route("/auth/legacy")
def legacy_login():
    session.clear()
    resp = make_response(redirect("/"))
    resp.set_cookie("gads_legacy", "1", max_age=3600, httponly=True, secure=True, samesite="Lax")
    return resp

# Catch-all: proxy to GADS with JWT injection
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

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5050)
