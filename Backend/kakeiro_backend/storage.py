import json
import os
import sqlite3
import threading
from pathlib import Path

from cryptography.fernet import Fernet


class Store:
    """All OAuth, identity, snapshot and job payloads are authenticated ciphertext.

    SQLite transactions atomically publish the complete snapshot and success state.
    Financial values are never put in unencrypted columns, SQLite WAL, or logs.
    """

    def __init__(self, path: Path, key: str):
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock = threading.RLock()
        self.cipher = Fernet(key.encode("ascii"))
        self.db = sqlite3.connect(str(path), check_same_thread=False)
        os.chmod(path, 0o600)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("CREATE TABLE IF NOT EXISTS sealed (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
        self.db.execute("CREATE TABLE IF NOT EXISTS schedule (day TEXT PRIMARY KEY, attempts INTEGER NOT NULL, state TEXT NOT NULL, retry_at INTEGER)")
        self.db.commit()

    def get(self, key, default=None):
        with self.lock:
            row = self.db.execute("SELECT value FROM sealed WHERE key = ?", (key,)).fetchone()
            return json.loads(self.cipher.decrypt(row[0])) if row else default

    def atomic(self, updates=None, deletes=()):
        with self.lock, self.db:
            for key, value in (updates or {}).items():
                raw = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
                self.db.execute("INSERT OR REPLACE INTO sealed(key,value) VALUES (?,?)", (key, self.cipher.encrypt(raw)))
            for key in deletes:
                self.db.execute("DELETE FROM sealed WHERE key = ?", (key,))

    def schedule(self, day):
        with self.lock:
            row = self.db.execute("SELECT attempts,state,retry_at FROM schedule WHERE day=?", (day,)).fetchone()
            return {"attempts": row[0], "state": row[1], "retryAt": row[2]} if row else None

    def claim_day(self, day, now):
        with self.lock, self.db:
            item = self.schedule(day)
            if item and (item["state"] == "success" or item["attempts"] >= 3 or (item["retryAt"] or 0) > now):
                return False
            attempts = (item["attempts"] if item else 0) + 1
            # A crashed process cannot claim this day again until this lease expires.
            self.db.execute("INSERT OR REPLACE INTO schedule VALUES (?,?,?,?)", (day, attempts, "running", now + 20 * 60_000))
            return True

    def finish_day(self, day, now, success, retry_after=0):
        with self.lock, self.db:
            item = self.schedule(day)
            if not item:
                return
            delay = max(retry_after, 15 * 60_000 * 2 ** (item["attempts"] - 1))
            self.db.execute("UPDATE schedule SET state=?,retry_at=? WHERE day=?", ("success" if success else "failed", None if success else now + delay, day))

    def satisfy_day(self, day):
        with self.lock, self.db:
            item = self.schedule(day)
            self.db.execute("INSERT OR REPLACE INTO schedule VALUES (?,?,?,NULL)", (day, item["attempts"] if item else 0, "success"))

    def close(self):
        with self.lock:
            self.db.close()
