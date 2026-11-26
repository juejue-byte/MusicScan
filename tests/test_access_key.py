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
