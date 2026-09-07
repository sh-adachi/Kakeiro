"""Moneytree LINK's documented Japanese API, pinned to 2026-09-03.

Endpoint/schema sources and acceptance limits: Docs/BackendSetup.md.
No bank passwords, private web endpoints, or synthetic production responses.
"""
import hashlib
import json
import threading
import time
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from email.utils import parsedate_to_datetime

import httpx

from .config import SCOPES
from .errors import Cancelled, INVALID_DATA, REAUTHENTICATE, SyncError


API_VERSION = "2026-09-03"
MAX_RECORDS = 200_000
MAX_YEN = 9_000_000_000_000_000
BANK_TYPES = {"savings", "checking", "chochiku", "term_deposit", "term_deposit_builder", "term_deposit_shikumi", "zaikei", "tax_payment_reserve_deposit"}
NO_TRANSACTION_TYPES = {"term_deposit", "term_deposit_builder", "term_deposit_shikumi", "zaikei"}
INVESTMENT_TYPES = {"brokerage", "brokerage_cash", "pension_cash", "defined_contribution_pension", "asset_management"}


def epoch_ms():
    return int(time.time() * 1000)


def timestamp(value):
    if not isinstance(value, str):
        raise SyncError(INVALID_DATA)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError()
        result = int(parsed.timestamp() * 1000)
        if not 0 <= result <= 32_503_680_000_000:
            raise ValueError()
        return result
    except (ValueError, OverflowError):
        raise SyncError(INVALID_DATA) from None


def yen(value):
    if isinstance(value, bool) or not isinstance(value, (int, float, Decimal)):
        raise SyncError("残高・明細に未取得の金額があります。前回のデータを保持しています。")
    try:
        amount = Decimal(str(value))
        if not amount.is_finite() or amount != amount.to_integral_value() or abs(amount) > MAX_YEN:
            raise ValueError()
        return int(amount)
    except (ValueError, InvalidOperation):
        raise SyncError("円単位で表せない金額があります。通貨と取得データを確認してください。") from None


def provider_id(value):
    if type(value) is not int or value < 0 or value > 9_223_372_036_854_775_807:
        raise SyncError(INVALID_DATA)
    return str(value)


def required_text(value, max_length=512):
    if not isinstance(value, str) or not value.strip() or len(value) > max_length:
        raise SyncError(INVALID_DATA)
    return value.strip()


def validate_snapshot(snapshot):
    """Defend the app's complete-replacement boundary, including referential integrity."""
    if snapshot.get("schemaVersion") != 1 or type(snapshot.get("revision")) is not int or snapshot["revision"] < 1:
        raise SyncError(INVALID_DATA)
    for key in ("generatedAt", "lastSuccessfulSync"):
        if type(snapshot.get(key)) is not int or snapshot[key] < 0:
            raise SyncError(INVALID_DATA)
    accounts, transactions = snapshot.get("accounts"), snapshot.get("transactions")
    if not isinstance(accounts, list) or not isinstance(transactions, list) or len(accounts) + len(transactions) > MAX_RECORDS:
        raise SyncError(INVALID_DATA)
    account_ids, transaction_ids = set(), set()
    for account in accounts:
        identifier = required_text(account.get("id"))
        if identifier in account_ids or account.get("kind") not in ("bank", "creditCard", "securities"):
            raise SyncError(INVALID_DATA)
        account_ids.add(identifier)
        required_text(account.get("name"))
        required_text(account.get("institution"))
        if type(account.get("balance")) is not int or type(account.get("balanceUpdatedAt")) is not int:
            raise SyncError(INVALID_DATA)
        yen(account["balance"])
        if not 0 <= account["balanceUpdatedAt"] <= snapshot["generatedAt"] + 60_000:
            raise SyncError(INVALID_DATA)
    for transaction in transactions:
        identifier = required_text(transaction.get("id"))
        if identifier in transaction_ids or transaction.get("accountID") not in account_ids:
            raise SyncError(INVALID_DATA)
        transaction_ids.add(identifier)
        if transaction.get("kind") not in ("expense", "income") or type(transaction.get("amount")) is not int or yen(transaction["amount"]) <= 0:
            raise SyncError(INVALID_DATA)
        if transaction.get("category") not in ("food", "daily", "transport", "housing", "utilities", "entertainment", "health", "shopping", "salary", "other"):
            raise SyncError(INVALID_DATA)
        if type(transaction.get("date")) is not int or transaction["date"] < 0 or type(transaction.get("excludedFromCashFlow")) is not bool:
            raise SyncError(INVALID_DATA)
        if type(transaction.get("isReversal", False)) is not bool or (transaction.get("isReversal", False) and transaction["excludedFromCashFlow"]):
            raise SyncError(INVALID_DATA)
        required_text(transaction.get("merchant"))
    return snapshot


