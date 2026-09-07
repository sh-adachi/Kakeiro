import threading
from datetime import datetime, timedelta, timezone

from .errors import Cancelled, INVALID_DATA, REAUTHENTICATE, SyncError
from .provider import Moneytree, epoch_ms, required_text, validate_snapshot


JST = timezone(timedelta(hours=9), name="Asia/Tokyo")


def jst_day(now):
    return datetime.fromtimestamp(now / 1000, JST).date().isoformat()


def next_midnight(now):
    local = datetime.fromtimestamp(now / 1000, JST)
    tomorrow = local.date() + timedelta(days=1)
    return int(datetime.combine(tomorrow, datetime.min.time(), JST).timestamp() * 1000)


def refresh_completed(baseline, current):
    """A 202 or a changed last_aggregated_at is never proof of success."""
    if set(current) != set(baseline):
        raise SyncError("連携口座が更新中に変わりました。もう一度更新してください。")
    for identifier, group in current.items():
        status = group["status"] or ""
        previous = baseline[identifier]
        attempted = (group.get("attemptAt") or 0) > (previous.get("attemptAt") or 0)
        changed = group["state"] != previous.get("state") or status != previous.get("status")
        # A queued 202 can show the *previous* error for several minutes before
        # Moneytree starts the new attempt. Only a new failure ends this job.
        if (attempted or changed) and status.startswith(("auth.", "suspended.", "guest.intervention")):
            raise SyncError("金融機関で追加認証が必要です。Moneytree の口座管理画面を確認してください。")
        if (attempted or changed) and group["state"] == "error":
            raise SyncError("一部の金融機関で更新に失敗しました。前回のデータを保持しています。")
        if group["state"] != "success" or status != "success" or group["successAt"] is None or group["successAt"] <= (baseline[identifier]["successAt"] or 0):
            return False
    return bool(current)


