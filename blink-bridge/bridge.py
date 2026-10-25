#!/usr/bin/env python3
"""
MILLS TV · Blink bridge.

Reads a Blink camera system (cameras + Video Doorbell) through Blink's cloud API, using the
blinkpy library, and serves it as small read-only JSON + JPEG snapshots on the home network for
a TV (or anything else) to show. Built to be shared: nothing about one house is baked in.

  .venv/bin/python bridge.py login     sign in once, interactively (email, password, Blink's code)
  .venv/bin/python bridge.py serve     keep running (launchd); see the endpoints below
  .venv/bin/python bridge.py status    print the cameras once and exit
  .venv/bin/python bridge.py archive   copy every clip not yet saved to BLINK_ARCHIVE_DIR, once

Archive (optional): set BLINK_ARCHIVE_DIR to a folder on your NAS and put an empty file named
.mills-blink-archive in it. While serving, every BLINK_ARCHIVE_MIN minutes (default 10) the bridge
copies each new clip to <dir>/<YYYY-MM-DD>/<camera>/<HHMMSS>_<source>_<id>.mp4. It never deletes
anything, in Blink or on the NAS. Without the marker file (NAS not mounted) it writes nothing, so
clips can't silently pile up on the local disk instead.

Endpoints (GET unless noted), port BLINK_BRIDGE_PORT (default 8779):
  /api/blink                    system: cameras, armed state, battery, temps, events, doorbell
  /api/blink/thumb/<camera>     latest snapshot JPEG for a camera
  /api/blink/event/<id>.jpg     thumbnail JPEG for a recent event
  POST /api/blink/snap/<camera> ask the camera for a fresh snapshot (max 1/min/camera; uses battery)
  /api/blink/devices            every device on the account as Blink's homescreen lists it (cameras,
                                Minis/Wired Floodlights, doorbells, sync modules, networks): names,
                                types, network ids, enabled/onboarded, status. No tokens or serials.
  /api/blink/clips?camera=<name>&hours=72&kind=all|motion|doorbell|liveview&offset=0&limit=40
                                clip history, newest first: the NAS archive index plus any recent
                                clip in Blink's cloud not archived yet
  /api/blink/clip/<id>.mp4      the clip itself (from the NAS; HTTP Range, so a player can seek)
  /api/blink/clipthumb/<id>.jpg a thumbnail for a clip: Blink's own, else the clip's first frame
                                (ffmpeg), cached in cache/clipthumbs next to this file

Privacy and safety:
  - Your password is never stored. Only the refresh token and account ids, in blink-token.json (0600).
  - Only clients in BLINK_ALLOW (comma-separated IPs; default: 127.0.0.1 plus the TV) get answers.
  - Read-only: it never arms, disarms, snoozes or changes any Blink setting.
"""

import asyncio
import json
import logging
import os
import re
import stat
import sys
import time
from collections import OrderedDict
from datetime import datetime
from getpass import getpass
from pathlib import Path

from aiohttp import ClientSession, web
from blinkpy.auth import Auth, BlinkTwoFARequiredError
from blinkpy.blinkpy import Blink

HERE = Path(__file__).resolve().parent
TOKEN_FILE = HERE / "blink-token.json"
PORT = int(os.environ.get("BLINK_BRIDGE_PORT", "8779"))
ALLOW = {ip.strip() for ip in os.environ.get("BLINK_ALLOW", "127.0.0.1,<tv-ip>").split(",") if ip.strip()}
REFRESH_SEC = int(os.environ.get("BLINK_REFRESH_SEC", "60"))
EVENT_HOURS = 24
ARCHIVE_DIR = os.environ.get("BLINK_ARCHIVE_DIR", "").strip()
ARCHIVE_MIN = int(os.environ.get("BLINK_ARCHIVE_MIN", "10"))
ARCHIVE_DAYS = int(os.environ.get("BLINK_ARCHIVE_DAYS", "14"))   # how far back each pass looks
MARKER = ".mills-blink-archive"
# Doorbells are detected by class; add any product-type codes yours report (see `bridge.py list`)
DOORBELLS = {s.strip() for s in os.environ.get("BLINK_DOORBELL_TYPES", "").split(",") if s.strip()}
# Optional: an smb:// URL to remount the NAS with (credentials come from the macOS keychain, never from here)
ARCHIVE_MOUNT = os.environ.get("BLINK_ARCHIVE_MOUNT", "").strip()
CACHE = HERE / "cache"
THUMB_CACHE = CACHE / "clipthumbs"
DURATIONS = CACHE / "durations.json"
FFMPEG = os.environ.get("BLINK_FFMPEG", "/opt/homebrew/bin/ffmpeg")
CLIP_ID = re.compile(r"^[0-9]{1,20}$")
FFPROBE = os.environ.get("BLINK_FFPROBE", str(Path(FFMPEG).with_name("ffprobe")))
THUMB_RETRY_SEC = 60   # a clip whose thumbnail couldn't be made yet (brand new in Blink's cloud) is tried again after this
KEEP = ("token", "expires_in", "expiration_date", "refresh_token", "host", "region_id",
        "client_id", "account_id", "user_id", "hardware_id")


