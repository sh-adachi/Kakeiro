import fcntl
import hmac
import json
import logging
import os
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .config import Config, load_env
from .errors import SyncError
from .service import Service
from .storage import Store


def handler_for(service):
    class Handler(BaseHTTPRequestHandler):
        server_version = "Kakeiro"
        sys_version = ""

        def setup(self):
            super().setup()
            self.connection.settimeout(15)

        def log_message(self, format, *args):
            pass  # No request URLs, bearer tokens, or payloads in access logs.

        def send_json(self, status, value):
            body = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            if status == 401:
                self.send_header("WWW-Authenticate", "Bearer")
            self.end_headers()
            self.wfile.write(body)

        def handle_request(self):
            expected = ("Bearer " + service.config.bearer_token).encode("utf-8")
            received = self.headers.get("Authorization", "").encode("utf-8")
            if not hmac.compare_digest(received, expected):
                self.send_json(401, {"error": "サーバーの認証情報を確認してください。"})
                return
            if self.headers.get("Origin"):
                self.send_json(403, {"error": "ブラウザーからのアクセスは許可されていません。"})
                return
            route = (self.command, self.path)
            try:
                if route == ("GET", "/v1/status"):
                    return self.send_json(200, service.status())
                if route == ("GET", "/v1/provider"):
                    return self.send_json(200, service.config.provider_configuration())
                if route == ("GET", "/v1/snapshot"):
                    return self.send_json(200, service.snapshot())
                if route == ("POST", "/v1/sync"):
                    return self.send_json(202, service.start_sync())
                if route == ("DELETE", "/v1/connection"):
                    return self.send_json(200, service.disconnect())
                if route == ("POST", "/v1/connection"):
                    if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json" or self.headers.get("Transfer-Encoding"):
                        raise SyncError("JSON 形式で接続してください。", 400)
                    try:
                        size = int(self.headers.get("Content-Length", "-1"))
                        if not 0 < size <= 65_536:
                            raise ValueError()
                        raw = self.rfile.read(size)
                        if len(raw) != size:
                            raise ValueError()
                        body = json.loads(raw)
                    except (ValueError, UnicodeError):
                        raise SyncError("接続情報の形式を確認してください。", 400) from None
                    return self.send_json(202, service.connect(body))
                return self.send_json(404, {"error": "この API はありません。"})
            except SyncError as error:
                return self.send_json(error.status, {"error": error.message})
            except Exception:
                return self.send_json(500, {"error": "サーバーで処理できませんでした。"})

        do_GET = handle_request
        do_POST = handle_request
        do_DELETE = handle_request

    return Handler


def main():
    os.umask(0o077)
    logging.getLogger("httpx").setLevel(logging.CRITICAL)
    logging.getLogger("httpcore").setLevel(logging.CRITICAL)
    load_env(Path(".env"))
    try:
        config = Config.from_env()
    except (ValueError, TypeError, UnicodeError):
        sys.exit("設定が不足または不正です。Docs/BackendSetup.md と Backend/.env.example を確認してください。")
    config.database.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lockfile = open(config.database.with_suffix(".server.lock"), "a")
    try:
        fcntl.flock(lockfile.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit("このデータベースを使用するサーバーはすでに稼働しています。")
    store = Store(config.database, config.encryption_key)
    service = Service(config, store)
    server = ThreadingHTTPServer((config.bind, config.port), handler_for(service))
    server.daemon_threads = True

    def shutdown(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    service.start()
    print("Kakeiro backend started. Financial data and request details are not logged.", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        service.close()
        store.close()
        lockfile.close()


if __name__ == "__main__":
    main()
