#!/usr/bin/env python3
"""Loopback-only HTTP bridge for the MANAGER Telegram Mini App.

HTTPS termination belongs to a separately configured reverse proxy. This server
has no public bind option and never trusts user data as identity or authority.
"""
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CONTRACT = "manager-telegram-miniapp-http-v1"
REQUEST_CONTRACT = "manager-telegram-gateway-request-v1"
VIEWS = {"clients", "sessions", "products", "quotas"}
MAX_BODY = 16384
MAX_REPLY = 262144
SEM = threading.BoundedSemaphore(6)
HOME = Path(os.environ.get("MANAGER_HOME", "/opt/manager"))
STATE = Path(os.environ.get("MANAGER_ETC", "/etc/manager")) / "telegram" / "miniapp"
ASSETS = HOME / "web" / "telegram"
GATEWAY = HOME / "modules" / "telegram_gateway.sh"
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{7,95}$")
ASSET_MAP = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "application/javascript; charset=utf-8"),
}


def valid_origin(raw):
    parsed = urllib.parse.urlsplit(raw)
    host = parsed.hostname
    if (parsed.scheme != "https" or not host or parsed.username is not None
            or parsed.password is not None or parsed.path not in {"", "/"}
            or parsed.query or parsed.fragment or parsed.port is not None
            or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,250}", host)
            or host.startswith(".") or ".." in host
            or host in {"localhost", "127.0.0.1"}):
        raise ValueError("public origin must be a dedicated HTTPS hostname")
    return "https://" + host.lower()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, origin):
        super().__init__(addr, Handler)
        self.origin = origin
        self.expected_host = urllib.parse.urlsplit(origin).netloc


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        # Request bodies, paths, URLs, initData and user attributes never logged.
        pass

    def headers_out(self, status, kind="application/json; charset=utf-8", length=0):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self' https://telegram.org; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; object-src 'none'")
        self.end_headers()

    def reply(self, status, payload):
        encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.headers_out(status, length=len(encoded))
        self.wfile.write(encoded)

    def host_ok(self):
        host = self.headers.get("Host", "").lower()
        return host == self.server.expected_host and "," not in host

    def do_GET(self):
        if not self.host_ok():
            return self.reply(403, {"ok": False, "error": "host-not-allowed"})
        if self.path == "/healthz":
            return self.reply(200, {"ok": True, "contract": CONTRACT})
        if self.path not in ASSET_MAP:
            return self.reply(404, {"ok": False, "error": "not-found"})
        filename, kind = ASSET_MAP[self.path]
        try:
            file = ASSETS / filename
            if file.is_symlink() or not file.is_file():
                raise OSError("asset missing")
            data = file.read_bytes()
            if len(data) > 524288:
                raise OSError("asset too large")
        except OSError:
            return self.reply(503, {"ok": False, "error": "asset-unavailable"})
        self.headers_out(200, kind, len(data))
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/api/read":
            return self.reply(404, {"ok": False, "error": "not-found"})
        if not self.host_ok():
            return self.reply(403, {"ok": False, "error": "host-not-allowed"})
        if self.headers.get("Origin") != self.server.origin:
            return self.reply(403, {"ok": False, "error": "origin-not-allowed"})
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
            return self.reply(415, {"ok": False, "error": "json-required"})
        length = self.headers.get("Content-Length", "")
        if not length.isascii() or not length.isdecimal() or len(length) > 5 or not 0 < int(length) <= MAX_BODY:
            return self.reply(413, {"ok": False, "error": "body-size-invalid"})
        if not SEM.acquire(blocking=False):
            return self.reply(503, {"ok": False, "error": "busy"})
        try:
            raw = self.rfile.read(int(length))
            try:
                req = json.loads(raw.decode("utf-8"))
                if not isinstance(req, dict) or set(req) != {"init_data", "view", "page", "limit"}:
                    raise ValueError("request schema")
                init_data = req["init_data"]
                view, page, limit = req["view"], req["page"], req["limit"]
                if not isinstance(init_data, str) or not 1 <= len(init_data.encode("utf-8")) <= 12000:
                    raise ValueError("init data")
                if view not in VIEWS or type(page) is not int or type(limit) is not int:
                    raise ValueError("view or type")
                if not (0 <= page <= 100000 and 1 <= limit <= 25):
                    raise ValueError("pagination")
            except (ValueError, UnicodeError, TypeError, KeyError):
                return self.reply(400, {"ok": False, "error": "invalid-request"})
            if not GATEWAY.is_file() or not os.access(GATEWAY, os.X_OK):
                return self.reply(503, {"ok": False, "error": "gateway-unavailable"})
            request = {
                "contract": REQUEST_CONTRACT,
                "request_id": "miniapp-" + os.urandom(12).hex(),
                "action_id": "ops.read",
                "params": {"view": view, "page": str(page), "limit": str(limit)},
            }
            STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8",
                                             prefix=".request-", suffix=".json",
                                             dir=STATE, delete=False) as fp:
                path = fp.name
                os.fchmod(fp.fileno(), 0o600)
                json.dump(request, fp, separators=(",", ":"))
                fp.write("\n")
            try:
                result = subprocess.run(
                    [str(GATEWAY), "--call-stdin", path],
                    input=init_data + "\n", capture_output=True,
                    text=True, timeout=215, check=False,
                )
            finally:
                os.unlink(path)
            try:
                if len(result.stdout) > MAX_REPLY:
                    raise ValueError("oversized gateway result")
                data = json.loads(result.stdout)
                if not isinstance(data, dict) or data.get("contract") != "manager-telegram-gateway-v1":
                    raise ValueError("unexpected contract")
                status = data.get("code")
                if type(status) is not int or not 0 <= status <= 255:
                    raise ValueError("invalid gateway code")
            except (ValueError, TypeError):
                return self.reply(503, {"ok": False, "error": "backend-unavailable"})
            if result.returncode != 0 or not data.get("ok"):
                http_code = {64: 400, 65: 409, 67: 403, 75: 429}.get(status, 503)
                return self.reply(http_code, {"ok": False, "error": "access-denied" if http_code == 403 else "request-failed"})
            result_data = data.get("result")
            view_data = result_data.get("view") if isinstance(result_data, dict) else None
            if not isinstance(view_data, dict) or view_data.get("contract") != "manager-automation-scoped-reads-v1" or view_data.get("view") != view:
                return self.reply(503, {"ok": False, "error": "backend-unavailable"})
            if (type(view_data.get("page")) is not int or view_data["page"] != page
                    or type(view_data.get("limit")) is not int or view_data["limit"] != limit
                    or not isinstance(view_data.get("items"), list) or len(view_data["items"]) > limit):
                return self.reply(503, {"ok": False, "error": "backend-unavailable"})
            return self.reply(200, {"ok": True, "data": view_data})
        except (OSError, subprocess.TimeoutExpired):
            return self.reply(503, {"ok": False, "error": "backend-unavailable"})
        finally:
            SEM.release()

    def do_PUT(self):
        self.reply(405, {"ok": False, "error": "read-only"})

    do_PATCH = do_DELETE = do_PUT


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: telegram_miniapp_server.py ORIGIN LOOPBACK_PORT")
    origin = valid_origin(sys.argv[1])
    port = int(sys.argv[2])
    if not (1024 <= port <= 65535):
        raise SystemExit("invalid port")
    os.umask(0o077)
    socket.setdefaulttimeout(15)
    server = Server(("127.0.0.1", port), origin)
    server.serve_forever(poll_interval=0.3)


if __name__ == "__main__":
    main()