class Service:
    def __init__(self, config, store, provider=None, clock=epoch_ms):
        self.config, self.store, self.clock = config, store, clock
        self.provider = provider or Moneytree(config, clock=clock)
        self.lock = threading.RLock()
        self.connection_lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread = None
        self.scheduler_thread = None
        self.workers = set()
        self.state = store.get("state", {"generation": 0, "lastSuccessfulSync": None, "lastAttemptAt": None, "error": None, "needsAuthentication": False, "nextAllowedSync": 0})
        self.state["isSyncing"] = False
        self._save_state()

    def _save_state(self):
        self.store.atomic({"state": self.state})

    def status(self):
        with self.lock:
            connected = self.store.get("tokens") is not None and not self.state.get("needsAuthentication", False)
            scheduled = next_midnight(self.clock()) if connected and self.config.configured else None
            today = self.store.schedule(jst_day(self.clock()))
            if today and today["state"] == "failed" and today["attempts"] < 3:
                scheduled = min(scheduled, max(self.clock(), today["retryAt"])) if scheduled is not None else None
            snapshot = self.store.get("snapshot", {})
            return {"configured": self.config.configured, "connected": connected, "isSyncing": self.state["isSyncing"], "revision": snapshot.get("revision"), "lastSuccessfulSync": self.state.get("lastSuccessfulSync"), "lastAttemptAt": self.state.get("lastAttemptAt"), "nextScheduledSync": scheduled, "error": self.state.get("error"), "warning": self.state.get("warning"), "providerEnvironment": self.config.environment, "scheduleTimeZone": "Asia/Tokyo", "scheduleHour": 0}

    def session(self, generation, detached=None):
        if detached is not None:
            return self.provider.session(detached, lambda bundle: None, lambda: True)

        def active():
            with self.lock:
                return not self.stop_event.is_set() and generation == self.state["generation"] and self.store.get("tokens") is not None

        def persist(bundle):
            with self.lock:
                if not active():
                    raise Cancelled()
                self.store.atomic({"tokens": bundle})

        return self.provider.session(self.store.get("tokens"), persist, active)

    def connect(self, body):
        if not self.config.configured:
            raise SyncError("Moneytree のクライアント登録がサーバーに設定されていません。", 409)
        if not isinstance(body, dict) or set(body) != {"accessToken", "refreshToken", "expiresAt", "resourceServer"}:
            raise SyncError("接続情報の形式を確認してください。", 400)
        token, refresh = required_text(body.get("accessToken"), 16_384), required_text(body.get("refreshToken"), 16_384)
        expiry = body.get("expiresAt")
        if type(expiry) is not int or expiry <= self.clock() or expiry > self.clock() + 31_536_000_000:
            raise SyncError("認証の有効期限を確認し、もう一度連携してください。", 400)
        if not self.config.validate_resource_server(body.get("resourceServer")):
            raise SyncError("Moneytree の接続環境が一致しません。", 400)
        with self.connection_lock:
            bundle = {"accessToken": token, "refreshToken": refresh, "expiresAt": expiry, "resourceServer": body["resourceServer"]}
            probe = self.provider.session(bundle, lambda value: bundle.update(value), lambda: True)
            subject = probe.profile()
            bundle.update(probe.bundle, subject=subject)
            with self.lock:
                old = self.store.get("tokens")
                old_subject = old.get("subject") if old else self.store.get("owner")
                # One server belongs to one person. Switching owner requires a new database.
                if old_subject and old_subject != subject:
                    raise SyncError("このサーバーは別の Moneytree アカウントに紐づいています。同じアカウントで連携してください。", 409)
                self.state.update(generation=self.state["generation"] + 1, error=None, warning=None, needsAuthentication=False, isSyncing=False, nextAllowedSync=0)
                self.store.atomic({"tokens": bundle, "owner": subject, "state": self.state}, deletes=("pending",))
            return self.start_sync("connection")

    def disconnect(self):
        with self.connection_lock:
            with self.lock:
                bundle = self.store.get("tokens")
                self.state.update(generation=self.state["generation"] + 1, isSyncing=False, error=None, warning=None, needsAuthentication=False, nextAllowedSync=0)
                self.store.atomic({"state": self.state}, deletes=("tokens", "pending"))
            # Local cancellation and deletion happen before network I/O; an old worker
            # cannot resurrect credentials, scheduled jobs or a snapshot after unlinking.
            if bundle:
                try:
                    self.session(0, detached=bundle).revoke()
                except SyncError:
                    with self.lock:
                        self.state["error"] = "サーバーの連携は解除しました。Moneytree 側の連携取消を確認できなかったため、Moneytree の設定からも確認してください。"
                        self._save_state()
            return self.status()

    def snapshot(self):
        with self.lock:
            snapshot = self.store.get("snapshot")
            if snapshot is None:
                raise SyncError("金融機関の更新がまだ完了していません。", 409)
            return validate_snapshot(snapshot)

    def start_sync(self, trigger="manual", day=None):
        with self.lock:
            if self.stop_event.is_set():
                raise SyncError("サーバーを終了しています。", 503)
            if not self.config.configured or not self.store.get("tokens") or self.state.get("needsAuthentication"):
                raise SyncError("Moneytree と連携してから更新してください。", 409)
            if self.state["isSyncing"]:
                return self.status()
            if self.state.get("nextAllowedSync", 0) > self.clock():
                raise SyncError("次に更新できる時刻までお待ちください。", 429)
            self.state.update(isSyncing=True, lastAttemptAt=self.clock(), error=None)
            self._save_state()
            generation = self.state["generation"]
            thread = threading.Thread(target=self._run, args=(generation, trigger, day), daemon=True, name="kakeiro-sync")
            self.thread = thread
            self.workers.add(thread)
            thread.start()
            return self.status()

    def _run(self, generation, trigger, day):
        success, error = False, None
        try:
            session = self.session(generation)
            pending = self.store.get("pending")
            if pending and pending["generation"] != generation:
                raise Cancelled()
            if not pending:
                all_groups = session.groups()
                inventory = session.account_baseline()
                # Known personal/investment accounts identify financial groups. A
                # brand-new connection can still have a group before its first account.
                financial_groups = set(inventory["groups"]) or set(all_groups)
                baseline = {key: value for key, value in all_groups.items() if key in financial_groups}
                if not baseline:
                    raise SyncError("Moneytree に金融機関を登録してから更新してください。")
                skipped = 0
                if trigger == "scheduled":
                    eligible = {key: value for key, value in baseline.items() if value["background"]}
                    skipped = len(baseline) - len(eligible)
                    baseline = eligible
                    if not baseline:
                        raise SyncError("自動更新できる金融機関がありません。Moneytree の口座管理画面で追加認証を確認してください。")
                now = self.clock()
                with self.lock:
                    session.check_active()
                    budget = self.store.get("refreshBudget", {"day": jst_day(now), "count": 0})
                    if budget["day"] != jst_day(now):
                        budget = {"day": jst_day(now), "count": 0}
                    if budget["count"] >= 4:
                        raise SyncError("本日の更新要求は4回に達しました。次の午前0時以降に更新してください。", retry_after=next_midnight(now) - now)
                    budget["count"] += 1
                    pending = {"generation": generation, "baseline": baseline, "accountBaseline": inventory["accounts"], "skipped": skipped, "requestedAt": now, "deadlineAt": now + int(self.config.refresh_timeout_seconds * 1000), "day": day, "phase": "reserved"}
                    # Reserve BEFORE sending: on a crash or lost HTTP response, resume
                    # polling this request, never blindly send another refresh POST.
                    self.store.atomic({"pending": pending, "refreshBudget": budget})
                session.request_refresh(trigger == "scheduled")
                pending["phase"] = "accepted"
                with self.lock:
                    session.check_active()
                    self.store.atomic({"pending": pending})
            # A scheduled request survives restarts even when resumed by a manual button.
            day = pending.get("day") or day
            while True:
                session.check_active()
                current = session.groups()
                complete, failed, waiting = {}, [], []
                for key, baseline_group in pending["baseline"].items():
                    try:
                        if refresh_completed({key: baseline_group}, {key: current[key]} if key in current else {}):
                            complete[key] = current[key]
                        else:
                            waiting.append(key)
                    except SyncError as group_error:
                        failed.append(group_error)
                deadline = self.clock() >= pending["deadlineAt"]
                if not waiting or deadline:
                    if not complete:
                        if failed:
                            raise failed[0]
                        raise SyncError("金融機関の更新完了を確認できませんでした。前回のデータを保持しています。時間をおいて更新してください。")
                    old = self.store.get("snapshot", {})
                    snapshot, membership = session.snapshot(old.get("revision", 0) + 1, complete, pending.get("accountBaseline", {}))
                    if not snapshot["accounts"]:
                        raise SyncError("更新済みの金融口座をまだ取得できません。Moneytree の口座管理画面を確認してください。")
                    old_membership = self.store.get("accountGroups", {})
                    replace_ids = {key for key, group in old_membership.items() if group in complete}
                    # Retain unavailable groups with their original balance timestamps.
                    # This cumulative cache also supports a phone that missed earlier jobs.
                    snapshot["accounts"] += [a for a in old.get("accounts", []) if a["id"] not in replace_ids and a["id"] not in membership]
                    snapshot["transactions"] += [t for t in old.get("transactions", []) if t["accountID"] not in replace_ids and t["accountID"] not in membership]
                    membership.update({key: group for key, group in old_membership.items() if key not in replace_ids})
                    snapshot = validate_snapshot(snapshot)
                    stale_count = pending.get("skipped", 0) + len(failed) + len(waiting)
                    warning = "%d件の金融機関連携は更新できなかったため、前回の残高・明細を保持しています。Moneytree の口座管理画面で認証状態を確認してください。" % stale_count if stale_count else None
                    with self.lock:
                        session.check_active()
                        self.state.update(lastSuccessfulSync=snapshot["lastSuccessfulSync"], error=None, warning=warning, needsAuthentication=False, nextAllowedSync=0)
                        self.store.atomic({"snapshot": snapshot, "accountGroups": membership, "state": self.state}, deletes=("pending",))
                        self.store.satisfy_day(jst_day(self.clock()))
                    success = True
                    break
                if self.clock() >= pending["deadlineAt"]:
                    raise SyncError("金融機関の更新完了を確認できませんでした。前回のデータを保持しています。時間をおいて更新してください。")
                self.stop_event.wait(min(self.config.poll_seconds, max(0.001, (pending["deadlineAt"] - self.clock()) / 1000)))
        except Cancelled:
            pass
        except SyncError as caught:
            error = caught
        except Exception:
            # Deliberately never log exception repr, HTTP payloads or financial values.
            error = SyncError("更新処理に失敗しました。前回のデータを保持しています。")
        finally:
            with self.lock:
                if generation == self.state["generation"]:
                    self.state["isSyncing"] = False
                    if error:
                        self.state.update(error=error.message, needsAuthentication=error.reauthenticate, nextAllowedSync=self.clock() + error.retry_after)
                        pending = self.store.get("pending")
                        preserve = error.preserve_pending and pending and pending["deadlineAt"] > self.clock()
                        if preserve:
                            self.state["nextAllowedSync"] = self.clock() + max(error.retry_after, 60_000)
                        self.store.atomic({"state": self.state}, deletes=() if preserve else ("pending",))
                    else:
                        self._save_state()
                    if day:
                        self.store.finish_day(day, self.clock(), success, error.retry_after if error else 0)
                self.workers.discard(threading.current_thread())

    def scheduler_tick(self):
        with self.lock:
            if not self.config.configured or not self.store.get("tokens") or self.state["isSyncing"] or self.state.get("needsAuthentication") or self.state.get("nextAllowedSync", 0) > self.clock():
                return False
            pending = self.store.get("pending")
            if pending:
                pending_day = pending.get("day")
                row = self.store.schedule(pending_day) if pending_day else None
                if row and row["state"] == "failed" and not self.store.claim_day(pending_day, self.clock()):
                    return False
                self.start_sync("resume", day=pending.get("day"))
                return True
            today = jst_day(self.clock())
            if not self.store.claim_day(today, self.clock()):
                return False
            try:
                self.start_sync("scheduled", day=today)
            except SyncError:
                self.store.finish_day(today, self.clock(), False)
                return False
            return True

    def start(self):
        def loop():
            while not self.stop_event.is_set():
                self.scheduler_tick()
                self.stop_event.wait(20)
        self.scheduler_thread = threading.Thread(target=loop, daemon=True, name="kakeiro-midnight")
        self.scheduler_thread.start()

    def close(self):
        self.stop_event.set()
        with self.lock:
            workers = list(self.workers)
        for worker in workers:
            worker.join(timeout=35)
        if self.scheduler_thread:
            self.scheduler_thread.join(timeout=1)
        self.provider.close()
