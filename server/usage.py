"""Page allowance per signed-in user, decided in the database (supabase/migrations: claim_page, unlock_page).

  access 'full'    Pro, under the monthly cap (30): the whole page
         'free'    the one free page every new account gets: the whole page
         'preview' no Pro and the free page is used: the first half only (cut on the server, then unlocked by a purchase)
         'cap'     Pro, and this billing period's pages are used up: nothing is read

Needs SUPABASE_URL and SUPABASE_SECRET_KEY (Supabase > Project Settings > API Keys > secret key, or the legacy
service_role key). Only the server holds it; the functions cannot be called with the app's publishable key.
Without them (your own computer, or the shared test key) every page is 'full'."""
from __future__ import annotations

import json
import os
import urllib.request

PAGE_LIMIT = int(os.environ.get("MUSICSCAN_PAGE_LIMIT", "30"))


def enabled() -> bool:
    return bool(os.environ.get("SUPABASE_URL") and os.environ.get("SUPABASE_SECRET_KEY"))


def _rpc(fn: str, args: dict) -> dict:
    url = os.environ["SUPABASE_URL"].rstrip("/") + f"/rest/v1/rpc/{fn}"
    key = os.environ["SUPABASE_SECRET_KEY"]
    headers = {"apikey": key, "Content-Type": "application/json", "Accept": "application/json"}
    if key.startswith("eyJ"):  # legacy service_role key is a JWT and goes in Authorization too
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(url, data=json.dumps(args).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        rows = json.loads(r.read() or b"[]")
    row = rows[0] if isinstance(rows, list) and rows else rows
    return {"access": row["access"], "pages_used": row["pages_used"], "page_limit": row["page_limit"],
            "renews_at": row.get("renews_at")}


FULL = {"access": "full", "pages_used": 0, "page_limit": PAGE_LIMIT, "renews_at": None}


def claim(user: dict | None, job_id: str) -> dict:
    """What this scan gets. Safe to call again for the same job (the database answers the same)."""
    if not user or not enabled():
        return dict(FULL)
    return _rpc("claim_page", {"p_user": user["id"], "p_job": job_id, "p_limit": PAGE_LIMIT})


def unlock(user: dict | None, job_id: str) -> dict:
    """After a purchase: turn this job's preview into a Pro page, if the entitlement is active and under the cap."""
    if not user or not enabled():
        return dict(FULL)
    return _rpc("unlock_page", {"p_user": user["id"], "p_job": job_id, "p_limit": PAGE_LIMIT})
