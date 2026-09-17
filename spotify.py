#!/usr/bin/env python3
"""Spotify helper for the funcoder.spotify Omarchy plugin.

Runs as a long-lived process (`spotify.py serve`). The shell writes one JSON
request per line to stdin:

    {"id": 7, "op": "playlists", "args": {}}

and gets one JSON line back per request, in whatever order they finish:

    {"id": 7, "data": {...}}      or      {"id": 7, "error": "..."}

Requests run on worker threads so a slow search never stalls the player
poll. Talks to the Spotify Web API with the user's own developer app (PKCE,
no client secret), keeps the refresh token in the desktop keyring, and
manages the local spotifyd playback device.

`spotify.py <op> [json-args]` runs a single request, which is handy for
debugging from a terminal.
"""

import base64
import hashlib
import http.server
import json
import os
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

APP = "funcoder-spotify"
API = "https://api.spotify.com/v1"
AUTH_URL = "https://accounts.spotify.com/authorize"
TOKEN_URL = "https://accounts.spotify.com/api/token"
REDIRECT_PORT = 8989
REDIRECT_URI = f"http://127.0.0.1:{REDIRECT_PORT}/callback"
SCOPES = " ".join([
    "user-read-playback-state",
    "user-modify-playback-state",
    "user-read-currently-playing",
    "user-read-recently-played",
    "user-library-read",
    "user-library-modify",
    "playlist-read-private",
    "playlist-read-collaborative",
])

HOME = os.path.expanduser("~")
CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), APP)
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"), APP)
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")
SPOTIFYD_CONF = os.path.join(CONFIG_DIR, "spotifyd.conf")
SPOTIFYD_CACHE = os.path.join(CACHE_DIR, "spotifyd")
UNIT_NAME = "funcoder-spotifyd.service"
UNIT_PATH = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "systemd", "user", UNIT_NAME)
DEFAULT_DEVICE_NAME = "Omarchy"


class ApiError(Exception):
    def __init__(self, message, status=0):
        super().__init__(message)
        self.status = status


# ---------------------------------------------------------------- config

_config_lock = threading.Lock()


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_config(data):
    with _config_lock:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        tmp = CONFIG_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, CONFIG_PATH)


def client_id():
    return str(load_config().get("clientId") or "").strip()


def device_name():
    return str(load_config().get("deviceName") or DEFAULT_DEVICE_NAME).strip() or DEFAULT_DEVICE_NAME


# ---------------------------------------------------------------- keyring


