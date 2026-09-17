"""Fake Spotify data for trying the UI without an account.

Enable with `"demo": true` in ~/.config/funcoder-spotify/config.json (then
restart the shell). Artwork comes from the installed Omarchy theme
backgrounds, so it exercises the duotone shader with real images.
"""

import glob
import os
import time

_imgs = sorted(glob.glob(os.path.expanduser("~/.local/share/omarchy/themes/*/backgrounds/*.[jp][pn]g")))
_imgs = ["file://" + p for p in _imgs if "omarchy.png" not in p] or [""]

NAMES = [("Night Drive", "Neon Harbor"), ("Glass Rivers", "Lumen"), ("Tokyo Rain", "Hikari"),
         ("Low Orbit", "Satellite Kids"), ("Paper Moons", "Fern & Wire"), ("Afterglow", "Kestrel"),
         ("Cold Coffee", "Late Shift"), ("Static Bloom", "Omnia"), ("Terminal Velocity", "Bashful"),
         ("Hyprland", "Tiling Order"), ("Soft Focus", "Quiet Hours"), ("Waveform", "Delta Sun")]

state = {"playing": True, "index": 0, "started": time.time(), "offset": 0, "shuffle": False, "repeat": "off", "volume": 64}


def track(i):
    name, artist = NAMES[i % len(NAMES)]
    img = _imgs[i % len(_imgs)]
    return {"type": "track", "id": f"t{i}", "uri": f"spotify:track:demo{i}", "name": name, "artist": artist,
            "album": artist + " Sessions", "albumUri": f"spotify:album:demo{i % 4}", "duration": 185000 + i * 7300,
            "image": img, "thumb": img, "playable": True}


PLAYLISTS = [
    {"type": "playlist", "id": f"p{i}", "uri": f"spotify:playlist:demo{i}", "name": n, "owner": o, "mine": o == "funcoder",
     "collaborative": False, "total": 12 + i * 9, "image": _imgs[(i + 3) % len(_imgs)], "thumb": _imgs[(i + 3) % len(_imgs)], "description": ""}
    for i, (n, o) in enumerate([("Deep Focus Coding", "funcoder"), ("Synthwave Nights", "funcoder"), ("Discover Weekly", "Spotify"),
                                ("Lo-fi Beats", "Spotify"), ("Road Trip", "funcoder"), ("Morning Coffee", "a friend")])
]


def progress():
    p = state["offset"] + ((time.time() - state["started"]) * 1000 if state["playing"] else 0)
    dur = track(state["index"])["duration"]
    if p >= dur:
        state["index"] += 1
        state["offset"], state["started"] = 0, time.time()
        p = 0
    return p


def handle(op, args):
    if op == "status":
        return {"clientId": "demo", "loggedIn": True, "redirectUri": "http://127.0.0.1:19872/login", "configDir": "",
                "deviceName": "Omarchy", "local": {"installed": True, "authenticated": True, "configured": True, "running": True, "name": "Omarchy"},
                "cava": bool(__import__("shutil").which("cava"))}
    if op == "player":
        return {"active": True, "playing": state["playing"], "progress": progress(), "shuffle": state["shuffle"], "repeat": state["repeat"],
                "device": {"id": "d1", "name": "Omarchy", "type": "Computer", "active": True, "volume": state["volume"], "restricted": False, "supportsVolume": True},
                "contextUri": PLAYLISTS[1]["uri"], "contextType": "playlist", "item": track(state["index"]), "timestamp": time.time() * 1000}
    if op in ("pause", "resume"):
        state["offset"] = progress()
        state["started"] = time.time()
        state["playing"] = op == "resume"
    elif op in ("next", "previous", "play"):
        state["index"] = max(0, state["index"] + (-1 if op == "previous" else 1))
        state["offset"], state["started"], state["playing"] = 0, time.time(), True
    elif op == "seek":
        state["offset"], state["started"] = int(args.get("position", 0)), time.time()
    elif op == "volume":
        state["volume"] = int(args.get("volume", 50))
    elif op == "shuffle":
        state["shuffle"] = bool(args.get("state"))
    elif op == "repeat":
        state["repeat"] = args.get("state") or "off"
    elif op == "playlists":
        return {"items": PLAYLISTS}
    elif op in ("playlist", "album"):
        pid = args.get("id")
        pl = next((p for p in PLAYLISTS if p["id"] == pid), PLAYLISTS[0])
        restricted = not pl["mine"]
        return {"playlist": pl, "tracks": [] if restricted else [track(i) for i in range(12)], "restricted": restricted}
    elif op in ("liked", "recent"):
        return {"items": [track(i) for i in range(3, 12)]}
    elif op == "queue":
        return {"current": track(state["index"]), "items": [track(state["index"] + i) for i in range(1, 8)]}
    elif op == "search":
        q = str(args.get("q") or "").lower()
        return {"tracks": [t for t in (track(i) for i in range(12)) if q in (t["name"] + t["artist"]).lower()],
                "playlists": [p for p in PLAYLISTS if q in p["name"].lower()], "albums": [], "artists": []}
    elif op == "devices":
        return {"items": [{"id": "d1", "name": "Omarchy", "type": "Computer", "active": True, "volume": state["volume"], "restricted": False, "supportsVolume": True},
                          {"id": "d2", "name": "Living Room", "type": "Speaker", "active": False, "volume": 30, "restricted": False, "supportsVolume": True},
                          {"id": "d3", "name": "Phone", "type": "Smartphone", "active": False, "volume": None, "restricted": False, "supportsVolume": True}],
                "localName": "Omarchy"}
    elif op == "saved":
        return {"saved": {u: u.endswith(("1", "4", "7")) for u in args.get("uris") or []}}
    elif op == "like":
        return {"saved": {args.get("uri"): bool(args.get("save", True))}}
    return {"ok": True}
