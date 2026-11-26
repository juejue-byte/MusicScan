#!/usr/bin/env bash
# Copy the server settings from .env (gitignored) into the Modal secret "musicscan", redeploy, and check that the
# live server sees them. Prints only names and yes/no, never the values.
#   scripts/sync_modal_secret.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env here. Run scripts/use_server.sh first, then add the Supabase lines (see .env.example)." >&2; exit 1; }
set -a; . ./.env; set +a

NAMES="MUSICSCAN_ACCESS_KEY SUPABASE_URL SUPABASE_SECRET_KEY SUPABASE_PUBLISHABLE_KEY SUPABASE_JWT_SECRET APPLE_BUNDLE_ID APPLE_APP_ID"
args=()
for n in $NAMES; do
  v="${!n:-}"
  v="${v//$'\r'/}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"  # drop CR and spaces
  printf -v "$n" '%s' "$v"
  if [ -n "$v" ]; then args+=("$n=$v"); echo "  set   $n"; else echo "  empty $n"; fi
done
for n in MUSICSCAN_ACCESS_KEY SUPABASE_URL SUPABASE_SECRET_KEY; do
  [ -n "${!n:-}" ] || { echo "$n is empty in .env; fill it in and run this again." >&2; exit 1; }
done

modal secret create musicscan --force "${args[@]}" >/dev/null
echo "Secret updated. Deploying…"
modal deploy deploy/modal_app.py

url="${MUSICSCAN_SERVER_URL%/}"
echo "Checking $url/api/health (the first call can take a minute while it wakes up)…"
health=$(curl -fsS -m 120 -H "X-MusicScan-Key: $MUSICSCAN_ACCESS_KEY" "$url/api/health") || { echo "Could not reach $url" >&2; exit 1; }
python3 - "$health" "$MUSICSCAN_ACCESS_KEY" <<'PY'
import hashlib, json, sys
h, mine = json.loads(sys.argv[1]), sys.argv[2]
ok = lambda b: "yes" if b else "NO"
print(f"  key accepted:     {ok(h.get('authorized'))}")
print(f"  sign-in on:       {ok(h.get('sign_in'))}")
if not h.get("authorized"):
    fp = hashlib.sha256(mine.encode()).hexdigest()[:6]
    print(f"  key in .env:      length {len(mine)}, fingerprint {fp}")
    print(f"  key on server:    length {h.get('key_length')}, fingerprint {h.get('key_fingerprint')}")
    print(f"  key it received:  fingerprint {h.get('sent_fingerprint')}  (None = nothing arrived)")
sys.exit(0 if h.get("authorized") and h.get("sign_in") else 1)
PY
echo "All good. The app must use the same key: run scripts/use_server.sh $MUSICSCAN_SERVER_URL <key> (or paste <address>/?key=<key> in Server: …), then Clean Build Folder and run."
