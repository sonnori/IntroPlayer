#!/usr/bin/env python3
"""
IntroPlayer - Local server for the Song Intro Quiz game.
Pure Python standard library. No pip packages needed.

Run:  python3 server.py
Then open http://localhost:8000 in your browser.
"""

import http.server
import socketserver
import datetime
import errno
import os
import re
import time
import json
import posixpath
import urllib.parse

PORT = 8000
ROOT = os.path.dirname(os.path.abspath(__file__))
SONGS_DIR = os.path.join(ROOT, "songs")
SE_DIR = os.path.join(ROOT, "se")
CONFIG_PATH = os.path.join(ROOT, "config.json")
LOG_PATH = os.path.join(ROOT, "log.json")

CLIENTS = {}        # client id -> last heartbeat (monotonic); see /api/hello
CLIENT_TTL = 12.0   # a window that hasn't pinged for this long is considered closed

AUDIO_EXTS = (".mp3", ".m4a", ".wav", ".ogg", ".flac", ".aac")
MIME = {
    ".mp3": "audio/mpeg",
    ".m4a": "audio/mp4",
    ".aac": "audio/aac",
    ".wav": "audio/wav",
    ".ogg": "audio/ogg",
    ".flac": "audio/flac",
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript",
    ".css": "text/css",
    ".json": "application/json",
}


def guess_mime(path):
    ext = os.path.splitext(path)[1].lower()
    return MIME.get(ext, "application/octet-stream")


