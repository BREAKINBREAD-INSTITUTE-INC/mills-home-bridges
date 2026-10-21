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

Privacy and safety:
  - Your password is never stored. Only the refresh token and account ids, in blink-token.json (0600).
  - Only clients in BLINK_ALLOW (comma-separated IPs; default: 127.0.0.1 plus the TV) get answers.
  - Read-only: it never arms, disarms, snoozes or changes any Blink setting.
"""

import asyncio
import json
import os
import stat
import sys
import time
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
KEEP = ("token", "expires_in", "expiration_date", "refresh_token", "host", "region_id",
        "client_id", "account_id", "user_id", "hardware_id")


def save_tokens(auth: Auth):
    """Write only what's needed to refresh the session: never the password."""
    data = {k: v for k, v in auth.login_attributes.items() if k in KEEP}
    tmp = TOKEN_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
    tmp.replace(TOKEN_FILE)


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
                events.append({
                    "id": eid,
                    "camera": v.get("device_name"),
                    "at": v.get("created_at"),
                    "source": src,                     # pir (motion), button_press (doorbell), liveview, snapshot…
                    "ring": "button" in src or "press" in src or "ring" in src,
                    "summary": (v.get("metadata") or {}).get("description") if isinstance(v.get("metadata"), dict) else None,
                })
            events.sort(key=lambda e: e["at"] or "", reverse=True)
            self.state.update(ok=True, signedIn=True, at=int(time.time() * 1000), error=None,
                              cameras=cams, events=events[:40])
        except Exception as e:  # keep the last good reading, marked by its age
            self.state.update(ok=False, error=str(e)[:200])

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
            a.update(ok=False, error=f"couldn't list clips: {str(e)[:150]}")
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
                a["error"] = f"{rel}: {str(e)[:120]}"
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
                self.archive.update(ok=False, error=str(e)[:200])
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
        return web.json_response(s, headers={"cache-control": "no-store"})

    async def h_thumb(self, request):
        t = self.thumbs.get(request.match_info["name"])
        if not t:
            return web.Response(status=404)
        return web.Response(body=t[1], content_type="image/jpeg", headers={"cache-control": "no-store"})

    async def h_event(self, request):
        url = self.event_thumbs.get(request.match_info["id"])
        if not url or self.blink is None:
            return web.Response(status=404)
        cam = next(iter(self.blink.cameras.values()), None)
        resp = await cam.get_thumbnail(url=url) if cam else None
        if resp is None or resp.status != 200:
            return web.Response(status=502)
        return web.Response(body=await resp.read(), content_type="image/jpeg")

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

    async def serve(self):
        self.session = ClientSession()
        app = web.Application(middlewares=[self.allow_only])
        app.add_routes([
            web.get("/api/blink", self.h_state),
            web.get("/api/blink/thumb/{name}", self.h_thumb),
            web.get("/api/blink/event/{id}.jpg", self.h_event),
            web.post("/api/blink/snap/{name}", self.h_snap),
        ])
        runner = web.AppRunner(app)
        await runner.setup()
        await web.TCPSite(runner, "0.0.0.0", PORT).start()
        print(f"Blink bridge on :{PORT} (allowing {', '.join(sorted(ALLOW))})", flush=True)
        if ARCHIVE_DIR:
            asyncio.ensure_future(self.archive_loop())
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