# ---- logs never carry account ids or tokens ----
# Blink's API paths hold the account and network ids ("/api/v3/media/accounts/<id>/networks/<id>/…"),
# and blinkpy or aiohttp may log a URL or a login response on an error. Everything this process logs,
# and every error it serves, goes through redact() first.
_REDACT = [
    (re.compile(r"(/(?:accounts?|networks?|users?|clients?|sync_modules?|cameras?|owls?|doorbells?|sedona|catalina|lotus|tulip|mini|superior)/)\d+", re.I), r"\1<id>"),
    (re.compile(r"""(["']?(?:account_id|client_id|user_id|hardware_id|network_id|serial|token|refresh_token|auth_token|access_token|password|unique_id)["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,}&]+)""", re.I), r"\1<redacted>"),
    (re.compile(r"(token-auth|TOKEN_AUTH|Authorization)(\W+)(Bearer\s+)?[\w.\-]+", re.I), r"\1\2<redacted>"),
]


def redact(text):
    s = str(text)
    for rx, rep in _REDACT:
        s = rx.sub(rep, s)
    return s


class RedactFilter(logging.Filter):
    """Rewrites each record (message, arguments and traceback) through redact() before it is written."""
    def filter(self, record):
        try:
            record.msg, record.args = redact(record.getMessage()), None
            if record.exc_info:
                import traceback
                record.exc_text = redact("".join(traceback.format_exception(*record.exc_info)).rstrip())
                record.exc_info = None
            if record.stack_info:
                record.stack_info = redact(record.stack_info)
        except Exception:
            pass
        return True


def setup_logging():
    h = logging.StreamHandler(sys.stderr)
    h.addFilter(RedactFilter())
    h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s", "%Y-%m-%d %H:%M:%S"))
    logging.basicConfig(level=logging.WARNING, handlers=[h], force=True)

    def hook(kind, value, tb):   # a crash's traceback is redacted too
        import traceback
        sys.stderr.write(redact("".join(traceback.format_exception(kind, value, tb))))
    sys.excepthook = hook


def save_tokens(auth: Auth):
    """Write only what's needed to refresh the session: never the password."""
    data = {k: v for k, v in auth.login_attributes.items() if k in KEEP}
    tmp = TOKEN_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
    tmp.replace(TOKEN_FILE)


def thumb_key(url):
    import hashlib
    return hashlib.sha1((url or "").encode()).hexdigest()[:12]


def clip_kind(source):
    """motion (pir, cv_motion), doorbell (a button press), liveview or snapshot."""
    s = (source or "").lower()
    if "button" in s or "press" in s or "ring" in s or "doorbell" in s:
        return "doorbell"
    if "live" in s:
        return "liveview"
    if "snapshot" in s:
        return "snapshot"
    return "motion"