class Moneytree:
    def __init__(self, config, transport=None, clock=epoch_ms):
        self.config, self.clock = config, clock
        self.token_lock = threading.RLock()
        self.client = httpx.Client(transport=transport, timeout=30, follow_redirects=False, trust_env=False)

    def session(self, bundle, persist, active):
        return Session(self, dict(bundle), persist, active)

    def close(self):
        self.client.close()


class Session:
    def __init__(self, provider, bundle, persist, active):
        self.provider, self.bundle, self.persist, self.active = provider, bundle, persist, active

    def check_active(self):
        if not self.active():
            raise Cancelled()

    def _send(self, method, url, **kwargs):
        try:
            with self.provider.client.stream(method, url, **kwargs) as response:
                if response.status_code == 429:
                    raw = response.headers.get("Retry-After", "900")
                    try:
                        seconds = int(raw)
                    except ValueError:
                        try:
                            seconds = int(parsedate_to_datetime(raw).timestamp() - self.provider.clock() / 1000)
                        except (TypeError, ValueError, OverflowError):
                            seconds = 900
                    raise SyncError("Moneytree の更新回数・アクセス制限に達しました。時間をおいて更新してください。", retry_after=max(1, seconds) * 1000, preserve_pending=True)
                if response.status_code in (401, 403):
                    raise SyncError(REAUTHENTICATE, reauthenticate=True)
                if response.status_code not in (200, 202, 204):
                    if response.status_code == 400 and url.endswith("/oauth/token"):
                        raise SyncError(REAUTHENTICATE, reauthenticate=True)
                    raise SyncError("Moneytree への接続に失敗しました。前回のデータを保持しています。", preserve_pending=True)
                content = bytearray()
                for chunk in response.iter_bytes():
                    content.extend(chunk)
                    if len(content) > 16 * 1024 * 1024:
                        raise SyncError(INVALID_DATA)
                if not content and response.status_code in (202, 204):
                    return {}, response.status_code
                value = json.loads(content, parse_float=Decimal)
                if not isinstance(value, dict):
                    raise SyncError(INVALID_DATA)
                return value, response.status_code
        except (httpx.HTTPError, OSError):
            raise SyncError("通信できませんでした。時間をおいて更新してください。", preserve_pending=True) from None
        except (ValueError, UnicodeError):
            raise SyncError(INVALID_DATA) from None

    def refresh_token(self):
        self.check_active()
        data = {"grant_type": "refresh_token", "client_id": self.provider.config.client_id, "refresh_token": self.bundle["refreshToken"]}
        if self.provider.config.client_secret:
            data["client_secret"] = self.provider.config.client_secret
        result, _ = self._send("POST", self.provider.config.auth_base + "/oauth/token", data=data)
        resource = result.get("resource_server", self.bundle["resourceServer"])
        if not self.provider.config.validate_resource_server(resource):
            raise SyncError("Moneytree の接続環境が一致しません。", reauthenticate=True)
        expires = result.get("expires_in")
        if type(expires) is not int or not 0 < expires <= 31_536_000 or str(result.get("token_type", "")).lower() != "bearer":
            raise SyncError(INVALID_DATA)
        if "scope" in result and not set(SCOPES).issubset(set(str(result["scope"]).split())):
            raise SyncError("必要な Moneytree の権限がありません。連携の許可を確認してください。", reauthenticate=True)
        self.bundle.update(accessToken=required_text(result.get("access_token"), 16_384), refreshToken=required_text(result.get("refresh_token"), 16_384), expiresAt=self.provider.clock() + expires * 1000, resourceServer=resource)
        self.check_active()
        # Persist the rotated refresh token before first use of the new access token.
        self.persist(self.bundle)

    def request(self, method, path, **kwargs):
        if not path.startswith("/link/") or "?" in path or ".." in path:
            raise SyncError(INVALID_DATA)
        with self.provider.token_lock:
            self.check_active()
            if self.bundle["expiresAt"] <= self.provider.clock() + 60_000:
                self.refresh_token()
            headers = {"Authorization": "Bearer " + self.bundle["accessToken"], "Moneytree-API-Version": API_VERSION, "Accept": "application/json"}
            try:
                result = self._send(method, self.provider.config.api_base + path, headers=headers, **kwargs)
            except SyncError as error:
                # One serialized token renewal handles an unexpectedly expired access token.
                # 403 may indicate missing scopes; a second rejection is surfaced unchanged.
                if not error.reauthenticate:
                    raise
                self.refresh_token()
                headers["Authorization"] = "Bearer " + self.bundle["accessToken"]
                result = self._send(method, self.provider.config.api_base + path, headers=headers, **kwargs)
            self.check_active()
            return result

    def profile(self):
        result, _ = self.request("GET", "/link/profile.json")
        subject = required_text(result.get("moneytree_id"), 512)
        return subject

    def pages(self, path, key, params=None):
        output, seen = [], set()
        for page in range(1, MAX_RECORDS // 500 + 2):
            result, _ = self.request("GET", path, params=dict(params or {}, page=page))
            records = result.get(key)
            if not isinstance(records, list) or len(records) > 500:
                raise SyncError(INVALID_DATA)
            for record in records:
                if not isinstance(record, dict):
                    raise SyncError(INVALID_DATA)
                identity = record.get("entity_key") if key == "institutions" else provider_id(record.get("id"))
                if identity in seen:
                    raise SyncError("ページ取得中にデータが変わりました。時間をおいて更新してください。")
                seen.add(identity)
                output.append(record)
                if len(output) > MAX_RECORDS:
                    raise SyncError("取得件数が上限を超えています。サーバーの設定を確認してください。")
            if len(records) < 500:
                return output
        raise SyncError(INVALID_DATA)

    def groups(self):
        response, _ = self.request("GET", "/link/profile/account_groups.json")
        records = response.get("account_groups")
        if not isinstance(records, list):
            raise SyncError(INVALID_DATA)
        result = {}
        for group in records:
            identifier = provider_id(group.get("account_group"))
            if identifier in result or type(group.get("background_refreshable")) is not bool:
                raise SyncError(INVALID_DATA)
            last = group.get("last_aggregated_success")
            attempted = group.get("last_aggregated_at")
            result[identifier] = {"successAt": timestamp(last) if last else None, "attemptAt": timestamp(attempted) if attempted else None, "state": group.get("aggregation_state"), "status": group.get("aggregation_status"), "background": group["background_refreshable"]}
        return result

    def request_refresh(self, scheduled=False):
        _, status = self.request("POST", "/link/profile/refresh.json", json={"background_refreshable_only": scheduled})
        if status != 202:
            raise SyncError(INVALID_DATA)

    def revoke(self):
        self.request("POST", "/link/profile/revoke.json")

    def account_baseline(self):
        accounts, groups = {}, set()
        for source, path in (("personal", "/link/accounts.json"), ("investment", "/link/investments/accounts.json")):
            for raw in self.pages(path, "accounts"):
                key = source + ":" + provider_id(raw.get("id"))
                value = raw.get("last_aggregated_success")
                accounts[key] = timestamp(value) if value else 0
                groups.add(provider_id(raw.get("account_group")))
        return {"accounts": accounts, "groups": sorted(groups)}

    def snapshot(self, revision, refreshed_groups, account_baseline=None):
        if self.provider.config.environment == "production" and not self.provider.config.signed_amounts_verified:
            raise SyncError("本番データの金額符号と返金の照合が未完了です。サーバーの導入手順を確認してください。")
        categories = {provider_id(c.get("id")): c for c in self.pages("/link/categories.json", "categories", {"locale": "ja"})}
        institutions = {required_text(i.get("entity_key")): i for i in self.pages("/link/institutions.json", "institutions", {"locale": "ja"})}
        accounts, transactions, membership = [], [], {}
        namespace = "moneytree:" + self.provider.config.environment + ":" + hashlib.sha256(self.bundle["subject"].encode()).hexdigest()[:24]
        for source, path in (("personal", "/link/accounts.json"), ("investment", "/link/investments/accounts.json")):
            for raw in self.pages(path, "accounts"):
                identifier, group = provider_id(raw.get("id")), provider_id(raw.get("account_group"))
                if group not in refreshed_groups:
                    continue
                if raw.get("aggregation_state") != "success" or raw.get("aggregation_status") != "success":
                    raise SyncError("一部の口座の更新が完了していません。前回のデータを保持しています。")
                success_at = timestamp(raw.get("last_aggregated_success"))
                # Group completion may be later than its individual accounts. Compare
                # each account to its own pre-request timestamp, not the group clock.
                if success_at <= (account_baseline or {}).get(source + ":" + identifier, 0):
                    raise SyncError("口座データへの反映を待っています。時間をおいて更新してください。", preserve_pending=True)
                if raw.get("currency") != "JPY":
                    raise SyncError("外貨口座が含まれています。現在の自動取り込みは円建て口座に対応しています。")
                subtype = raw.get("account_subtype")
                if source == "personal":
                    if subtype == "credit_card":
                        kind = "creditCard"
                    elif subtype in BANK_TYPES:
                        kind = "bank"
                    else:
                        raise SyncError("未対応の口座種類があります。デビット・電子マネー・ローン等は対応確認が必要です。")
                    balance = yen(raw.get("current_balance"))
                    detail_type = "none" if subtype in NO_TRANSACTION_TYPES else "transactions"
                else:
                    if subtype not in INVESTMENT_TYPES or raw.get("account_detail_type") not in ("positions", "transactions"):
                        raise SyncError("未対応の証券口座種類があります。取得範囲を確認してください。")
                    kind, balance, detail_type = "securities", yen(raw.get("current_value")), raw["account_detail_type"]
                institution = institutions.get(raw.get("institution_entity_key"))
                if not institution:
                    raise SyncError(INVALID_DATA)
                account_id = namespace + ":" + source + ":" + identifier
                membership[account_id] = group
                accounts.append({"id": account_id, "name": required_text(raw.get("nickname") or raw.get("institution_account_name")), "institution": required_text(institution.get("display_name")), "kind": kind, "balance": balance, "balanceUpdatedAt": success_at})
                base = "/link/investments/accounts/" if source == "investment" else "/link/accounts/"
                if detail_type == "positions":
                    # Validate complete detail retrieval, but do not add positions to account valuation.
                    # Position IDs are regenerated on every refresh; snapshot replacement is intentional.
                    self.pages(base + identifier + "/positions.json", "positions")
                elif detail_type == "transactions":
                    for raw_tx in self.pages(base + identifier + "/transactions.json", "transactions"):
                        if provider_id(raw_tx.get("account_id")) != identifier:
                            raise SyncError(INVALID_DATA)
                        amount = yen(raw_tx.get("amount"))
                        if amount == 0:
                            continue  # A zero-value annotation cannot change either balance or cash flow.
                        category = categories.get(provider_id(raw_tx.get("category_id")))
                        if not category or "category_type" not in category or category["category_type"] not in (None, "expense", "income"):
                            raise SyncError("収支・振替の分類が不明な明細があります。Moneytree で分類を確認してください。")
                        mapped_category = "entertainment" if str(category.get("entity_key", "")).startswith("holiday_leisure") else "other"
                        merchant = raw_tx.get("description_guest") or raw_tx.get("description_pretty") or raw_tx.get("description_raw") or "名称未取得"
                        category_type = category["category_type"]
                        is_reversal = (category_type == "expense" and amount > 0) or (category_type == "income" and amount < 0)
                        kind = category_type or ("income" if amount > 0 else "expense")
                        transactions.append({"id": account_id + ":transaction:" + provider_id(raw_tx.get("id")), "accountID": account_id, "kind": kind, "amount": abs(amount), "date": timestamp(raw_tx.get("date")), "category": mapped_category, "merchant": required_text(merchant), "excludedFromCashFlow": category_type is None, "isReversal": is_reversal})
        # Detect aggregation starting again or a connected institution being added/removed mid-read.
        after = self.groups()
        if {key: after.get(key) for key in refreshed_groups} != refreshed_groups:
            raise SyncError("取得中に金融機関の状態が変わりました。時間をおいて更新してください。", preserve_pending=True)
        now = self.provider.clock()
        snapshot = validate_snapshot({"schemaVersion": 1, "revision": revision, "generatedAt": now, "lastSuccessfulSync": now, "accounts": accounts, "transactions": transactions})
        return snapshot, membership
