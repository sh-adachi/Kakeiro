import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

import httpx
from cryptography.fernet import Fernet

from kakeiro_backend.__main__ import handler_for
from kakeiro_backend.config import Config
from kakeiro_backend.service import Service
from kakeiro_backend.storage import Store


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.config = Config("private-owner-" + "x" * 40, Fernet.generate_key().decode(), Path(self.temp.name) / "test.sqlite3")
        self.store = Store(self.config.database, self.config.encryption_key)
        self.service = Service(self.config, self.store)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(self.service))
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.01), daemon=True)
        self.thread.start()
        self.client = httpx.Client(base_url="http://127.0.0.1:%s" % self.server.server_port, trust_env=False)
        self.authorization = {"Authorization": "Bearer " + self.config.bearer_token}

    def tearDown(self):
        self.client.close()
        self.server.shutdown()
        self.thread.join(timeout=1)
        self.server.server_close()
        self.service.close()
        self.store.close()
        self.temp.cleanup()

    def test_all_financial_and_configuration_routes_require_bearer(self):
        for method, path in (("GET", "/v1/status"), ("GET", "/v1/provider"), ("GET", "/v1/snapshot"), ("POST", "/v1/sync"), ("POST", "/v1/connection"), ("DELETE", "/v1/connection")):
            for header in ({}, {"Authorization": "Bearer wrong-token"}):
                response = self.client.request(method, path, headers=header)
                self.assertEqual(response.status_code, 401)
                self.assertEqual(response.headers["cache-control"], "no-store")

    def test_unconfigured_server_reports_truth_and_has_no_snapshot(self):
        response = self.client.get("/v1/status", headers=self.authorization)
        status = response.json()
        self.assertEqual(response.status_code, 200)
        self.assertFalse(status["configured"])
        self.assertFalse(status["connected"])
        self.assertFalse(status["isSyncing"])
        self.assertIsNone(status["revision"])
        self.assertIsNone(status["lastSuccessfulSync"])
        self.assertEqual(status["scheduleHour"], 0)
        self.assertEqual(status["scheduleTimeZone"], "Asia/Tokyo")
        self.assertEqual(self.client.get("/v1/snapshot", headers=self.authorization).status_code, 409)
        self.assertEqual(self.client.post("/v1/sync", headers=self.authorization).status_code, 409)

    def test_public_pkce_configuration_contains_no_server_secret(self):
        response = self.client.get("/v1/provider", headers=self.authorization)
        self.assertEqual(response.status_code, 200)
        provider = response.json()
        self.assertEqual(provider["authorizationURL"], "https://myaccount-staging.getmoneytree.com/oauth/authorize")
        self.assertEqual(provider["redirectURI"], "kakeiro://moneytree/callback")
        self.assertNotIn(self.config.encryption_key, response.text)
        self.assertNotIn(self.config.bearer_token, response.text)
        self.assertNotIn("clientSecret", provider)

    def test_browser_origins_and_malformed_json_are_rejected(self):
        response = self.client.get("/v1/status", headers=dict(self.authorization, Origin="https://attacker.invalid"))
        self.assertEqual(response.status_code, 403)
        self.assertNotIn("access-control-allow-origin", response.headers)
        response = self.client.post("/v1/connection", content="not json", headers=dict(self.authorization, **{"Content-Type": "application/json"}))
        self.assertEqual(response.status_code, 400)
        response = self.client.post("/v1/connection", content="{}", headers=self.authorization)
        self.assertEqual(response.status_code, 400)


if __name__ == "__main__":
    unittest.main()
