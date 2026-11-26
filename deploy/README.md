# Host the MusicScan reading server (Modal, GPU, HTTPS)

This puts the real reader (copisteria 28m + 2m, the photo clean-up and the editor) on a public `https://` address,
so the iPhone and iPad app work anywhere, not just on your Wi-Fi. It runs on [Modal](https://modal.com): you pay
per second while a container is up, it scales to zero 10 minutes after the last request, and Modal's free plan
includes monthly credits that cover a lot of testing. Everything in the image is commercially usable (Apache-2.0
copisteria code and weights, BSD/MIT/Apache Python packages; see `THIRD_PARTY_NOTICES.md`).

## Deploy (about 15 minutes the first time)

On your Mac, in the repo:

```bash
cd MusicScan && git pull
. .venv/bin/activate              # or any Python 3.10+
pip install modal
modal setup                       # opens the browser: sign in / create the Modal account
```

Make an access key, so strangers who find the address can't use your GPU. Copy the key it prints; you'll paste it
into the app.

```bash
KEY=$(openssl rand -hex 16); echo "$KEY"
modal secret create musicscan MUSICSCAN_ACCESS_KEY="$KEY"
```

Deploy:

```bash
modal deploy deploy/modal_app.py
```

The first build takes 5 to 10 minutes (PyTorch and the model weights go into the image). Later deploys, after a
`git pull`, take seconds unless `requirements` or the copisteria pin changed. It ends with a line like

```
└── 🔨 Created web function web => https://YOURNAME--musicscan.modal.run
```

Your server address is that URL plus the key: **`https://YOURNAME--musicscan.modal.run/?key=YOURKEY`**.

## Check it in a browser

Open the address with `?key=…` in Safari on the Mac. The first request after a pause wakes the container (30 to
60 seconds), then pages read in a few seconds. Tap a sample photo, or drop a photo of your own. The key is kept in a
cookie, so later visits work without it. `https://YOURNAME--musicscan.modal.run/api/health` shows whether that
browser is authorized and which device the reader uses (`cuda` once a page has been read).

## Point the iPhone and iPad app at it

In the app in `ios/` (build it as in `ios/README.md`):

- **In the app:** tap **Server: …** on the start screen (or **Change server** on the error screen), paste the
  address with `?key=…`, tap **Test connection**, then **Save**. It is remembered per device.
- **As the built-in default:** Xcode > MusicScan target > **Build Settings** > search `MUSICSCAN_SERVER_URL` and set
  it (Debug and Release) to the same address. That value lands in `Info.plist` as `MusicScanServerURL` and is read
  by `ios/MusicScan/ServerConfig.swift` (`defaultURL`). The simulator always uses `http://localhost:8000`; change it
  in the app if you want the simulator on the hosted server too.

Because it is `https`, nothing else is needed: no Wi-Fi pairing, no local-network prompt.

### If you are building a new app (the Sky design) instead

Keep one base URL setting the same way, and either load the web editor from it in a `WKWebView` (what the
prototype does) or call the API directly. Send the key as the `X-MusicScan-Key` header on every request.

| Call | What it does |
| --- | --- |
| `GET /api/health` | `{"ok": true, "app": "musicscan", "authorized": …}`. Use it for "Test connection". |
| `POST /api/jobs` (multipart: `file`, optional `page` for PDFs, `context` JSON) | Starts reading one page. Returns `{"id", "pages", "page"}`. |
| `GET /api/jobs/{id}` | Poll about once a second: `status` is a progress line until `"done"` (then `result.xml` is MusicXML, `result.measures` has per-bar warnings, `result.quality` the photo check) or `"error"`. |
| `GET /api/jobs/{id}/page.png` | The cleaned, flattened page the reading is drawn over. |
| `POST /api/jobs/{id}/rescan` (`measures`, `attempt`, optional `file`) | Reads selected bars again, a different way each attempt. |

## Everyday commands

```bash
modal app logs musicscan                  # live server log (each page, errors)
git pull && modal deploy deploy/modal_app.py   # ship the latest code
MUSICSCAN_GPU=L4 modal deploy deploy/modal_app.py   # a faster GPU (T4 is the default and the cheapest)
modal app stop musicscan                  # take it offline
modal secret create musicscan MUSICSCAN_ACCESS_KEY=NEWKEY --force   # change the key, then deploy again
```

Scans (the photo, the cleaned page and the reading) are kept in the Modal volume `musicscan-work` so a rescan still
works after the container sleeps. `modal volume ls musicscan-work` lists them; `modal volume delete musicscan-work`
removes them all.

## Limits of this setup

- **One container.** Jobs are tracked in that container's memory, so `max_containers=1`. Fine for testing and a
  small TestFlight group (a page takes a few seconds of GPU); a busy launch needs the queue described below.
- **One shared key**, not user accounts. Anyone with the key can read pages. Rotate it if it leaks.
- **No paywall enforcement on the server yet.** The paywall in `web/js/paywall.js` is UI only.

## Before launch

See the launch plan (linked from the project) for the full list. In short: Sign in with Apple + per-user page
counts and StoreKit entitlements checked on the server, previews cut to the first half on the server, jobs in shared
storage (so `max_containers` can go up), photo retention and a Privacy Policy, and the web editor bundled into the app.
