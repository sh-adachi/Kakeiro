import copy
import json
import tempfile
import threading
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

import httpx
from cryptography.fernet import Fernet, InvalidToken

from kakeiro_backend.config import Config
from kakeiro_backend.errors import SyncError
from kakeiro_backend.provider import Moneytree, timestamp, validate_snapshot, yen
from kakeiro_backend.service import Service, jst_day, next_midnight, refresh_completed
from kakeiro_backend.storage import Store


class Clock:
    def __init__(self):
        self.now = timestamp("2026-09-07T00:00:00+09:00")

    def __call__(self):
        return self.now


def iso(ms):
    return datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat()


class FakeAPI:
    """Synthetic provider fixtures are only reachable through a test transport."""

    def __init__(self, clock):
        self.clock = clock
        self.requests = []
        self.refreshes = 0
        self.token_refreshes = 0
        self.pending = False
        self.failed = False
        self.rate_limited = False
        self.fail_path = None
        self.bad_currency = False
        self.unknown_category = False
        self.large_history = False
        self.duplicate_page = False
        self.group_success = clock() - 86_400_000
        self.requested_at = None
        self.gate = None
        self.subject = "fixture-guest-123"

    def __call__(self, request):
        path = request.url.path
        self.requests.append((request.method, path, dict(request.url.params)))
        if self.fail_path == path:
            return httpx.Response(503)
        if path == "/oauth/token":
            self.token_refreshes += 1
            return httpx.Response(200, json={"access_token": "rotated-access-token", "refresh_token": "rotated-refresh-token", "expires_in": 3600, "token_type": "bearer", "scope": "guest_read accounts_read transactions_read request_refresh investment_accounts_read investment_transactions_read", "resource_server": "myaccount-staging"})
        if path == "/link/profile.json":
            return httpx.Response(200, json={"moneytree_id": self.subject, "email": "never-persist@example.invalid", "locale_identifier": "ja_JP"})
        if path == "/link/profile/revoke.json":
            return httpx.Response(202)
        if path == "/link/profile/refresh.json":
            self.refreshes += 1
            self.requested_at = self.clock()
            if self.rate_limited:
                return httpx.Response(429, headers={"Retry-After": "120"})
            if self.gate:
                self.gate.wait(5)
            return httpx.Response(202)
        if path == "/link/profile/account_groups.json":
            if self.refreshes and not self.pending and not self.failed:
                self.group_success = self.requested_at or self.clock()
            return httpx.Response(200, json={"account_groups": [{"id": 1, "account_group": 1, "institution_entity_key": "fixture_bank", "aggregation_state": "error" if self.failed else ("running" if self.pending and self.refreshes else "success"), "aggregation_status": "error.network" if self.failed else ("running.data" if self.pending and self.refreshes else "success"), "last_aggregated_at": iso(self.requested_at or self.group_success), "last_aggregated_success": iso(self.group_success), "background_refreshable": True}]})
        if path == "/link/categories.json":
            categories = [{"id": 1, "entity_key": "holiday_leisure", "category_type": "expense"}, {"id": 2, "entity_key": "fixture_salary", "category_type": "income"}, {"id": 3, "entity_key": "fixture_transfer", "category_type": None}]
            if self.unknown_category:
                del categories[0]["category_type"]
            return httpx.Response(200, json={"categories": categories})
        if path == "/link/institutions.json":
            return httpx.Response(200, json={"institutions": [{"entity_key": "fixture_bank", "display_name": "試験銀行"}]})
        if path == "/link/accounts.json":
            return httpx.Response(200, json={"accounts": [self.account(7, "savings", 123456789), self.account(8, "credit_card", -200)]})
        if path == "/link/investments/accounts.json":
            account = self.account(7, "brokerage", 3000)
            account.update(current_value=3000, account_detail_type="positions")
            return httpx.Response(200, json={"accounts": [account]})
        if path == "/link/investments/accounts/7/positions.json":
            return httpx.Response(200, json={"positions": [{"id": 8001, "market_value": 3000, "currency": "JPY"}]})
        if path == "/link/accounts/7/transactions.json":
            if self.large_history:
                page = int(request.url.params.get("page", 1))
                start = 0 if self.duplicate_page else (page - 1) * 500
                values = [self.transaction(i + 1, 7, -10, 1) for i in range(start, min(start + 500, 501))]
            else:
                values = [self.transaction(1, 7, -300, 1), self.transaction(2, 7, 1000, 2), self.transaction(3, 7, -200, 3)]
            return httpx.Response(200, json={"transactions": values})
        if path == "/link/accounts/8/transactions.json":
            return httpx.Response(200, json={"transactions": [self.transaction(4, 8, -200, 1), self.transaction(5, 8, 30, 1)]})
        raise AssertionError("Unexpected test endpoint: " + path)

    def account(self, identifier, subtype, balance):
        return {"id": identifier, "account_group": 1, "account_subtype": subtype, "currency": "USD" if self.bad_currency else "JPY", "institution_entity_key": "fixture_bank", "institution_account_name": "試験口座", "nickname": "試験口座", "current_balance": balance, "aggregation_state": "success", "aggregation_status": "success", "last_aggregated_success": iso(self.group_success)}

    def transaction(self, identifier, account, amount, category):
        return {"id": identifier, "account_id": account, "amount": amount, "category_id": category, "date": iso(self.clock() - 1000), "description_pretty": "fixture merchant confidential"}


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.clock = Clock()
        self.config = Config("owner-token-" + "a" * 40, Fernet.generate_key().decode(), Path(self.temp.name) / "data.sqlite3", client_id="fixture-client", poll_seconds=0.01, refresh_timeout_seconds=60)
        self.store = Store(self.config.database, self.config.encryption_key)
        self.api = FakeAPI(self.clock)
        self.provider = Moneytree(self.config, transport=httpx.MockTransport(self.api), clock=self.clock)
        self.service = Service(self.config, self.store, self.provider, self.clock)
        self.bundle = {"accessToken": "test-access-token-secret", "refreshToken": "test-refresh-token-secret", "expiresAt": self.clock() + 3_600_000, "resourceServer": "myaccount-staging", "subject": self.api.subject}
        self.store.atomic({"tokens": self.bundle, "owner": self.api.subject})

    def tearDown(self):
        if self.api.gate:
            self.api.gate.set()
        self.service.close()
        self.store.close()
        self.temp.cleanup()

    def finish(self):
        self.service.thread.join(timeout=3)
        self.assertFalse(self.service.thread.is_alive(), "worker must finish")

    def sync(self):
        self.service.start_sync()
        self.finish()

    def test_full_snapshot_authoritative_balances_and_transfer_exclusion(self):
        self.sync()
        status, snapshot = self.service.status(), self.service.snapshot()
        self.assertTrue(status["connected"])
        self.assertEqual(status["revision"], 1)
        self.assertIsNone(status["error"])
        self.assertEqual(len(snapshot["accounts"]), 3)
        self.assertEqual(len(set(a["id"] for a in snapshot["accounts"])), 3)
        self.assertEqual(snapshot["accounts"][0]["balance"], 123456789)
        self.assertEqual(snapshot["accounts"][1]["balance"], -200)
        self.assertEqual(sum(t["amount"] * (-1 if t["isReversal"] else 1) for t in snapshot["transactions"] if t["kind"] == "expense" and not t["excludedFromCashFlow"]), 470)
        self.assertEqual(snapshot["transactions"][-1]["kind"], "expense")
        self.assertTrue(snapshot["transactions"][-1]["isReversal"])
        self.assertFalse(self.service.scheduler_tick(), "successful initial/manual sync already satisfies today's schedule")

    def test_concurrent_refresh_buttons_coalesce(self):
        self.api.gate = threading.Event()
        callers = [threading.Thread(target=self.service.start_sync) for _ in range(12)]
        for caller in callers:
            caller.start()
        for caller in callers:
            caller.join()
        self.assertTrue(self.service.status()["isSyncing"])
        self.api.gate.set()
        self.finish()
        self.assertEqual(self.api.refreshes, 1)

    def test_expired_token_rotates_and_is_encrypted_before_reuse(self):
        self.bundle["expiresAt"] = self.clock() - 1000
        self.store.atomic({"tokens": self.bundle})
        self.sync()
        self.assertEqual(self.api.token_refreshes, 1)
        self.assertEqual(self.store.get("tokens")["refreshToken"], "rotated-refresh-token")
        self.store.db.execute("PRAGMA wal_checkpoint(FULL)")
        raw = self.config.database.read_bytes()
        self.assertNotIn(b"rotated-refresh-token", raw)
        self.assertNotIn(b"fixture merchant confidential", raw)
        self.assertNotIn(b"123456789", raw)

    def test_202_never_marks_completed_until_aggregation_finishes(self):
        self.api.pending = True
        self.service.start_sync()
        time.sleep(0.04)
        self.assertTrue(self.service.status()["isSyncing"])
        self.assertIsNone(self.service.status()["lastSuccessfulSync"])
        with self.assertRaises(SyncError):
            self.service.snapshot()
        self.api.pending = False
        self.finish()
        self.assertIsNotNone(self.service.status()["lastSuccessfulSync"])

    def test_stale_refresh_times_out_and_keeps_last_good_snapshot(self):
        self.sync()
        original = self.service.snapshot()
        self.clock.now += 1000
        self.api.pending = True
        self.service.start_sync()
        time.sleep(0.02)
        self.clock.now += 61_000
        self.finish()
        self.assertEqual(self.service.snapshot(), original)
        self.assertIn("完了を確認できません", self.service.status()["error"])

    def test_failed_aggregation_timestamp_does_not_count_as_success(self):
        baseline = {"1": {"successAt": self.clock() - 1000}}
        current = {"1": {"successAt": self.clock() - 1000, "state": "error", "status": "error.network"}}
        with self.assertRaises(SyncError):
            refresh_completed(baseline, current)
        self.api.failed = True
        self.sync()
        self.assertIsNone(self.service.status()["lastSuccessfulSync"])

    def test_previous_failure_is_polled_until_new_attempt_starts(self):
        baseline = {"1": {"successAt": self.clock() - 10000, "attemptAt": self.clock() - 1000, "state": "error", "status": "error.network"}}
        self.assertFalse(refresh_completed(baseline, copy.deepcopy(baseline)))
        newer = copy.deepcopy(baseline)
        newer["1"]["attemptAt"] = self.clock()
        with self.assertRaises(SyncError):
            refresh_completed(baseline, newer)

    def test_all_history_pages_are_loaded_and_duplicate_pages_rejected(self):
        self.api.large_history = True
        self.sync()
        self.assertEqual(len(self.service.snapshot()["transactions"]), 503)
        self.assertTrue(any(p.endswith("/7/transactions.json") and q.get("page") == "2" for _, p, q in self.api.requests))
        original = self.service.snapshot()
        self.clock.now += 1000
        self.api.duplicate_page = True
        self.sync()
        self.assertEqual(self.service.snapshot(), original)
        self.assertIsNotNone(self.service.status()["error"])

    def test_partial_failure_does_not_publish_revision(self):
        self.sync()
        original = self.service.snapshot()
        self.clock.now += 1000
        self.api.fail_path = "/link/accounts/8/transactions.json"
        self.sync()
        self.assertEqual(self.service.snapshot(), original)
        self.assertEqual(self.service.status()["lastSuccessfulSync"], original["lastSuccessfulSync"])

    def test_fx_and_unknown_classification_fail_without_silent_loss(self):
        self.api.bad_currency = True
        self.sync()
        self.assertIn("外貨", self.service.status()["error"])
        self.clock.now += 1000
        self.api.bad_currency = False
        self.api.unknown_category = True
        self.sync()
        self.assertIn("分類が不明", self.service.status()["error"])
        self.assertIsNone(self.store.get("snapshot"))

    def test_snapshot_rejects_nan_fractional_yen_duplicate_and_orphan(self):
        for amount in (float("nan"), float("inf"), 10.5, None, True):
            with self.assertRaises(SyncError):
                yen(amount)
        self.sync()
        snapshot = self.service.snapshot()
        for mutation in (lambda s: s["accounts"].append(s["accounts"][0]), lambda s: s["transactions"][0].update(accountID="missing"), lambda s: s["transactions"][0].update(amount=-1)):
            changed = copy.deepcopy(snapshot)
            mutation(changed)
            with self.assertRaises(SyncError):
                validate_snapshot(changed)

    def test_jst_midnight_is_utc_1500(self):
        before = timestamp("2026-09-06T14:59:59Z")
        after = timestamp("2026-09-06T15:00:00Z")
        self.assertEqual(jst_day(before), "2026-09-06")
        self.assertEqual(jst_day(after), "2026-09-07")
        self.assertEqual(next_midnight(before), after)
        self.assertEqual(next_midnight(after), after + 86_400_000)

    def test_scheduler_catches_missed_day_once_and_durable_retry_is_bounded(self):
        self.assertTrue(self.service.scheduler_tick())
        self.finish()
        self.assertEqual(self.api.refreshes, 1)
        self.assertFalse(self.service.scheduler_tick())
        self.clock.now += 86_400_000
        self.api.failed = True
        self.assertTrue(self.service.scheduler_tick())
        self.finish()
        self.assertFalse(self.service.scheduler_tick())
        for attempt, delay in ((2, 15 * 60_000), (3, 30 * 60_000)):
            self.clock.now += delay
            self.assertTrue(self.service.scheduler_tick())
            self.finish()
            self.assertEqual(self.store.schedule(jst_day(self.clock()))["attempts"], attempt)
        self.clock.now += 60 * 60_000
        self.assertFalse(self.service.scheduler_tick())

    def test_restart_resumes_accepted_job_without_second_refresh_post(self):
        baseline = {"1": {"successAt": self.clock() - 86_400_000, "state": "success", "status": "success", "background": True}}
        self.api.refreshes = 1
        self.store.atomic({"pending": {"generation": 0, "baseline": baseline, "requestedAt": self.clock() - 1000, "deadlineAt": self.clock() + 50_000, "day": None, "phase": "reserved"}})
        # A new Service over the same durable database is what process startup does.
        previous = self.service
        self.service = Service(self.config, self.store, self.provider, self.clock)
        previous.stop_event.set()
        self.assertTrue(self.service.scheduler_tick())
        self.finish()
        self.assertEqual(self.api.refreshes, 1)
        self.assertIsNone(self.store.get("pending"))

    def test_disconnect_during_worker_cannot_restore_data_or_credentials(self):
        self.api.gate = threading.Event()
        self.service.start_sync()
        time.sleep(0.03)
        thread = threading.Thread(target=self.service.disconnect)
        thread.start()
        time.sleep(0.03)
        self.api.gate.set()
        thread.join(timeout=2)
        self.finish()
        self.assertFalse(self.service.status()["connected"])
        self.assertIsNone(self.store.get("tokens"))
        self.assertIsNone(self.store.get("snapshot"))
        self.assertFalse(self.service.scheduler_tick())

    def test_connect_validates_profile_and_prevents_owner_switch(self):
        self.api.subject = "another-fixture-person"
        body = {k: v for k, v in self.bundle.items() if k != "subject"}
        with self.assertRaises(SyncError) as result:
            self.service.connect(body)
        self.assertEqual(result.exception.status, 409)
        self.assertEqual(self.store.get("tokens")["subject"], "fixture-guest-123")
        body["resourceServer"] = "https://attacker.invalid"
        count = len(self.api.requests)
        with self.assertRaises(SyncError):
            self.service.connect(body)
        self.assertEqual(len(self.api.requests), count)

    def test_provider_rate_limit_is_respected_by_button_and_scheduler(self):
        self.api.rate_limited = True
        self.sync()
        self.assertIsNone(self.service.status()["lastSuccessfulSync"])
        with self.assertRaises(SyncError) as result:
            self.service.start_sync()
        self.assertEqual(result.exception.status, 429)
        self.assertFalse(self.service.scheduler_tick())
        self.assertEqual(self.api.refreshes, 1)

    def test_four_request_daily_budget_is_durable(self):
        for _ in range(4):
            self.sync()
            self.clock.now += 1000
        self.sync()
        self.assertEqual(self.api.refreshes, 4)
        self.assertIn("4回", self.service.status()["error"])
        self.clock.now = next_midnight(self.clock())
        self.sync()
        self.assertEqual(self.api.refreshes, 5)

    def test_database_tamper_and_wrong_key_are_detected(self):
        self.store.db.execute("UPDATE sealed SET value=? WHERE key='tokens'", (b"not authenticated ciphertext",))
        self.store.db.commit()
        with self.assertRaises(InvalidToken):
            self.store.get("tokens")


if __name__ == "__main__":
    unittest.main()
