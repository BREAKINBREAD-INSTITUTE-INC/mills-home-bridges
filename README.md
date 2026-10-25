# MILLS home bridges

Small services and scripts that run on one always-on machine at home (the "hub") and
feed the **MILLS TV** launcher (`mills-tv` repo): a Blink bridge, a Nest bridge over Matter, a
status dashboard, a guard that keeps the TV the way we set it, and the scripts we used to clean up
and manage a Sony BRAVIA (Google TV) over ADB.

The rule behind all of it: **the TV reads, the phone approves.** The services read, and they answer
only the addresses you allow. Two narrow exceptions write anything: the Nest bridge can change the
thermostat's targets and mode within fixed limits, and the dashboard stores the TV's Mission
Control layout (card order, names, notes). Nothing changes a camera or an account setting.

## What's here

| Folder / file | What it does |
|---|---|
| `blink-bridge/bridge.py` | Reads Blink cameras and doorbell events with [blinkpy](https://github.com/fronzbot/blinkpy) and serves JSON and snapshots on port 8779: the device list, clip history by camera and kind, the clips themselves (with HTTP Range, so the TV can seek) and their thumbnails. Optional clip archive to a NAS folder (never deletes). Account, network and camera ids and tokens are redacted from every log line and served error. Your password is never stored; only the refresh token, in `blink-token.json` (0600, git-ignored). |
| `nest-bridge/` | Joins a Nest thermostat as a second Matter controller with [matter.js](https://github.com/project-chip/matter.js) (Google Home stays as it is) and serves it on port 8778. **v2** can change the setpoints and the mode, and nothing else: see below. No cloud API key. Pairing state lives in `.matter-storage/` and the change log in `changes.jsonl` (both git-ignored). Tests: `npm test`. |
| `dashboard/` | `server.py` serves a status page and `/api/status` on port 8777: the hub's load, memory and disk, local models, an agent roster (`agents.json`) checked against what Tailscale can see, and, if you add an `infra.json`, your model machines and NAS. The fleet is checked in the background every 30 s, so the TV never waits on a slow machine. It also serves `/api/layout` and `/api/budget` (below). `tv.html` is a page rotator for the TV; `dc_render.js` and `build_tv.sh` render design boards into pages. |
| `tv_guard.sh`, `guard/` | Every 15 minutes, checks the TV over ADB and puts back the default home, the screensaver and the debloat list if a TV update undid them. Never uninstalls; protected system apps are only reported. |
| `*.sh`, `tv.py` | TV tools: connect, audit, debloat and restore, set ad-block DNS, build and install the launcher, screenshots, emulator tests, UniFi read-only probes. `tv.py` is a Sony Bravia REST (IP Control) client. |
| `millsos-tv-app/` | An earlier, minimal full-screen viewer app for the dashboard. |
| `brand_render/`, `wallpaper_render/` | HTML sources used to render the launcher's banner, icon and wallpapers. |
| `MILLS-OS-TV-DESIGN-RULES.md` | The design system the TV screens follow: tokens, type scale, focus model, data-honesty rules. v2 adds the Glass look, the Quick menu and on-TV layout editing. |

### Nest bridge v2: what the TV may change

| Route | What it does |
|---|---|
| `GET /api/house` | The reading, plus the limits, the modes the Nest accepts, and the last change |
| `GET /api/house/changes` | The last changes, newest last |
| `POST /api/house/cool`, `/heat` | `{"f": 76}`: set the cooling or heating setpoint |
| `POST /api/house/step` | `{"delta": 1 or -1, "target": "cool" or "heat"}`: one degree up or down |
| `POST /api/house/mode` | `{"mode": "Off", "Heat", "Cool" or "Auto"}`: only modes the Nest accepts |

Only addresses in `NEST_ALLOW` may call it (403 otherwise). Every write is clamped to 68-82 °F,
keeps heat below cool (3 °F apart in Auto), is limited to one change every 3 s and 30 an hour,
is read back from the thermostat before it counts as done, and is logged to `changes.jsonl`.

### Mission Control layout (`/api/layout`)

The TV's **Edit layout** mode saves here: `GET /api/layout` returns it, and `POST /api/layout`
replaces it with `{"agents": [{"name", "label"?, "note"?}...], "machines": [...]}`. Only names,
order and short text are accepted (labels up to 24 characters, notes up to 80), and only from the
addresses in `DASH_ALLOW`. An empty label or note means "back to the default". `/api/status`
returns the agents and machines in that order with `label` applied and the defaults alongside
(`default_label`, `default_note`). It's stored in `dashboard/layout.json` (git-ignored).

### Housing budget (`/api/budget`)

`GET /api/budget` reads a tab-separated bills file **outside this repo** (path in `BILLS_TSV`,
default `~/private/household_bills.tsv`) and returns each monthly line and the total. Columns:
`date`, `payee`, `category`, `amount_usd`, `paid_with`, `note`; lines starting with `#` are
skipped. For example (made-up figures):

```
date	payee	category	amount_usd	paid_with	note
monthly	Landlord	rent	1500.00	ACH	fixed monthly
2026-01-15	Power Co	electric	120.00	card
2026-01-10	City	water, trash, sewer	90.00	card	billed about every 2 months
2026-01-16	ISP	internet	60.00	card
```

A `monthly` row is fixed; for the others the latest row counts. A category containing "setup"
is left out, and a note containing "every 2 months" halves the amount (and says so). Keep the
file `chmod 600`; the dashboard serves it only to `DASH_ALLOW`.

### Sample TV boards

`dashboard/boards/` holds ten **sample** boards (`TVR-Glance`, `Waiting`, `Activity`, `Leads`,
`Next`, `Fix`, `Safety`, `Machines`, `Models`, `Log`), and `dashboard/tv-r-*.html` are those boards
already rendered, so `tv.html` works out of the box. Every name, number, time and address on them
is made up (Lead A to Lead D, machines `hub`, `studio-1`, `studio-2`, `gpu-1`, `monitor-1`, the date
2026-01-01), and each page carries a **SAMPLE DATA** label. Our own boards are not published: they
were dated snapshots of our build status.

To use your own data:

1. Edit a board in `dashboard/boards/`. The markup and styles are the layout; the data is the JSON
   returned by `renderVals()` in the `<script type="text/x-dc">` block at the bottom. `{{name}}`
   fills in a value and `<sc-for list="{{rows}}" as="r">` repeats a block for each item.
2. Remove the `SAMPLE DATA` label from the header when the data is real.
3. Run `bash dashboard/build_tv.sh` (needs `node`). It renders each board to `tv-r-<name>.html`,
   fails if anything is left unrendered, and writes `missioncontrol.html` from `tv.html`.
4. To add or drop a page, change `PAIRS` in `build_tv.sh` and the page lists in `tv.html` and
   `tv_page.sh` to match.

`build_tv.sh` keeps the first `missioncontrol.html` it replaces as `missioncontrol.before-tv.html`
(git-ignored); `bash build_tv.sh undo` puts it back.

## Setup

Everything runs on macOS with Homebrew; most of it works on Linux too.

```bash
brew install android-platform-tools node python@3.12

# who may read the bridges: localhost plus your TV
export TV=192.168.1.x            # your TV's address
export HUB_IP=192.168.1.x        # this machine's LAN address (fallback if en0 has none)
export BLINK_ALLOW="127.0.0.1,$TV"
export DASH_ALLOW="127.0.0.1,$TV"
export NEST_ALLOW="127.0.0.1,$TV"

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

- Tokens, Matter pairing state, the thermostat change log, the Mission Control layout, logs,
  virtual environments and build output are git-ignored. The bills file lives outside the repo.
- The bridges answer only the IPs in `*_ALLOW`.
- Placeholders such as `192.168.1.x` and `<tv-ip>` stand for your own addresses.

## Credit

The launcher these scripts install is built on [tv-vibehack](https://github.com/Gathin23/tv-vibehack)
by Gathin (MIT). Blink access uses blinkpy; Nest access uses matter.js.

## License

MIT, see [`LICENSE`](LICENSE). The Outfit typeface in `brand_render/` is under the SIL Open Font
License 1.1.

Maintained by JJ Mills for BREAKINBREAD INSTITUTE INC.
