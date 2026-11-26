#!/usr/bin/env bash
# Point your local setup at a hosted MusicScan server, keeping the key out of git:
#   scripts/use_server.sh https://YOURNAME--musicscan.us-east.modal.run YOURKEY
# Writes .env and ios/Secrets.xcconfig (both gitignored). The iOS app then opens that server with the key built in.
set -euo pipefail
cd "$(dirname "$0")/.."
url="${1:?usage: scripts/use_server.sh <server address> <access key>}"; key="${2:-}"
url="${url%/}"
case "$url" in http://*|https://*) ;; *) url="https://$url" ;; esac
case "$key" in *[!A-Za-z0-9_-]*) echo "The key should be letters, digits, - or _ only." >&2; exit 1 ;; esac
printf 'MUSICSCAN_SERVER_URL=%s\nMUSICSCAN_ACCESS_KEY=%s\n' "$url" "$key" > .env
printf '// Written by scripts/use_server.sh; gitignored.\nMUSICSCAN_SERVER_URL = %s\nMUSICSCAN_ACCESS_KEY = %s\n' \
  "${url/:\/\//:/\$()/}" "$key" > ios/Secrets.xcconfig
chmod 600 .env ios/Secrets.xcconfig
{ git check-ignore -q .env && git check-ignore -q ios/Secrets.xcconfig; } || { echo "Warning: these files are not gitignored!" >&2; exit 1; }
echo "Saved to .env and ios/Secrets.xcconfig (not tracked by git)."
echo "In Xcode: Product > Clean Build Folder (⇧⌘K), then run (⌘R). Already-installed apps keep their saved address:"
echo "tap Server: … and paste  $url/?key=$key  once, or delete and reinstall the app."
