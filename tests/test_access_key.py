"""The optional access key on a hosted server (MUSICSCAN_ACCESS_KEY): API locked, editor files and health open."""
import pytest

fastapi = pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

import server.app as srv  # noqa: E402


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(srv, "ACCESS_KEY", "s3cret")
    return TestClient(srv.app)


def test_api_needs_key(client):
    assert client.post("/api/jobs", files={"file": ("a.jpg", b"x")}).status_code == 401
    assert client.get("/api/jobs/abc").status_code == 401
    assert client.get("/api/jobs/abc?key=wrong").status_code == 401
    h = client.get("/api/health").json()
    assert h["key_required"] and not h["authorized"]


def test_key_in_address_sets_cookie(client):
    r = client.get("/?key=s3cret")
    assert r.status_code == 200 and r.cookies.get(srv.KEY_COOKIE) == "s3cret"
    assert client.get("/api/health").json()["authorized"]
    assert client.get("/api/jobs/nope").status_code == 404  # past the lock


def test_header(client):
    assert client.get("/api/jobs/nope", headers={"X-MusicScan-Key": "s3cret"}).status_code == 404


def test_no_key_configured(monkeypatch):
    monkeypatch.setattr(srv, "ACCESS_KEY", "")
    c = TestClient(srv.app)
    assert c.get("/api/jobs/nope").status_code == 404
    assert c.get("/api/health").json()["authorized"]


# --- per-user sign-in (Supabase access tokens) ---
import time  # noqa: E402

jwt = pytest.importorskip("jwt")
URL = "https://proj.supabase.co"


def _token(sub="user-1", secret="jwt-secret", iss=URL + "/auth/v1", exp=None, **extra):
    claims = {"sub": sub, "aud": "authenticated", "iss": iss, "exp": exp or int(time.time()) + 3600,
              "email": "a@example.com", "app_metadata": {"provider": "apple"}, **extra}
    return jwt.encode(claims, secret, algorithm="HS256")


@pytest.fixture
def signin(monkeypatch):
    monkeypatch.setattr(srv, "ACCESS_KEY", "")
    monkeypatch.setenv("SUPABASE_URL", URL)
    monkeypatch.setenv("SUPABASE_JWT_SECRET", "jwt-secret")
    return TestClient(srv.app)


def test_signin_required(signin):
    assert signin.get("/api/jobs/nope").status_code == 401
    assert signin.get("/api/health").json()["sign_in"]


def test_signin_bearer_and_cookie(signin):
    h = {"Authorization": "Bearer " + _token()}
    assert signin.get("/api/jobs/nope", headers=h).status_code == 404
    assert signin.get("/api/health", headers=h).json()["user"] == "user-1"
    signin.cookies.set("musicscan_session", _token())
    assert signin.get("/api/jobs/nope").status_code == 404


@pytest.mark.parametrize("bad", [
    dict(secret="forged"), dict(iss="https://other.supabase.co/auth/v1"), dict(exp=int(time.time()) - 10)])
def test_signin_rejects_bad_tokens(signin, bad):
    h = {"Authorization": "Bearer " + _token(**bad)}
    assert signin.get("/api/jobs/nope", headers=h).status_code == 401


def test_key_still_works_beside_signin(signin, monkeypatch):
    monkeypatch.setattr(srv, "ACCESS_KEY", "s3cret")
    assert signin.get("/api/jobs/nope?key=s3cret").status_code == 404


def test_signin_jwks_es256(monkeypatch):
    """New Supabase projects sign tokens with an asymmetric key published as JWKS."""
    from cryptography.hazmat.primitives.asymmetric import ec
    from server import auth
    priv = ec.generate_private_key(ec.SECP256R1())

    class Keys:
        def get_signing_key_from_jwt(self, token):
            return type("K", (), {"key": priv.public_key()})()
    monkeypatch.setattr(srv, "ACCESS_KEY", "")
    monkeypatch.setenv("SUPABASE_URL", URL)
    monkeypatch.delenv("SUPABASE_JWT_SECRET", raising=False)
    monkeypatch.setattr(auth, "_jwks", lambda url: Keys())
    good = jwt.encode({"sub": "u2", "aud": "authenticated", "iss": URL + "/auth/v1", "exp": int(time.time()) + 60,
                       "is_anonymous": True}, priv, algorithm="ES256")
    assert auth.verify(good) == {"id": "u2", "email": None, "provider": None, "anonymous": True}
    assert auth.verify(_token()) is None  # an HS256 token is refused when the project uses signing keys
