# MILLS home bridges

Small, read-only services and scripts that run on one always-on machine at home (the "hub") and
feed the **MILLS TV** launcher (`mills-tv` repo): a Blink bridge, a Nest bridge over Matter, a
status dashboard, a guard that keeps the TV the way we set it, and the scripts we used to clean up
and manage a Sony BRAVIA (Google TV) over ADB.

The rule behind all of it: **the TV reads, the phone approves.** None of these services change a
camera, thermostat or account setting. They read, and they answer only the addresses you allow.

## What's here

| Folder / file | What it does |
|---|---|
| `blink-bridge/bridge.py` | Reads Blink cameras and doorbell events with [blinkpy](https://github.com/fronzbot/blinkpy) and serves JSON and snapshots on port 8779. Optional clip archive to a NAS folder (never deletes). Your password is never stored; only the refresh token, in `blink-token.json` (0600, git-ignored). |
| `nest-bridge/` | Joins a Nest thermostat as a second, read-only Matter controller with [matter.js](https://github.com/project-chip/matter.js) and serves `GET /api/house` on port 8778. No cloud API key. Pairing state lives in `.matter-storage/` (git-ignored). |
| `dashboard/` | `server.py` serves a status page and `/api/status` on port 8777: the hub's load, memory and disk, local models, and an agent roster (`agents.json`) checked against what Tailscale can see. `tv.html` is a page rotator for the TV; `dc_render.js` and `build_tv.sh` render design boards into pages. |
| `tv_guard.sh`, `guard/` | Every 15 minutes, checks the TV over ADB and puts back the default home, the screensaver and the debloat list if a TV update undid them. Never uninstalls; protected system apps are only reported. |
| `*.sh`, `tv.py` | TV tools: connect, audit, debloat and restore, set ad-block DNS, build and install the launcher, screenshots, emulator tests, UniFi read-only probes. `tv.py` is a Sony Bravia REST (IP Control) client. |
| `millsos-tv-app/` | An earlier, minimal full-screen viewer app for the dashboard. |
| `brand_render/`, `wallpaper_render/` | HTML sources used to render the launcher's banner, icon and wallpapers. |
| `MILLS-OS-TV-DESIGN-RULES.md` | The design system the TV screens follow: tokens, type scale, focus model, data-honesty rules. |

Not included: the dashboard's design boards and their rendered pages (`dashboard/boards/`,
`tv-r-*.html`, `tv-v4*.html`). They were dated snapshots of our own build status. Add your own
boards to `dashboard/boards/` and run `dashboard/build_tv.sh`.

## Setup

Everything runs on macOS with Homebrew; most of it works on Linux too.

```bash
brew install android-platform-tools node python@3.12

# who may read the bridges: localhost plus your TV
export TV=192.168.1.x            # your TV's address
export HUB_IP=192.168.1.x        # this machine's LAN address (fallback if en0 has none)
export BLINK_ALLOW="127.0.0.1,$TV"
export DASH_ALLOW="127.0.0.1,$TV"

# Blink
cd blink-bridge && python3 -m venv .venv && .venv/bin/pip install blinkpy aiohttp
.venv/bin/python bridge.py login      # once, interactive
.venv/bin/python bridge.py serve

# Nest (code from Google Home > Linked Matter apps & services)
cd nest-bridge && npm ci && node bridge.mjs pair <code> && node bridge.mjs serve

# Dashboard
python3 dashboard/server.py
```

Scripts that talk to the TV need `TV` set and **Network debugging** on (Settings > System >
Developer options), with the "Allow debugging?" prompt accepted on the TV. `run.sh` and `tv.py`
use the Bravia IP Control pre-shared key: `PSK=yourkey bash run.sh` (Settings > Network > Home
Network > IP Control).

Optional settings:
- `BLINK_DOORBELL_TYPES`: extra product-type codes to treat as doorbells (doorbells are already
  detected by class).
- `BLINK_ARCHIVE_DIR`, `BLINK_ARCHIVE_MOUNT`: archive folder and an `smb://` URL to remount it.
  Credentials come from the macOS keychain, never from this repo.
- `unifi_probe.sh` and `unifi_snapshot.sh` read a UniFi gateway with a read-only API key that you
  paste at a hidden prompt (or read from your password manager). Set `GW` to the gateway address.

## Privacy

- Tokens, Matter pairing state, logs, virtual environments and build output are git-ignored.
- The bridges answer only the IPs in `*_ALLOW`.
- Placeholders such as `192.168.1.x` and `<tv-ip>` stand for your own addresses.

## Credit

The launcher these scripts install is built on [tv-vibehack](https://github.com/Gathin23/tv-vibehack)
by Gathin (MIT). Blink access uses blinkpy; Nest access uses matter.js.

## License

MIT, see [`LICENSE`](LICENSE). The Outfit typeface in `brand_render/` is under the SIL Open Font
License 1.1.

Maintained by JJ Mills for BREAKINBREAD INSTITUTE INC.
