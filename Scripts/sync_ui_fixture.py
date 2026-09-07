#!/usr/bin/env python3
"""Local, fictional HTTP fixture for simulator UI tests; never a live provider.

Binds loopback only. Does not read environment credentials or contact the internet.
Start with python3 Scripts/sync_ui_fixture.py; test_ui.sh manages it automatically.
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "kakeiro-uitest-only-token-not-for-production"
LOCK = threading.RLock()
STATE = {}


def reset():
    STATE.clear()
    STATE.update(revision=1, requests=0, syncing=False, fail=False,
                 completed=int(time.time() * 1000) - 60_000, generation=0)


def snapshot():
    updated = STATE["revision"] > 1
    date = STATE["completed"]
    accounts = [
        dict(id="fixture:bank", name="連携テスト銀行", institution="架空銀行", kind="bank",
             balance=130000 if updated else 100000, balanceUpdatedAt=date),
        dict(id="fixture:card", name="連携テストカード", institution="架空カード", kind="creditCard",
             balance=-4000 if updated else -5000, balanceUpdatedAt=date),
    ]
    transactions = [dict(id="fixture:purchase", accountID="fixture:card", kind="expense",
                         amount=1500 if updated else 1200, date=date,
                         category="food", merchant="同期テストのスーパー", excludedFromCashFlow=False)]
    if not updated:
        transactions.append(dict(id="fixture:deleted", accountID="fixture:bank", kind="expense",
                                 amount=300, date=date, category="other", merchant="取消前の明細",
                                 excludedFromCashFlow=False))
    transactions.append(dict(id="fixture:repayment", accountID="fixture:bank", kind="expense",
                             amount=5000, date=date, category="other", merchant="カード引き落とし",
                             excludedFromCashFlow=True))
    return dict(schemaVersion=1, revision=STATE["revision"], generatedAt=date,
                lastSuccessfulSync=date, accounts=accounts, transactions=transactions)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, code, value):
        data = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        with LOCK:
            if self.headers.get("Authorization") != "Bearer " + TOKEN:
                return self.send_json(401, {})
            if self.path == "/_test/state":
                return self.send_json(200, STATE)
            if self.path == "/v1/status":
                return self.send_json(200, dict(
                    revision=STATE["revision"], configured=True, connected=True,
                    isSyncing=STATE["syncing"], lastSuccessfulSync=STATE["completed"],
                    lastAttemptAt=None, nextScheduledSync=STATE["completed"] + 86400000,
                    error=None, providerEnvironment="staging", scheduleTimeZone="Asia/Tokyo", scheduleHour=0))
            if self.path == "/v1/snapshot":
                return self.send_json(200, snapshot())
            return self.send_json(404, {})

    def do_POST(self):
        with LOCK:
            if self.headers.get("Authorization") != "Bearer " + TOKEN:
                return self.send_json(401, {})
            if self.path == "/_test/reset":
                reset()
                return self.send_json(200, {})
            if self.path == "/_test/fail":
                STATE["fail"] = True
                return self.send_json(200, {})
            if self.path == "/v1/sync":
                STATE["requests"] += 1
                if STATE["fail"]:
                    return self.send_json(503, {"error": "fixture unavailable"})
                if not STATE["syncing"]:
                    STATE["syncing"] = True
                    STATE["generation"] += 1
                    generation = STATE["generation"]
                    def complete():
                        with LOCK:
                            if STATE["generation"] == generation:
                                STATE.update(revision=STATE["revision"] + 1, syncing=False,
                                             completed=int(time.time() * 1000))
                    threading.Timer(1, complete).start()
                return self.send_json(202, {"accepted": True})
            return self.send_json(404, {})


if __name__ == "__main__":
    reset()
    ThreadingHTTPServer(("127.0.0.1", 8779), Handler).serve_forever()
