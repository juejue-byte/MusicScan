"""Per-user sign-in for the hosted server: Supabase Auth access tokens (Sign in with Apple, Google, email link,
or an anonymous account), checked on every API call.

Turned on by SUPABASE_URL (https://<project>.supabase.co). The app sends the user's access token as
  Authorization: Bearer <token>        (native code, API clients)
or as the cookie  musicscan_session    (the iOS app sets it in the WKWebView before loading the editor, and again
                                         after each token refresh, so the editor's own requests carry it)
Tokens are verified locally against the project's published signing keys (JWKS, cached), so a check costs no network
call. Projects still on the legacy shared secret set SUPABASE_JWT_SECRET instead.
Unset SUPABASE_URL = sign-in off (your own computer, or the shared access key while testing)."""
from __future__ import annotations

import os
from functools import lru_cache

SESSION_COOKIE = "musicscan_session"


def supabase_url() -> str:
    return os.environ.get("SUPABASE_URL", "").rstrip("/")


def enabled() -> bool:
    return bool(supabase_url())


@lru_cache(maxsize=1)
def _jwks(url: str):
    import jwt
    return jwt.PyJWKClient(f"{url}/auth/v1/.well-known/jwks.json", cache_keys=True, lifespan=3600)


def token_from(request) -> str:
    h = request.headers.get("authorization", "")
    if h[:7].lower() == "bearer ":
        return h[7:].strip()
    return request.cookies.get(SESSION_COOKIE, "")


def verify(token: str) -> dict | None:
    """The signed-in user for a Supabase access token, or None if it is missing, expired, forged or for another
    project. {"id", "email", "provider", "anonymous"}"""
    url = supabase_url()
    if not url or not token:
        return None
    import jwt
    opts = {"audience": "authenticated", "issuer": f"{url}/auth/v1", "options": {"require": ["exp", "sub"]}}
    try:
        secret = os.environ.get("SUPABASE_JWT_SECRET")
        if secret:
            claims = jwt.decode(token, secret, algorithms=["HS256"], **opts)
        else:
            key = _jwks(url).get_signing_key_from_jwt(token)
            claims = jwt.decode(token, key.key, algorithms=["ES256", "RS256"], **opts)
    except Exception:
        return None
    meta = claims.get("app_metadata") or {}
    return {"id": claims["sub"], "email": claims.get("email") or None, "provider": meta.get("provider"),
            "anonymous": bool(claims.get("is_anonymous"))}


def user_from(request) -> dict | None:
    return verify(token_from(request))