class Handler(http.server.BaseHTTPRequestHandler):
    # quieter logging
    def log_message(self, fmt, *args):
        pass

    # ---- helpers -------------------------------------------------
    def _send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _safe_join(self, base, rel):
        """Prevent path traversal. Returns absolute path inside base or None."""
        rel = urllib.parse.unquote(rel)
        rel = posixpath.normpath("/" + rel).lstrip("/")
        full = os.path.normpath(os.path.join(base, rel))
        if os.path.commonpath([os.path.abspath(full), base]) != base:
            return None
        return full

    def _serve_file(self, path):
        """Serve a static file with HTTP Range support (needed for audio seeking)."""
        if not os.path.isfile(path):
            self.send_error(404, "Not found")
            return
        file_size = os.path.getsize(path)
        ctype = guess_mime(path)
        range_header = self.headers.get("Range")

        if range_header:
            m = re.match(r"bytes=(\d*)-(\d*)", range_header)
            start = int(m.group(1)) if m and m.group(1) else 0
            end = int(m.group(2)) if m and m.group(2) else file_size - 1
            end = min(end, file_size - 1)
            if start > end or start >= file_size:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % file_size)
                self.end_headers()
                return
            length = end - start + 1
            self.send_response(206)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, file_size))
            self.send_header("Content-Length", str(length))
            self.end_headers()
            with open(path, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(64 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        else:
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(file_size))
            self.end_headers()
            with open(path, "rb") as f:
                while True:
                    chunk = f.read(64 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)

    # ---- routes --------------------------------------------------
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/" or path == "/index.html":
            self._serve_file(os.path.join(ROOT, "index.html"))
            return

        if path == "/api/songs":
            # Relative paths, so a subfolder of songs/ becomes a playlist (one taping session).
            # Files sitting loose in songs/ keep a bare filename, which is exactly what the old
            # flat layout produced — existing config entries for them keep working untouched.
            songs = []
            if os.path.isdir(SONGS_DIR):
                for root, dirs, files in os.walk(SONGS_DIR):
                    dirs[:] = [d for d in dirs if not d.startswith(".")]
                    for name in files:
                        if name.lower().endswith(AUDIO_EXTS) and not name.startswith("."):
                            rel = os.path.relpath(os.path.join(root, name), SONGS_DIR)
                            songs.append(rel.replace(os.sep, "/"))
            songs.sort(key=lambda s: s.lower())
            self._send_json({"songs": songs})
            return

        if path == "/api/config":
            cfg = {}
            if os.path.isfile(CONFIG_PATH):
                try:
                    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                        cfg = json.load(f)
                except Exception:
                    cfg = {}
            self._send_json(cfg)
            return

        if path == "/api/log":
            self._send_json({"events": self._read_log()})
            return

        if path.startswith("/songs/"):
            full = self._safe_join(SONGS_DIR, path[len("/songs/"):])
            if full:
                self._serve_file(full)
            else:
                self.send_error(403)
            return

        if path.startswith("/se/"):
            full = self._safe_join(SE_DIR, path[len("/se/"):])
            if full:
                self._serve_file(full)
            else:
                self.send_error(403)
            return

        self.send_error(404, "Not found")

    # ---- taping log ----------------------------------------------------
    def _read_log(self):
        if os.path.isfile(LOG_PATH):
            try:
                with open(LOG_PATH, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, dict) and isinstance(data.get("events"), list):
                    return data["events"]
            except Exception:
                pass
        return []

    def _write_log(self, events):
        with open(LOG_PATH, "w", encoding="utf-8") as f:
            json.dump({"events": events}, f, ensure_ascii=False, indent=2)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/config":
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                data = json.loads(raw.decode("utf-8"))
            except Exception:
                self._send_json({"ok": False, "error": "bad json"}, 400)
                return
            try:
                with open(CONFIG_PATH, "w", encoding="utf-8") as f:
                    json.dump(data, f, ensure_ascii=False, indent=2)
                self._send_json({"ok": True})
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, 500)
            return

        if parsed.path == "/api/hello":
            # Liveness ping so a window can tell it is not the only one open. The .app refuses to
            # launch twice, but nothing stops a plain browser tab on localhost:8000, and two
            # windows silently overwrite each other's config.
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                cid = str(json.loads(raw.decode("utf-8")).get("id", ""))[:64]
            except Exception:
                cid = ""
            now = time.monotonic()
            CLIENTS[cid] = now
            for k in [k for k, v in CLIENTS.items() if now - v > CLIENT_TTL]:
                CLIENTS.pop(k, None)
            self._send_json({"clients": len(CLIENTS)})
            return

        if parsed.path == "/api/log":
            # Append-only by design: the client sends ONE event and the server owns the file and
            # the clock. Unlike /api/config (whole-object overwrite) two windows can't clobber
            # each other's history here, and the timestamp can't drift with a client's clock.
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw.decode("utf-8"))
            except Exception:
                self._send_json({"ok": False, "error": "bad json"}, 400)
                return
            op = body.get("op", "append")
            try:
                events = self._read_log()
                if op == "append":
                    ev = body.get("event") or {}
                    if ev.get("event") not in ("correct", "wrong"):
                        self._send_json({"ok": False, "error": "bad event"}, 400)
                        return
                    events.append({
                        "t": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
                        "playlist": str(ev.get("playlist", "")),
                        "path": str(ev.get("path", "")),
                        "event": ev["event"],
                    })
                elif op == "undo":
                    pl = body.get("playlist")
                    for i in range(len(events) - 1, -1, -1):
                        if pl is None or events[i].get("playlist") == pl:
                            events.pop(i)
                            break
                elif op == "clear":
                    pl = body.get("playlist")
                    events = [] if pl is None else [e for e in events if e.get("playlist") != pl]
                else:
                    self._send_json({"ok": False, "error": "bad op"}, 400)
                    return
                self._write_log(events)
                self._send_json({"ok": True, "events": events})
            except Exception as e:
                self._send_json({"ok": False, "error": str(e)}, 500)
            return

        self.send_error(404, "Not found")


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    # macOS blocks Desktop / Documents / Downloads / iCloud for processes without permission, so
    # this is where a copied-to-another-Mac install dies. A bare traceback here tells the operator
    # nothing, and the launcher can only report "server failed to start".
    try:
        os.makedirs(SONGS_DIR, exist_ok=True)
        os.makedirs(SE_DIR, exist_ok=True)
        os.listdir(SONGS_DIR)
    except OSError as e:
        if e.errno in (errno.EPERM, errno.EACCES):
            print("ERROR: ไม่มีสิทธิ์เข้าถึงโฟลเดอร์ - %s" % ROOT)
            print("       macOS ป้องกัน Desktop / Documents / Downloads / iCloud อยู่")
            print("       วิธีแก้: ย้ายทั้งโฟลเดอร์ IntroPlayer ไปไว้ที่ ~/IntroPlayer แล้วเปิดใหม่")
        else:
            print("ERROR: เปิดโฟลเดอร์ songs/ หรือ se/ ไม่ได้ - %s" % e)
        raise SystemExit(3)
    try:
        httpd = ThreadingServer(("127.0.0.1", PORT), Handler)
    except OSError as e:
        if e.errno not in (errno.EADDRINUSE, errno.EACCES):
            raise
        # A raw traceback in front of the GM mid-taping is useless; say what to do instead.
        print("=" * 48)
        print("  Port %d is already in use." % PORT)
        print("")
        print("  IntroPlayer is probably already running.")
        print("  Try opening:  http://localhost:%d" % PORT)
        print("")
        print("  If not, something else has the port. Find it with:")
        print("    lsof -nP -iTCP:%d -sTCP:LISTEN" % PORT)
        print("=" * 48)
        raise SystemExit(2)
    url = "http://localhost:%d" % PORT
    print("=" * 48)
    print("  IntroPlayer is running!")
    print("  Open this in your browser:  " + url)
    print("  Put song files in:  ./songs/")
    print("  To stop: press Control-C, or just close this window.")
    print("=" * 48)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