def to_ms(iso):
    try:
        return int(datetime.fromisoformat((iso or "").replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return 0


def norm(name):
    """Blink names can carry a trailing space ("Porch "): match on the trimmed, case-folded name."""
    return (name or "").strip().casefold()


def load_tokens():
    try:
        return json.loads(TOKEN_FILE.read_text())
    except (FileNotFoundError, ValueError):
        return None


async def login():
    print("Sign in to Blink. Your password is used once and never saved.")
    email = input("Blink email: ").strip()
    password = getpass("Blink password: ")
    async with ClientSession() as session:
        blink = Blink(session=session)
        blink.auth = Auth({"username": email, "password": password}, no_prompt=True, session=session)
        try:
            ok = await blink.start()
        except BlinkTwoFARequiredError:
            code = input("Code Blink just sent you (text or email): ").strip()
            ok = await blink.send_2fa_code(code)
        password = None
        if not ok:
            print("Sign-in didn't work. Check the email and password and try again.")
            return 1
        save_tokens(blink.auth)
        print(f"Signed in. Saved session to {TOKEN_FILE.name} (password not stored).")
        for name, cam in blink.cameras.items():
            print(f"  {name:20} {cam.product_type:10} battery {cam.battery}  armed {cam.arm}")
    return 0


class Bridge:
    def __init__(self):
        self.session = None
        self.blink = None
        self.state = {"ok": False, "signedIn": False, "at": 0, "error": "starting", "cameras": [], "events": []}
        self.thumbs = {}        # camera name -> (url, bytes)
        self.event_thumbs = {}  # event id -> url
        self.snap_at = {}       # camera name -> last snap request time
        self.cloud = {}         # event id -> {camera, at, source, media, duration} from Blink's recent list
        self.idx, self.idx_mtime = {}, None   # the NAS archive index, re-read when it changes
        self.mem_clips = OrderedDict()        # event id -> bytes, for clips not on the NAS yet (small LRU)
        self.thumb_sem = asyncio.Semaphore(3)
        self.thumb_miss = {}    # event id -> when its thumbnail last couldn't be made (retried after THUMB_RETRY_SEC)
        self.probe_queue = None # event ids whose length isn't known yet, for probe_loop
        self.probe_front = []   # ...and the ones on the TV's screen right now, measured first
        self.probing = set()
        try:
            self.durations = json.loads(DURATIONS.read_text())
        except (FileNotFoundError, ValueError):
            self.durations = {}
        self.archive = {"enabled": bool(ARCHIVE_DIR), "ok": None, "at": 0, "saved": 0,
                        "total": 0, "pending": 0, "error": None if ARCHIVE_DIR else "BLINK_ARCHIVE_DIR not set"}

    async def connect(self):
        data = load_tokens()
        if not data:
            self.state.update(error="not signed in: run `bridge.py login`", signedIn=False)
            return False
        self.blink = Blink(session=self.session, refresh_rate=REFRESH_SEC)
        self.blink.auth = Auth(data, no_prompt=True, session=self.session,
                               callback=lambda: save_tokens(self.blink.auth))
        try:
            ok = await self.blink.start()
        except BlinkTwoFARequiredError:
            ok = False
        if not ok:
            self.state.update(error="sign-in expired: run `bridge.py login` again", signedIn=False)
            self.blink = None
            return False
        save_tokens(self.blink.auth)
        self.state["signedIn"] = True
        return True

    async def tick(self):
        try:
            if self.blink is None and not await self.connect():
                self.state["ok"] = False
                return
            await self.blink.refresh(force=True)
            cams = []
            for name, cam in self.blink.cameras.items():
                url = cam.thumbnail
                if url and self.thumbs.get(name, (None,))[0] != url:
                    resp = await cam.get_thumbnail()
                    if resp is not None and resp.status == 200:
                        self.thumbs[name] = (url, await resp.read())
                sync = cam.sync
                cams.append({
                    "name": name,
                    "type": cam.product_type,          # Blink product-type code, as reported by the API
                    "doorbell": cam.product_type in DOORBELLS or type(cam).__name__ == "BlinkDoorbell",
                    "online": bool(getattr(cam, "online", True)),
                    "armed": bool(sync.arm) if sync is not None and sync.arm is not None else None,
                    "motionEnabled": cam.motion_enabled,
                    "battery": cam.battery,            # "ok" / "low"
                    "temperatureF": cam.temperature,
                    "wifi": cam.wifi_strength,
                    "lastRecord": cam.last_record[0] if cam.last_record else None,
                    "hasThumb": name in self.thumbs,
                    # changes only when Blink has a new snapshot: the TV re-downloads the picture then, not every poll
                    "thumbKey": thumb_key(self.thumbs[name][0]) if name in self.thumbs else None,
                    "networkId": str(cam.network_id) if cam.network_id else None,
                })
            events = []
            since = time.strftime("%Y/%m/%d %H:%M:%S", time.localtime(time.time() - EVENT_HOURS * 3600))
            for v in await self.blink.get_videos_metadata(since=since, stop=3):
                if v.get("deleted"):
                    continue
                eid = str(v.get("id"))
                if v.get("thumbnail"):
                    self.event_thumbs[eid] = v["thumbnail"]
                src = (v.get("source") or "").lower()
                self.cloud[eid] = {"camera": v.get("device_name"), "at": v.get("created_at"), "source": src,
                                   "media": v.get("media"), "duration": v.get("duration")}
                events.append({
                    "id": eid,
                    "camera": v.get("device_name"),
                    "at": v.get("created_at"),
                    "source": src,                     # pir (motion), button_press (doorbell), liveview, snapshot…
                    "ring": "button" in src or "press" in src or "ring" in src,
                    "summary": (v.get("metadata") or {}).get("description") if isinstance(v.get("metadata"), dict) else None,
                })
            events.sort(key=lambda e: e["at"] or "", reverse=True)
            if len(self.cloud) > 400:
                for k in sorted(self.cloud, key=lambda k: self.cloud[k]["at"] or "")[:-400]:
                    self.cloud.pop(k, None)
            await self.add_clip_stats(cams)
            self.state.update(ok=True, signedIn=True, at=int(time.time() * 1000), error=None,
                              cameras=cams, events=events[:40])
        except Exception as e:  # keep the last good reading, marked by its age
            self.state.update(ok=False, error=redact(e)[:200])

    async def add_clip_stats(self, cams):
        """Per camera: clips today (NAS + cloud, local day) and the last motion or ring, in ms."""
        idx = await self.load_index()
        midnight = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp() * 1000
        today, last = {}, {}
        seen = set()
        for eid, e in list(idx.items()) + [(k, v) for k, v in self.cloud.items() if k not in idx]:
            if eid in seen:
                continue
            seen.add(eid)
            cam, at = norm(e.get("camera")), to_ms(e.get("at"))
            if at >= midnight:
                today[cam] = today.get(cam, 0) + 1
            if clip_kind(e.get("source")) in ("motion", "doorbell") and at > last.get(cam, 0):
                last[cam] = at
        for c in cams:
            c["clipsToday"] = today.get(norm(c["name"]), 0)
            c["lastMotionAt"] = last.get(norm(c["name"])) or None

    async def load_index(self):
        """The archive's .index.json, re-read only when its mtime changes. {} when the NAS is away."""
        if not ARCHIVE_DIR:
            return {}
        f = Path(ARCHIVE_DIR) / ".index.json"
        try:
            m = (await asyncio.to_thread(f.stat)).st_mtime
            if m != self.idx_mtime:
                self.idx = json.loads(await asyncio.to_thread(f.read_text))
                self.idx_mtime = m
        except (OSError, ValueError):
            pass
        return self.idx

    def clip_file(self, eid):
        """The NAS file for an event id, only through the index and only inside the archive."""
        e = self.idx.get(eid)
        if not ARCHIVE_DIR or not e or not e.get("path"):
            return None
        root = Path(ARCHIVE_DIR).resolve()
        p = (root / e["path"]).resolve()
        if root not in p.parents or p.suffix != ".mp4" or not p.is_file():
            return None
        return p

    async def loop(self):
        while True:
            await self.tick()
            await asyncio.sleep(REFRESH_SEC)

    # ---- archive to the NAS ----

    async def archive_pass(self):
        """Copy every clip from the last ARCHIVE_DAYS that isn't on the NAS yet. Never deletes."""
        a = self.archive
        if not ARCHIVE_DIR:
            return a
        root = Path(ARCHIVE_DIR)
        if not (root / MARKER).is_file() and ARCHIVE_MOUNT and time.time() - getattr(self, "mount_tried", 0) > 3600:
            self.mount_tried = time.time()
            proc = await asyncio.create_subprocess_exec(
                "osascript", "-e", f'mount volume "{ARCHIVE_MOUNT}"',
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
            try:
                await asyncio.wait_for(proc.wait(), 60)
            except asyncio.TimeoutError:
                proc.kill()
        if not (root / MARKER).is_file():
            a.update(ok=False, error=f"archive folder not reachable (no {MARKER} in it): is the NAS mounted?")
            return a
        if self.blink is None and not await self.connect():
            a.update(ok=False, error="not signed in")
            return a
        index_file = root / ".index.json"
        try:
            index = json.loads(index_file.read_text())
        except (FileNotFoundError, ValueError):
            index = {}
        since = time.strftime("%Y/%m/%d %H:%M:%S", time.localtime(time.time() - ARCHIVE_DAYS * 86400))
        saved, failed, pending = 0, 0, 0
        try:
            clips = await self.blink.get_videos_metadata(since=since, stop=50)
        except Exception as e:
            a.update(ok=False, error=f"couldn't list clips: {redact(e)[:150]}")
            return a
        for v in clips:
            eid, media = str(v.get("id")), v.get("media")
            if v.get("deleted") or not media or eid in index:
                continue
            pending += 1
            when = (v.get("created_at") or "")[:19].replace("T", " ")
            day, hms = when[:10] or "unknown-date", when[11:19].replace(":", "") or "000000"
            cam = "".join(ch if ch.isalnum() or ch in " -_" else "_" for ch in (v.get("device_name") or "camera")).strip()
            src = "".join(ch for ch in (v.get("source") or "clip").lower() if ch.isalnum() or ch == "_")
            rel = f"{day}/{cam}/{hms}_{src}_{eid}.mp4"
            dest = root / rel
            tmp = dest.with_suffix(".part")
            if dest.is_file() and dest.stat().st_size >= 1024:
                # Already on the NAS (the index lost it): record it, and drop a leftover .part,
                # which SMB refuses to rename over the finished clip ("Resource busy").
                index[eid] = {"path": rel, "bytes": dest.stat().st_size, "camera": v.get("device_name"),
                              "at": v.get("created_at"), "source": v.get("source")}
                tmp.unlink(missing_ok=True)
                pending -= 1
                continue
            try:
                resp = await self.blink.do_http_get(media)
                if resp is None or resp.status != 200:
                    raise RuntimeError(f"HTTP {getattr(resp, 'status', '?')}")
                data = await resp.read()
                if len(data) < 1024:
                    raise RuntimeError("clip came back empty")
                dest.parent.mkdir(parents=True, exist_ok=True)
                tmp.write_bytes(data)
                tmp.replace(dest)
                index[eid] = {"path": rel, "bytes": len(data), "camera": v.get("device_name"),
                              "at": v.get("created_at"), "source": v.get("source")}
                saved += 1
                pending -= 1
                if saved % 10 == 0:
                    self._write_index(index_file, index)
            except Exception as e:
                failed += 1
                a["error"] = f"{rel}: {redact(e)[:120]}"
            await asyncio.sleep(1)   # gentle on Blink's servers
        self._write_index(index_file, index)
        a.update(ok=failed == 0, at=int(time.time() * 1000), saved=a["saved"] + saved,
                 total=len(index), pending=pending)
        if failed == 0:
            a["error"] = None
        print(f"archive: +{saved} saved, {failed} failed, {len(index)} on the NAS", flush=True)
        return a

    @staticmethod
    def _write_index(index_file, index):
        tmp = index_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(index, indent=1))
        tmp.replace(index_file)

    async def archive_loop(self):
        await asyncio.sleep(30)
        while True:
            try:
                await self.archive_pass()
            except Exception as e:
                self.archive.update(ok=False, error=redact(e)[:200])
            await asyncio.sleep(ARCHIVE_MIN * 60)

    # ---- http ----

    @web.middleware
    async def allow_only(self, request, handler):
        if request.remote not in ALLOW:
            return web.Response(status=403, text="not allowed")
        return await handler(request)

    async def h_state(self, request):
        s = dict(self.state)
        s["ageSec"] = int((time.time() * 1000 - s["at"]) / 1000) if s["at"] else None
        s["archive"] = self.archive
        if ARCHIVE_DIR:   # "NAS" for /Volumes/NAS/…: where the clips live, for the TV to say
            parts = Path(ARCHIVE_DIR).parts
            s["archive"] = dict(self.archive, clips=len(self.idx),
                                place=parts[2] if len(parts) > 2 and parts[1] == "Volumes" else Path(ARCHIVE_DIR).name)
        return web.json_response(s, headers={"cache-control": "no-store"})

    async def h_thumb(self, request):
        t = self.thumbs.get(request.match_info["name"])
        if not t:
            return web.Response(status=404)
        tag = f'"{thumb_key(t[0])}"'
        hdr = {"cache-control": "no-cache", "etag": tag}
        if request.headers.get("If-None-Match") == tag:   # the TV already has this snapshot
            return web.Response(status=304, headers=hdr)
        return web.Response(body=t[1], content_type="image/jpeg", headers=hdr)

    async def event_jpeg(self, eid):
        """Blink's own thumbnail for an event. Its metadata gives a path ("/api/v3/media/…"), not a URL."""
        url = self.event_thumbs.get(eid)
        if not url or self.blink is None:
            return None
        try:
            if url.startswith("/"):
                resp = await self.blink.do_http_get(url)
            else:
                cam = next(iter(self.blink.cameras.values()), None)
                resp = await cam.get_thumbnail(url=url) if cam else None
            if resp is not None and resp.status == 200:
                data = await resp.read()
                return data if len(data) > 200 else None
        except Exception:
            pass
        return None

    async def h_event(self, request):
        data = await self.event_jpeg(request.match_info["id"])
        if data is None:
            return web.Response(status=404 if request.match_info["id"] not in self.event_thumbs else 502)
        return web.Response(body=data, content_type="image/jpeg")

    async def h_snap(self, request):
        name = request.match_info["name"]
        cam = self.blink.cameras.get(name) if self.blink else None
        if cam is None:
            return web.json_response({"ok": False, "error": "no such camera"}, status=404)
        if time.time() - self.snap_at.get(name, 0) < 60:
            return web.json_response({"ok": False, "error": "one snapshot a minute per camera"}, status=429)
        self.snap_at[name] = time.time()
        await cam.snap_picture()
        asyncio.get_running_loop().call_later(12, lambda: asyncio.ensure_future(self.tick()))
        return web.json_response({"ok": True, "note": "asked the camera; the new snapshot arrives in ~15 s"})

    async def h_devices(self, request):
        """Everything the account has, as Blink's homescreen lists it. Names and states only."""
        if self.blink is None:
            return web.json_response({"ok": False, "error": self.state.get("error")}, status=503)
        hs = self.blink.homescreen or {}
        in_bridge = {norm(n) for n in self.blink.cameras}

        def dev(d, kind):
            nid = d.get("network_id")
            out = {"kind": kind, "name": d.get("name"), "type": d.get("type"),
                   "networkId": str(nid) if nid is not None else None,
                   "enabled": d.get("enabled"), "onboarded": d.get("onboarded"), "status": d.get("status")}
            if kind in ("camera", "owl", "doorbell"):
                out["inBridge"] = norm(d.get("name")) in in_bridge
            return out

        devices = []
        for key, kind in (("cameras", "camera"), ("owls", "owl"), ("doorbells", "doorbell"),
                          ("sync_modules", "sync module")):
            for d in hs.get(key) or []:
                if isinstance(d, dict):
                    devices.append(dev(d, kind))
        networks = [{"name": n.get("name"), "networkId": str(n.get("id")), "armed": n.get("armed"),
                     "onboarded": (self.blink.networks or {}).get(str(n.get("id")), {}).get("onboarded")}
                    for n in hs.get("networks") or [] if isinstance(n, dict)]
        other = {k: len(v) for k, v in hs.items()
                 if isinstance(v, list) and v and k not in ("cameras", "owls", "doorbells", "sync_modules", "networks")}
        try:   # what blinkpy builds its camera list from: cameras per network ("camera usage")
            from blinkpy import api
            usage = await api.request_camera_usage(self.blink)
            usage = [{"networkId": str(n.get("network_id")), "cameras": [c.get("name") for c in n.get("cameras") or []]}
                     for n in (usage or {}).get("networks") or []]
        except Exception as e:
            usage = f"unavailable: {redact(e)[:80]}"
        return web.json_response({
            "ok": True, "noOwls": bool(self.blink.no_owls),
            "devices": devices, "networks": networks, "otherLists": other, "cameraUsage": usage,
            "bridge": {"cameras": [n for n in self.blink.cameras], "syncModules": list(self.blink.sync),
                       "networkIds": list(self.blink.network_ids)},
            "counts": {k: sum(1 for d in devices if d["kind"] == k) for k in ("camera", "owl", "doorbell", "sync module")},
        }, headers={"cache-control": "no-store"})

    async def h_clips(self, request):
        q = request.query
        cam = norm(q.get("camera"))
        try:
            hours = max(1, min(int(q.get("hours", "72")), 24 * 14))
            offset = max(0, int(q.get("offset", "0")))
            limit = max(1, min(int(q.get("limit", "40")), 200))
        except ValueError:
            return web.json_response({"ok": False, "error": "hours, offset and limit are numbers"}, status=400)
        want = (q.get("kind") or "all").lower()
        idx = await self.load_index()
        since = time.time() * 1000 - hours * 3600_000
        rows = {}
        for eid, e in idx.items():
            at = to_ms(e.get("at"))
            if at >= since and (not cam or norm(e.get("camera")) == cam):
                rows[eid] = {"id": eid, "camera": (e.get("camera") or "").strip(), "atIso": e.get("at"), "at": at,
                             "source": e.get("source"), "archived": True, "bytes": e.get("bytes")}
        for eid, e in self.cloud.items():
            at = to_ms(e.get("at"))
            if eid not in rows and e.get("media") and at >= since and (not cam or norm(e.get("camera")) == cam):
                rows[eid] = {"id": eid, "camera": (e.get("camera") or "").strip(), "atIso": e.get("at"), "at": at,
                             "source": e.get("source"), "archived": False, "bytes": None}
        counts = {"all": 0, "motion": 0, "doorbell": 0, "liveview": 0, "snapshot": 0}
        out = []
        for r in sorted(rows.values(), key=lambda r: r["at"], reverse=True):
            r["kind"] = clip_kind(r["source"])
            counts["all"] += 1
            counts[r["kind"]] += 1
            if want != "all" and r["kind"] != want:
                continue
            d = self.durations.get(r["id"]) or (self.cloud.get(r["id"]) or {}).get("duration")
            r["duration"] = round(float(d), 1) if d else None
            if d is None and r["archived"] and offset <= len(out) < offset + limit:
                self.want_probe(r["id"], front=True)   # shown now: measure it next, so the list has it on its next read
            r["thumb"] = f"/api/blink/clipthumb/{r['id']}.jpg"
            r["url"] = f"/api/blink/clip/{r['id']}.mp4"
            out.append(r)
        page = out[offset:offset + limit]
        return web.json_response({"ok": True, "camera": q.get("camera"), "hours": hours, "kind": want,
                                  "total": len(out), "offset": offset, "counts": counts,
                                  "next": offset + limit if offset + limit < len(out) else None,
                                  "archiveReachable": bool(idx), "clips": page},
                                 headers={"cache-control": "no-store"})

    async def h_clip(self, request):
        eid = request.match_info["id"]
        if not CLIP_ID.match(eid):
            return web.Response(status=404)
        await self.load_index()
        p = self.clip_file(eid)
        if p is not None:   # aiohttp's FileResponse answers Range requests (206) itself
            return web.FileResponse(p, headers={"cache-control": "private, max-age=86400",
                                                "content-type": "video/mp4"})
        media = (self.cloud.get(eid) or {}).get("media")
        if not media or self.blink is None:
            return web.Response(status=404)
        data = await self.cloud_bytes(eid)
        if data is None:
            return web.Response(status=502)
        return self.ranged(request, data, "video/mp4")

    @staticmethod
    def ranged(request, data, ctype):
        size = len(data)
        h = {"accept-ranges": "bytes", "content-type": ctype, "cache-control": "private, max-age=3600"}
        m = re.match(r"bytes=(\d*)-(\d*)$", request.headers.get("Range", ""))
        if not m or (not m.group(1) and not m.group(2)):
            return web.Response(body=data, headers=h)
        if m.group(1):
            start = int(m.group(1))
            end = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
        else:
            start, end = max(0, size - int(m.group(2))), size - 1
        if start >= size or start > end:
            return web.Response(status=416, headers={"content-range": f"bytes */{size}"})
        h["content-range"] = f"bytes {start}-{end}/{size}"
        return web.Response(status=206, body=data[start:end + 1], headers=h)

    async def h_clipthumb(self, request):
        eid = request.match_info["id"]
        if not CLIP_ID.match(eid):
            return web.Response(status=404)
        f = THUMB_CACHE / f"{eid}.jpg"
        hdr = {"cache-control": "private, max-age=86400"}
        if f.is_file():
            return web.Response(body=f.read_bytes(), content_type="image/jpeg", headers=hdr)
        miss = {"cache-control": "no-store", "retry-after": str(THUMB_RETRY_SEC)}
        if time.time() - self.thumb_miss.get(eid, 0) < THUMB_RETRY_SEC:
            return web.Response(status=404, headers=miss)
        async with self.thumb_sem:
            if f.is_file():
                return web.Response(body=f.read_bytes(), content_type="image/jpeg", headers=hdr)
            data = await self.event_jpeg(eid)
            if not data:
                await self.load_index()
                p = self.clip_file(eid)
                if p is not None:
                    data = await self.first_frame(eid, p)
                elif (self.cloud.get(eid) or {}).get("media") and self.blink is not None:
                    data = await self.cloud_first_frame(eid)   # not on the NAS yet: Blink's copy
            if not data or len(data) < 200:
                self.thumb_miss[eid] = time.time()
                if len(self.thumb_miss) > 500:
                    self.thumb_miss = {k: v for k, v in self.thumb_miss.items() if time.time() - v < THUMB_RETRY_SEC}
                return web.Response(status=404, headers=miss)
            self.thumb_miss.pop(eid, None)
            THUMB_CACHE.mkdir(parents=True, exist_ok=True)
            tmp = f.with_suffix(".tmp")
            tmp.write_bytes(data)
            tmp.replace(f)
        return web.Response(body=data, content_type="image/jpeg", headers=hdr)

    async def cloud_bytes(self, eid):
        """A clip still only in Blink's cloud, kept in a small memory LRU (playing it reuses the copy)."""
        data = self.mem_clips.get(eid)
        if data is None:
            media = (self.cloud.get(eid) or {}).get("media")
            resp = await self.blink.do_http_get(media) if media else None
            if resp is None or resp.status != 200:
                return None
            data = await resp.read()
            if len(data) < 1024:
                return None
            self.mem_clips[eid] = data
            while len(self.mem_clips) > 8:
                self.mem_clips.popitem(last=False)
        return data

    async def cloud_first_frame(self, eid):
        import tempfile
        try:
            data = await self.cloud_bytes(eid)
        except Exception:
            return None
        if not data:
            return None
        CACHE.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(suffix=".mp4", dir=str(CACHE))
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(data)
            return await self.first_frame(eid, Path(tmp))
        finally:
            Path(tmp).unlink(missing_ok=True)

    async def first_frame(self, eid, path):
        """A small JPEG of the clip's opening frame; notes the clip's length from ffmpeg on the way."""
        for seek in ("0.5", None):
            args = [FFMPEG, "-hide_banner", "-nostdin"] + (["-ss", seek] if seek else []) + [
                "-i", str(path), "-frames:v", "1", "-vf", "scale=480:-2", "-q:v", "5", "-f", "image2", "-c:v", "mjpeg", "pipe:1"]
            try:
                proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE,
                                                            stderr=asyncio.subprocess.PIPE)
                out, err = await asyncio.wait_for(proc.communicate(), 25)
            except (asyncio.TimeoutError, OSError):
                try:
                    proc.kill()
                except Exception:
                    pass
                return None
            m = re.search(rb"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)", err or b"")
            if m and eid not in self.durations:
                self.durations[eid] = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
                self.save_durations()
            if out:
                return out
        return None

    # ---- clip lengths ----
    # Lengths used to come only from ffmpeg making a thumbnail, so a clip with Blink's own thumbnail
    # never had one. probe_loop reads each archived clip's length with ffprobe (the moov header, a few
    # KB off the NAS), one at a time: clips on screen first, then the rest of the archive, then each new one.

    def want_probe(self, eid, front=False):
        if self.probe_queue is None or eid in self.durations:
            return
        if front:
            if eid not in self.probe_front and len(self.probe_front) < 200:
                self.probe_front.append(eid)
        elif eid not in self.probing:
            self.probing.add(eid)
            self.probe_queue.put_nowait(eid)

    async def probe_loop(self):
        self.probe_queue = asyncio.Queue()
        await asyncio.sleep(20)
        dirty, last_save, last_fill = 0, time.time(), 0
        while True:
            if time.time() - last_fill > 600:   # every 10 min: anything archived without a length joins the queue
                last_fill = time.time()
                for eid in list((await self.load_index()).keys()):
                    self.want_probe(eid)
            if self.probe_front:
                eid = self.probe_front.pop(0)
            else:
                try:
                    eid = await asyncio.wait_for(self.probe_queue.get(), 30)
                except asyncio.TimeoutError:
                    eid = None
            if eid is not None and eid not in self.durations:
                p = self.clip_file(eid)
                d = await self.probe(p) if p is not None else None
                if d:
                    self.durations[eid] = d
                    dirty += 1
                await asyncio.sleep(0.05)   # gentle on the NAS
            self.probing.discard(eid)
            if dirty and (dirty >= 50 or time.time() - last_save > 15):
                await asyncio.to_thread(self.save_durations)
                dirty, last_save = 0, time.time()

    async def probe(self, path):
        try:
            proc = await asyncio.create_subprocess_exec(
                FFPROBE, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path),
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
            out, _ = await asyncio.wait_for(proc.communicate(), 15)
            d = float(out.strip() or 0)
            return round(d, 2) if d > 0 else None
        except (asyncio.TimeoutError, OSError, ValueError):
            try:
                proc.kill()
            except Exception:
                pass
            return None

    def save_durations(self):
        try:
            CACHE.mkdir(parents=True, exist_ok=True)
            tmp = DURATIONS.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.durations))
            tmp.replace(DURATIONS)
        except OSError:
            pass

    async def serve(self):
        self.session = ClientSession()
        app = web.Application(middlewares=[self.allow_only])
        app.add_routes([
            web.get("/api/blink", self.h_state),
            web.get("/api/blink/thumb/{name}", self.h_thumb),
            web.get("/api/blink/event/{id}.jpg", self.h_event),
            web.post("/api/blink/snap/{name}", self.h_snap),
            web.get("/api/blink/devices", self.h_devices),
            web.get("/api/blink/clips", self.h_clips),
            web.get(r"/api/blink/clip/{id:\d+}.mp4", self.h_clip),
            web.get(r"/api/blink/clipthumb/{id:\d+}.jpg", self.h_clipthumb),
        ])
        runner = web.AppRunner(app)
        await runner.setup()
        await web.TCPSite(runner, "0.0.0.0", PORT).start()
        print(f"Blink bridge on :{PORT} (allowing {', '.join(sorted(ALLOW))})", flush=True)
        if ARCHIVE_DIR:
            asyncio.ensure_future(self.archive_loop())
            asyncio.ensure_future(self.probe_loop())
        await self.loop()


async def status():
    b = Bridge()
    b.session = ClientSession()
    await b.tick()
    await b.session.close()
    print(json.dumps({k: v for k, v in b.state.items() if k != "events"} | {"events": b.state["events"][:5]}, indent=2))


async def archive_once():
    b = Bridge()
    b.session = ClientSession()
    print(json.dumps(await b.archive_pass(), indent=2))
    await b.session.close()


if __name__ == "__main__":
    setup_logging()
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "login":
        sys.exit(asyncio.run(login()))
    elif cmd == "serve":
        asyncio.run(Bridge().serve())
    elif cmd == "status":
        asyncio.run(status())
    elif cmd == "archive":
        asyncio.run(archive_once())
    else:
        print(__doc__)
        sys.exit(1)