def keyring_lookup(cid):
    if not cid or not shutil.which("secret-tool"):
        return ""
    try:
        out = subprocess.run(["secret-tool", "lookup", "service", APP, "client", cid],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def keyring_store(cid, token):
    if not shutil.which("secret-tool"):
        raise ApiError("secret-tool is missing, so the Spotify login can't be saved")
    out = subprocess.run(["secret-tool", "store", "--label", "Spotify (Omarchy)", "service", APP, "client", cid],
                         input=token, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise ApiError("Couldn't save the Spotify login to the keyring: " + (out.stderr.strip() or "unknown error"))


def keyring_clear(cid):
    if cid and shutil.which("secret-tool"):
        subprocess.run(["secret-tool", "clear", "service", APP, "client", cid],
                       capture_output=True, timeout=10)


# ---------------------------------------------------------------- tokens

_token_lock = threading.Lock()
_token = {"access": "", "expires": 0.0, "client": ""}
_login_lock = threading.Lock()


def _token_request(fields):
    body = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(TOKEN_URL, data=body, method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read().decode())
            msg = detail.get("error_description") or detail.get("error") or str(e)
        except ValueError:
            msg = str(e)
        raise ApiError("Spotify login failed: " + msg, e.code)
    except urllib.error.URLError as e:
        raise ApiError("Can't reach Spotify: " + str(e.reason))


def access_token():
    cid = client_id()
    if not cid:
        raise ApiError("Add your Spotify app client ID first", 401)
    with _token_lock:
        if _token["access"] and _token["client"] == cid and time.time() < _token["expires"] - 60:
            return _token["access"]
        refresh = keyring_lookup(cid)
        if not refresh:
            raise ApiError("Log in to Spotify first", 401)
        data = _token_request({"grant_type": "refresh_token", "refresh_token": refresh, "client_id": cid})
        if data.get("refresh_token") and data["refresh_token"] != refresh:
            keyring_store(cid, data["refresh_token"])
        _token.update(access=data["access_token"], expires=time.time() + int(data.get("expires_in", 3600)), client=cid)
        return _token["access"]


def forget_token():
    with _token_lock:
        _token.update(access="", expires=0.0, client="")


# ---------------------------------------------------------------- api


def api(method, path, params=None, body=None, retry=True):
    url = path if path.startswith("http") else API + path
    if params:
        clean = {k: v for k, v in params.items() if v is not None}
        if clean:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(clean)
    data = json.dumps(body).encode() if body is not None else (b"" if method in ("PUT", "POST") else None)
    headers = {"Authorization": "Bearer " + access_token()}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode()
            if not raw.strip():
                return None
            try:
                return json.loads(raw)
            except ValueError:
                return None
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        if e.code == 401 and retry:
            forget_token()
            return api(method, path, params, body, retry=False)
        if e.code == 429 and retry:
            wait = min(10, int(e.headers.get("Retry-After") or 2))
            time.sleep(wait)
            return api(method, path, params, body, retry=False)
        msg = ""
        try:
            detail = json.loads(raw)
            err = detail.get("error")
            msg = err.get("message") if isinstance(err, dict) else str(err or "")
        except ValueError:
            pass
        if e.code == 404 and "device" in (msg or "").lower():
            msg = "No active Spotify device. Start this computer's player or pick a device"
        elif e.code == 403 and "premium" in (msg or "").lower():
            msg = "Spotify Premium is required for playback control"
        raise ApiError(msg or f"Spotify returned {e.code}", e.code)
    except urllib.error.URLError as e:
        raise ApiError("Can't reach Spotify: " + str(e.reason))


def paged(path, params, max_items):
    items = []
    url = path
    first = True
    while url and len(items) < max_items:
        page = api("GET", url, params if first else None) or {}
        first = False
        items.extend(page.get("items") or [])
        url = page.get("next")
    return items[:max_items]


# ---------------------------------------------------------------- shaping


def pick_image(images, target=300):
    images = [i for i in (images or []) if i and i.get("url")]
    if not images:
        return ""
    # Smallest image at least `target` px wide, else the largest there is.
    sized = sorted(images, key=lambda i: i.get("width") or 0)
    for img in sized:
        if (img.get("width") or 0) >= target:
            return img["url"]
    return sized[-1]["url"]


def shape_track(t):
    if not t:
        return None
    kind = t.get("type") or "track"
    if kind == "episode":
        show = t.get("show") or {}
        return {
            "type": "episode", "id": t.get("id") or "", "uri": t.get("uri") or "",
            "name": t.get("name") or "", "artist": show.get("name") or "",
            "album": show.get("name") or "", "albumUri": show.get("uri") or "",
            "duration": t.get("duration_ms") or 0,
            "image": pick_image(t.get("images") or show.get("images"), 640),
            "thumb": pick_image(t.get("images") or show.get("images"), 64),
        }
    album = t.get("album") or {}
    return {
        "type": "track", "id": t.get("id") or "", "uri": t.get("uri") or "",
        "name": t.get("name") or "",
        "artist": ", ".join(a.get("name", "") for a in t.get("artists") or []),
        "album": album.get("name") or "", "albumUri": album.get("uri") or "",
        "duration": t.get("duration_ms") or 0,
        "image": pick_image(album.get("images"), 640),
        "thumb": pick_image(album.get("images"), 64),
        "playable": t.get("is_playable", True) is not False,
    }


def shape_playlist(p, me=""):
    if not p:
        return None
    owner = p.get("owner") or {}
    tracks = p.get("items") if isinstance(p.get("items"), dict) else (p.get("tracks") or {})
    return {
        "type": "playlist", "id": p.get("id") or "", "uri": p.get("uri") or "",
        "name": p.get("name") or "", "owner": owner.get("display_name") or owner.get("id") or "",
        "mine": bool(me) and owner.get("id") == me,
        "collaborative": bool(p.get("collaborative")),
        "total": (tracks or {}).get("total") or 0,
        "image": pick_image(p.get("images"), 300),
        "thumb": pick_image(p.get("images"), 64),
        "description": p.get("description") or "",
    }


def shape_device(d):
    return {
        "id": d.get("id") or "", "name": d.get("name") or "", "type": d.get("type") or "",
        "active": bool(d.get("is_active")), "volume": d.get("volume_percent"),
        "restricted": bool(d.get("is_restricted")),
        "supportsVolume": d.get("supports_volume", True) is not False,
    }


# ---------------------------------------------------------------- ops

_me = {"id": "", "name": ""}


def me():
    if not _me["id"]:
        data = api("GET", "/me") or {}
        _me.update(id=data.get("id") or "", name=data.get("display_name") or data.get("id") or "")
    return dict(_me)


def op_status(_):
    cid = client_id()
    logged_in = bool(cid and keyring_lookup(cid))
    return {
        "clientId": cid,
        "loggedIn": logged_in,
        "redirectUri": REDIRECT_URI,
        "configDir": CONFIG_DIR,
        "deviceName": device_name(),
        "local": local_status(),
        "cava": bool(shutil.which("cava")),
    }


def op_set_client_id(args):
    cid = str(args.get("clientId") or "").strip()
    if cid and (len(cid) != 32 or any(c not in "0123456789abcdef" for c in cid.lower())):
        raise ApiError("That doesn't look like a Spotify client ID (32 hex characters)")
    cfg = load_config()
    old = str(cfg.get("clientId") or "")
    cfg["clientId"] = cid
    save_config(cfg)
    if old != cid:
        forget_token()
        _me.update(id="", name="")
    return op_status({})


def op_login(_):
    cid = client_id()
    if not cid:
        raise ApiError("Add your Spotify app client ID first")
    if not _login_lock.acquire(blocking=False):
        raise ApiError("A login is already waiting in your browser")
    try:
        verifier = base64.urlsafe_b64encode(secrets.token_bytes(64)).rstrip(b"=").decode()
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        state = secrets.token_urlsafe(24)
        result = {}
        done = threading.Event()

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                parsed = urllib.parse.urlparse(self.path)
                if parsed.path != "/callback":
                    self.send_response(404)
                    self.end_headers()
                    return
                q = urllib.parse.parse_qs(parsed.query)
                if q.get("state", [""])[0] != state:
                    result["error"] = "Login state mismatch, try again"
                elif "error" in q:
                    result["error"] = "Spotify said: " + q["error"][0]
                else:
                    result["code"] = q.get("code", [""])[0]
                ok = "code" in result
                page = ("<html><body style='font-family:monospace;background:#111;color:#ddd;"
                        "display:flex;height:100vh;align-items:center;justify-content:center'>"
                        f"<div><h2>{'Spotify connected' if ok else 'Login failed'}</h2>"
                        f"<p>{'You can close this tab and go back to Omarchy.' if ok else result.get('error', '')}</p>"
                        "</div></body></html>").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(page)
                done.set()

        try:
            server = http.server.HTTPServer(("127.0.0.1", REDIRECT_PORT), Handler)
        except OSError:
            raise ApiError(f"Port {REDIRECT_PORT} is busy, so the login can't finish")
        server.timeout = 1
        url = AUTH_URL + "?" + urllib.parse.urlencode({
            "client_id": cid, "response_type": "code", "redirect_uri": REDIRECT_URI,
            "code_challenge_method": "S256", "code_challenge": challenge,
            "scope": SCOPES, "state": state,
        })
        subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 300
        try:
            while not done.is_set() and time.time() < deadline:
                server.handle_request()
        finally:
            server.server_close()
        if not done.is_set():
            raise ApiError("Login timed out")
        if "error" in result:
            raise ApiError(result["error"])
        data = _token_request({
            "grant_type": "authorization_code", "code": result["code"],
            "redirect_uri": REDIRECT_URI, "client_id": cid, "code_verifier": verifier,
        })
        keyring_store(cid, data["refresh_token"])
        with _token_lock:
            _token.update(access=data["access_token"], expires=time.time() + int(data.get("expires_in", 3600)), client=cid)
        _me.update(id="", name="")
        return op_status({})
    finally:
        _login_lock.release()


def op_logout(_):
    keyring_clear(client_id())
    forget_token()
    _me.update(id="", name="")
    return op_status({})


def op_player(_):
    data = api("GET", "/me/player", {"additional_types": "episode"})
    if not data:
        return {"active": False}
    ctx = data.get("context") or {}
    return {
        "active": True,
        "playing": bool(data.get("is_playing")),
        "progress": data.get("progress_ms") or 0,
        "shuffle": bool(data.get("shuffle_state")),
        "repeat": data.get("repeat_state") or "off",
        "device": shape_device(data.get("device") or {}),
        "contextUri": ctx.get("uri") or "",
        "contextType": ctx.get("type") or "",
        "item": shape_track(data.get("item")),
        "timestamp": time.time() * 1000,
    }


def op_me(_):
    return me()


def op_playlists(_):
    user = me()
    items = paged("/me/playlists", {"limit": 50}, 1000)
    return {"items": [shape_playlist(p, user["id"]) for p in items if p]}


def op_playlist(args):
    pid = str(args.get("id") or "")
    if not pid:
        raise ApiError("Missing playlist id")
    user = me()
    meta = api("GET", f"/playlists/{pid}") or {}
    playlist = shape_playlist(meta, user["id"])
    # Development-mode apps only get track listings for playlists the user
    # owns or collaborates on; others answer without "items".
    tracks, restricted = [], False
    try:
        page = api("GET", f"/playlists/{pid}/items", {"limit": 100, "additional_types": "track,episode"}) or {}
        if "items" not in page:
            restricted = True
        else:
            rows = list(page.get("items") or [])
            url = page.get("next")
            while url and len(rows) < 1000:
                page = api("GET", url) or {}
                rows.extend(page.get("items") or [])
                url = page.get("next")
            for row in rows:
                t = shape_track(row.get("item") or row.get("track"))
                if t and t["uri"]:
                    tracks.append(t)
    except ApiError as e:
        if e.status in (403, 404):
            restricted = True
        else:
            raise
    return {"playlist": playlist, "tracks": tracks, "restricted": restricted}


def op_liked(_):
    rows = paged("/me/tracks", {"limit": 50}, 500)
    return {"items": [t for t in (shape_track(r.get("track")) for r in rows) if t]}


def op_recent(_):
    data = api("GET", "/me/player/recently-played", {"limit": 50}) or {}
    seen, items = set(), []
    for row in data.get("items") or []:
        t = shape_track(row.get("track"))
        if t and t["uri"] not in seen:
            seen.add(t["uri"])
            ctx = row.get("context") or {}
            t["contextUri"] = ctx.get("uri") or ""
            items.append(t)
    return {"items": items}


def op_queue(_):
    data = api("GET", "/me/player/queue") or {}
    return {
        "current": shape_track(data.get("currently_playing")),
        "items": [t for t in (shape_track(x) for x in data.get("queue") or []) if t],
    }


def op_search(args):
    q = str(args.get("q") or "").strip()
    if not q:
        return {"tracks": [], "playlists": [], "albums": [], "artists": []}
    data = api("GET", "/search", {"q": q, "type": "track,playlist,album,artist", "limit": 10}) or {}
    user_id = _me["id"]

    def shape_album(a):
        return {"type": "album", "id": a.get("id") or "", "uri": a.get("uri") or "", "name": a.get("name") or "",
                "owner": ", ".join(x.get("name", "") for x in a.get("artists") or []),
                "total": a.get("total_tracks") or 0,
                "image": pick_image(a.get("images"), 300), "thumb": pick_image(a.get("images"), 64)}

    def shape_artist(a):
        return {"type": "artist", "id": a.get("id") or "", "uri": a.get("uri") or "", "name": a.get("name") or "",
                "owner": "Artist", "image": pick_image(a.get("images"), 300), "thumb": pick_image(a.get("images"), 64)}

    def items(key):
        return [x for x in ((data.get(key) or {}).get("items") or []) if x]

    return {
        "tracks": [shape_track(t) for t in items("tracks")],
        "playlists": [shape_playlist(p, user_id) for p in items("playlists")],
        "albums": [shape_album(a) for a in items("albums")],
        "artists": [shape_artist(a) for a in items("artists")],
    }


def op_album(args):
    aid = str(args.get("id") or "")
    album = api("GET", f"/albums/{aid}") or {}
    rows = list((album.get("tracks") or {}).get("items") or [])
    url = (album.get("tracks") or {}).get("next")
    while url:
        page = api("GET", url) or {}
        rows.extend(page.get("items") or [])
        url = page.get("next")
    for r in rows:
        r["album"] = {"name": album.get("name"), "uri": album.get("uri"), "images": album.get("images")}
    return {
        "playlist": {"type": "album", "id": aid, "uri": album.get("uri") or "", "name": album.get("name") or "",
                     "owner": ", ".join(a.get("name", "") for a in album.get("artists") or []),
                     "total": album.get("total_tracks") or len(rows),
                     "image": pick_image(album.get("images"), 300), "thumb": pick_image(album.get("images"), 64)},
        "tracks": [t for t in (shape_track(r) for r in rows) if t],
        "restricted": False,
    }


def op_devices(_):
    data = api("GET", "/me/player/devices") or {}
    return {"items": [shape_device(d) for d in data.get("devices") or []], "localName": device_name()}


def find_device_id(prefer_local=True):
    """An id to play on when nothing is active: this computer if it's online."""
    data = api("GET", "/me/player/devices") or {}
    devices = data.get("devices") or []
    for d in devices:
        if d.get("is_active"):
            return None
    name = device_name().lower()
    if prefer_local:
        for d in devices:
            if (d.get("name") or "").lower() == name:
                return d.get("id")
    return devices[0].get("id") if devices else None


def with_device(fn):
    """Runs a player command, retrying on this computer if no device is active."""
    try:
        return fn(None)
    except ApiError as e:
        if e.status != 404:
            raise
        device = find_device_id()
        if not device:
            if local_status().get("installed") and not local_status().get("running"):
                local_start()
                for _ in range(20):
                    time.sleep(0.5)
                    device = find_device_id()
                    if device:
                        break
            if not device:
                raise ApiError("No Spotify device is available. Start this computer's player in Devices (d)")
        return fn(device)


def op_play(args):
    body = {}
    if args.get("contextUri"):
        body["context_uri"] = args["contextUri"]
        if args.get("offsetUri"):
            body["offset"] = {"uri": args["offsetUri"]}
        elif args.get("offset") is not None:
            body["offset"] = {"position": int(args["offset"])}
    elif args.get("uris"):
        body["uris"] = list(args["uris"])[:100]
        if args.get("offsetUri"):
            body["offset"] = {"uri": args["offsetUri"]}
    target = args.get("deviceId")
    with_device(lambda dev: api("PUT", "/me/player/play", {"device_id": target or dev}, body or None))
    return {"ok": True}


def simple(method, path, params_fn=None):
    def run(args):
        params = params_fn(args) if params_fn else {}
        with_device(lambda dev: api(method, path, dict(params, device_id=dev) if dev else params))
        return {"ok": True}
    return run


def op_transfer(args):
    api("PUT", "/me/player", body={"device_ids": [args["deviceId"]], "play": bool(args.get("play", True))})
    return {"ok": True}


def op_queue_add(args):
    with_device(lambda dev: api("POST", "/me/player/queue", {"uri": args["uri"], "device_id": dev}))
    return {"ok": True}


def op_saved(args):
    uris = [u for u in (args.get("uris") or []) if u][:40]
    if not uris:
        return {"saved": {}}
    data = api("GET", "/me/library/contains", {"uris": ",".join(uris)}) or []
    return {"saved": {u: bool(v) for u, v in zip(uris, data)}}


def op_like(args):
    uri = args.get("uri")
    method = "PUT" if args.get("save", True) else "DELETE"
    api(method, "/me/library", {"uris": uri})
    return {"saved": {uri: method == "PUT"}}


# ---------------------------------------------------------------- local device (spotifyd)


def spotifyd_bin():
    return shutil.which("spotifyd") or ""


def local_credentials():
    return os.path.isfile(os.path.join(SPOTIFYD_CACHE, "oauth", "credentials.json"))


def systemctl(*args, timeout=15):
    try:
        return subprocess.run(["systemctl", "--user", *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        return subprocess.CompletedProcess(args, 1, "", str(e))


def local_status():
    binary = spotifyd_bin()
    return {
        "installed": bool(binary),
        "authenticated": local_credentials(),
        "configured": os.path.isfile(UNIT_PATH) and os.path.isfile(SPOTIFYD_CONF),
        "running": systemctl("is-active", "--quiet", UNIT_NAME).returncode == 0,
        "name": device_name(),
    }


def write_local_config():
    binary = spotifyd_bin()
    if not binary:
        raise ApiError("spotifyd isn't installed. Run: sudo pacman -S spotifyd")
    os.makedirs(CONFIG_DIR, exist_ok=True)
    os.makedirs(SPOTIFYD_CACHE, exist_ok=True)
    name = device_name().replace('"', "")
    conf = (
        "# Written by the funcoder.spotify Omarchy plugin.\n"
        "[global]\n"
        f'device_name = "{name}"\n'
        'device_type = "computer"\n'
        'backend = "pulseaudio"\n'
        "bitrate = 320\n"
        f'cache_path = "{SPOTIFYD_CACHE}"\n'
        "max_cache_size = 1000000000\n"
        "initial_volume = 70\n"
        "volume_normalisation = true\n"
        "use_mpris = true\n"
        'dbus_type = "session"\n'
        "disable_discovery = true\n"
    )
    with open(SPOTIFYD_CONF, "w") as f:
        f.write(conf)
    unit = (
        "[Unit]\n"
        "Description=Spotify playback for Omarchy (funcoder.spotify)\n"
        "Wants=network-online.target\n"
        "After=network-online.target pipewire-pulse.service\n\n"
        "[Service]\n"
        f"ExecStart={binary} --no-daemon --config-path {SPOTIFYD_CONF}\n"
        "Restart=on-failure\n"
        "RestartSec=5\n\n"
        "[Install]\n"
        "WantedBy=default.target\n"
    )
    os.makedirs(os.path.dirname(UNIT_PATH), exist_ok=True)
    old = ""
    try:
        with open(UNIT_PATH) as f:
            old = f.read()
    except OSError:
        pass
    if old != unit:
        with open(UNIT_PATH, "w") as f:
            f.write(unit)
    systemctl("daemon-reload")


def local_start():
    write_local_config()
    if not local_credentials():
        raise ApiError("Connect this computer to Spotify first (Enter on the setup step)")
    out = systemctl("restart", UNIT_NAME)
    if out.returncode != 0:
        raise ApiError("spotifyd didn't start: " + (out.stderr.strip() or "see journalctl --user -u " + UNIT_NAME))


def op_local_status(_):
    return local_status()


def op_local_auth(_):
    write_local_config()
    # Opens the browser and waits for the redirect, then caches credentials
    # under cache_path/oauth.
    try:
        out = subprocess.run([spotifyd_bin(), "authenticate", "--config-path", SPOTIFYD_CONF],
                             capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        raise ApiError("Timed out waiting for the Spotify login in your browser")
    if not local_credentials():
        tail = (out.stderr or out.stdout or "").strip().splitlines()[-1:] or ["no credentials were saved"]
        raise ApiError("This computer couldn't connect: " + tail[0])
    local_start()
    return local_status()


def op_local_start(_):
    local_start()
    return local_status()


def op_local_stop(_):
    systemctl("stop", UNIT_NAME)
    return local_status()


def op_set_device_name(args):
    name = str(args.get("name") or "").strip()[:60]
    cfg = load_config()
    cfg["deviceName"] = name or DEFAULT_DEVICE_NAME
    save_config(cfg)
    if spotifyd_bin():
        write_local_config()
        if local_status()["running"]:
            systemctl("restart", UNIT_NAME)
    return local_status()


def op_cava_config(args):
    bars = max(4, min(128, int(args.get("bars") or 48)))
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = os.path.join(CACHE_DIR, "cava.conf")
    with open(path, "w") as f:
        f.write(
            "# Written by the funcoder.spotify Omarchy plugin.\n"
            "[general]\n"
            f"bars = {bars}\n"
            "framerate = 45\n"
            "autosens = 1\n"
            "sleep_timer = 0\n"
            "[input]\n"
            "method = pipewire\n"
            "source = auto\n"
            "[output]\n"
            "method = raw\n"
            "raw_target = /dev/stdout\n"
            "data_format = ascii\n"
            "ascii_max_range = 1000\n"
            "bar_delimiter = 59\n"
            "frame_delimiter = 10\n"
            "channels = mono\n"
            "[smoothing]\n"
            "noise_reduction = 55\n"
        )
    return {"path": path, "cava": shutil.which("cava") or ""}


def op_open_url(args):
    subprocess.Popen(["xdg-open", str(args.get("url") or "")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"ok": True}


OPS = {
    "status": op_status,
    "set_client_id": op_set_client_id,
    "login": op_login,
    "logout": op_logout,
    "me": op_me,
    "player": op_player,
    "playlists": op_playlists,
    "playlist": op_playlist,
    "album": op_album,
    "liked": op_liked,
    "recent": op_recent,
    "queue": op_queue,
    "search": op_search,
    "devices": op_devices,
    "play": op_play,
    "pause": simple("PUT", "/me/player/pause"),
    "resume": simple("PUT", "/me/player/play"),
    "next": simple("POST", "/me/player/next"),
    "previous": simple("POST", "/me/player/previous"),
    "seek": simple("PUT", "/me/player/seek", lambda a: {"position_ms": max(0, int(a.get("position", 0)))}),
    "volume": simple("PUT", "/me/player/volume", lambda a: {"volume_percent": max(0, min(100, int(a.get("volume", 50))))}),
    "shuffle": simple("PUT", "/me/player/shuffle", lambda a: {"state": "true" if a.get("state") else "false"}),
    "repeat": simple("PUT", "/me/player/repeat", lambda a: {"state": a.get("state") if a.get("state") in ("off", "context", "track") else "off"}),
    "transfer": op_transfer,
    "queue_add": op_queue_add,
    "saved": op_saved,
    "like": op_like,
    "local_status": op_local_status,
    "local_auth": op_local_auth,
    "local_start": op_local_start,
    "local_stop": op_local_stop,
    "set_device_name": op_set_device_name,
    "cava_config": op_cava_config,
    "open_url": op_open_url,
}


def handle(op, args):
    if load_config().get("demo") and op not in ("cava_config", "open_url"):
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
        import demo
        return demo.handle(op, args or {})
    fn = OPS.get(op)
    if not fn:
        raise ApiError("Unknown request: " + str(op))
    return fn(args or {})


# ---------------------------------------------------------------- server

_out_lock = threading.Lock()


def emit(obj):
    line = json.dumps(obj, separators=(",", ":"))
    with _out_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def serve_one(req):
    rid = req.get("id")
    try:
        emit({"id": rid, "data": handle(req.get("op"), req.get("args"))})
    except ApiError as e:
        emit({"id": rid, "error": str(e), "status": e.status})
    except Exception as e:  # never let one request kill the helper
        emit({"id": rid, "error": f"{type(e).__name__}: {e}"})


def serve():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        threading.Thread(target=serve_one, args=(req,), daemon=True).start()


def main(argv):
    if len(argv) < 2 or argv[1] == "serve":
        serve()
        return 0
    args = json.loads(argv[2]) if len(argv) > 2 else {}
    try:
        print(json.dumps(handle(argv[1], args), indent=2))
        return 0
    except ApiError as e:
        print(json.dumps({"error": str(e), "status": e.status}))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
