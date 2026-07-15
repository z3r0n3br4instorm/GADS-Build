"""
GADS SSO Proxy — authenticates users against Auth0
and mints short-lived HMAC JWTs that GADS understands.

Flow:
  1. nginx protects the GADS hostname with `auth_request /auth/verify`.
  2. Unauthenticated users get redirected here to /auth/login.
  3. We send them through the Auth0 OAuth2/OIDC authorization code flow.
  4. On callback we validate the id_token and store a signed session cookie.
  5. On every subsequent request, nginx calls /auth/verify. If the session
     is valid we mint a fresh, short-lived JWT signed with the SAME secret
     configured in GADS's "Add New Secret Key" form, and return it in a
     response header that nginx injects as the Authorization header GADS
     receives.

This service never gives GADS your Auth0 credentials or tokens —
it only gives GADS a JWT signed with the secret YOU control, containing
only the claims GADS was configured to read.
"""

import os
import time
import logging
from datetime import datetime, timedelta, timezone

from dotenv import load_dotenv
load_dotenv()  # load .env file so it works with both "python app.py" and "flask run"

import jwt as pyjwt
from authlib.integrations.flask_client import OAuth
from flask import Flask, request, redirect, session, jsonify, make_response, url_for

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("gads-sso-proxy")

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Configuration (all via environment variables)
# ---------------------------------------------------------------------------
FLASK_SECRET_KEY   = os.environ["FLASK_SECRET_KEY"]           # session cookie signing key

# Auth0 application credentials
AUTH0_DOMAIN       = os.environ["AUTH0_DOMAIN"]               # e.g. dev-xxx.us.auth0.com
AUTH0_CLIENT_ID     = os.environ["AUTH0_CLIENT_ID"]            # Auth0 App -> Client ID
AUTH0_CLIENT_SECRET = os.environ["AUTH0_CLIENT_SECRET"]        # Auth0 App -> Client Secret

REDIRECT_URI       = os.environ["REDIRECT_URI"]               # e.g. https://gads-mac.assurecraft.com/auth/callback
POST_LOGIN_DEFAULT = os.environ.get("POST_LOGIN_DEFAULT", "/")

# These MUST match what you enter in GADS's "Add New Secret Key" form.
GADS_ORIGIN            = os.environ["GADS_ORIGIN"]             # e.g. "sso.assurecraft.com"
GADS_JWT_SECRET         = os.environ["GADS_JWT_SECRET"]        # the "Secret Key" value in GADS
GADS_USER_CLAIM         = os.environ.get("GADS_USER_CLAIM", "email")
GADS_TENANT_CLAIM       = os.environ.get("GADS_TENANT_CLAIM", "tenant")
GADS_TENANT_VALUE       = os.environ.get("GADS_TENANT_VALUE", "assurecraft")
GADS_TOKEN_TTL_SECONDS  = int(os.environ.get("GADS_TOKEN_TTL_SECONDS", "300"))  # short-lived, minted fresh each verify

# GADS's JWTClaims struct reads Role/Scope directly off the token — there's
# no dynamic claim-name remapping for these two (unlike Username/Tenant),
# so we set them explicitly per user on every mint.
GADS_DEFAULT_ROLE      = os.environ.get("GADS_DEFAULT_ROLE", "user")
GADS_ADMIN_EMAILS      = {
    e.strip().lower()
    for e in os.environ.get("GADS_ADMIN_EMAILS", "").split(",")
    if e.strip()
}

app.secret_key = FLASK_SECRET_KEY
app.config.update(
    SESSION_COOKIE_NAME="gads_sso_session",
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=True,      # requires HTTPS — you're behind Cloudflare tunnel, so fine
    SESSION_COOKIE_SAMESITE="Lax",
    PERMANENT_SESSION_LIFETIME=timedelta(hours=10),
)

# ---------------------------------------------------------------------------
# Auth0 OAuth client
# ---------------------------------------------------------------------------
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


# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------
@app.route("/auth/login")
def login():
    session.clear()
    session["post_login_redirect"] = request.args.get("redirect", POST_LOGIN_DEFAULT)
    return auth0.authorize_redirect(redirect_uri=REDIRECT_URI)


@app.route("/auth/callback")
def callback():
    # authlib handles state/nonce validation and token exchange
    token = auth0.authorize_access_token()
    userinfo = token.get("userinfo")

    if not userinfo:
        log.warning("No userinfo returned from Auth0")
        return jsonify({"error": "no_userinfo"}), 400

    email = (userinfo.get("email") or "").lower()
    if not email:
        log.warning("No email in Auth0 userinfo")
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
    # Auth0 OpenID Connect logout — returns user to the GADS root
    return_to = REDIRECT_URI.rsplit("/auth/", 1)[0]
    auth0_logout = (
        f"https://{AUTH0_DOMAIN}/v2/logout"
        f"?client_id={AUTH0_CLIENT_ID}"
        f"&returnTo={return_to}"
    )
    return redirect(auth0_logout)


# ---------------------------------------------------------------------------
# Verify endpoint — called by nginx's auth_request for every protected request
# ---------------------------------------------------------------------------
@app.route("/auth/verify")
def verify():
    email = session.get("user_email")
    if not email:
        return jsonify({"error": "not_authenticated"}), 401

    now = datetime.now(timezone.utc)
    role = "admin" if email in GADS_ADMIN_EMAILS else GADS_DEFAULT_ROLE

    payload = {
        # Registered/standard claims GADS's JWTClaims struct reads directly
        "sub": email,
        "username": email,
        "role": role,
        "scope": [role],
        "tenant": GADS_TENANT_VALUE,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(seconds=GADS_TOKEN_TTL_SECONDS)).timestamp()),
        "iss": "gads-sso-proxy",

        # Critical: GADS's ValidateJWT reads this claim to pick which
        # origin-specific secret key to verify against (see jwt.go's
        # keyFunc fallback when no origin is passed explicitly, e.g. via
        # the ?token= query param path). Signing with the origin's secret
        # alone is not enough — the claim must be present in the payload.
        "origin": GADS_ORIGIN,

        # Custom claim names as configured in GADS's "Add New Secret Key"
        # form (User Identifier Claim / Tenant Identifier Claim). These are
        # looked up dynamically from the raw token payload, so the key
        # names here must exactly match what you typed into that form.
        GADS_USER_CLAIM: email,
        GADS_TENANT_CLAIM: GADS_TENANT_VALUE,
    }
    token = pyjwt.encode(payload, GADS_JWT_SECRET, algorithm="HS256")

    resp = make_response("", 200)
    # nginx will read this via auth_request_set and inject it as the
    # Authorization header on the upstream request to GADS.
    resp.headers["X-GADS-Auth-Token"] = token
    resp.headers["X-Auth-User"] = email
    return resp


@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5050)
