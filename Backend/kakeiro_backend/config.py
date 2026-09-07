import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from cryptography.fernet import Fernet


SCOPES = (
    "guest_read", "accounts_read", "transactions_read", "request_refresh",
    "investment_accounts_read", "investment_transactions_read",
)


def load_env(path: Path) -> None:
    """Read literal KEY=VALUE lines, never evaluate shell code or interpolate secrets."""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not key.replace("_", "").isalnum():
            raise ValueError(".env の形式を確認してください。")
        value = value.strip()
        if len(value) > 1 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ.setdefault(key, value)


@dataclass(frozen=True)
class Config:
    bearer_token: str
    encryption_key: str
    database: Path
    client_id: str = ""
    redirect_uri: str = "kakeiro://moneytree/callback"
    environment: str = "staging"
    bind: str = "127.0.0.1"
    port: int = 8787
    poll_seconds: float = 30
    refresh_timeout_seconds: float = 900
    client_secret: str = ""
    signed_amounts_verified: bool = False

    def __post_init__(self):
        if not 32 <= len(self.bearer_token) <= 4096 or not self.bearer_token.isascii() or any(c.isspace() for c in self.bearer_token):
            raise ValueError("KAKEIRO_API_TOKEN は32文字以上のランダムな値が必要です。")
        Fernet(self.encryption_key.encode("ascii"))
        if self.environment not in ("staging", "production"):
            raise ValueError("MONEYTREE_ENVIRONMENT は staging または production にしてください。")
        uri = urlsplit(self.redirect_uri)
        if self.redirect_uri != "kakeiro://moneytree/callback" or not uri.scheme or uri.fragment or uri.query or uri.username or uri.password:
            raise ValueError("MONEYTREE_REDIRECT_URI が正しくありません。")
        if not 1 <= self.port <= 65535 or self.poll_seconds <= 0 or self.refresh_timeout_seconds <= 0:
            raise ValueError("サーバーの時間・ポート設定が正しくありません。")

    @classmethod
    def from_env(cls):
        return cls(
            bearer_token=os.environ.get("KAKEIRO_API_TOKEN", ""),
            encryption_key=os.environ.get("KAKEIRO_ENCRYPTION_KEY", ""),
            database=Path(os.environ.get("KAKEIRO_DATABASE", "data/kakeiro.sqlite3")),
            client_id=os.environ.get("MONEYTREE_CLIENT_ID", ""),
            redirect_uri=os.environ.get("MONEYTREE_REDIRECT_URI", "kakeiro://moneytree/callback"),
            environment=os.environ.get("MONEYTREE_ENVIRONMENT", "staging"),
            bind=os.environ.get("KAKEIRO_BIND", "127.0.0.1"),
            port=int(os.environ.get("KAKEIRO_PORT", "8787")),
            client_secret=os.environ.get("MONEYTREE_CLIENT_SECRET", ""),
            signed_amounts_verified=os.environ.get("MONEYTREE_SIGNED_AMOUNTS_VERIFIED", "false").lower() == "true",
        )

    @property
    def configured(self):
        return bool(self.client_id.strip())

    @property
    def auth_base(self):
        suffix = "-staging" if self.environment == "staging" else ""
        return "https://myaccount%s.getmoneytree.com" % suffix

    @property
    def api_base(self):
        suffix = "-staging" if self.environment == "staging" else ""
        return "https://jp-api%s.getmoneytree.com" % suffix

    def validate_resource_server(self, value):
        suffix = "-staging" if self.environment == "staging" else ""
        # resource_server is an identifier in the documented token response, not a URL.
        # Never construct a network destination from input supplied by the app/provider.
        return isinstance(value, str) and value in {
            "myaccount" + suffix, "jp-api" + suffix,
            self.api_base, self.api_base + "/", self.auth_base, self.auth_base + "/",
        }

    def provider_configuration(self):
        return {
            "clientID": self.client_id,
            "authorizationURL": self.auth_base + "/oauth/authorize",
            "tokenURL": self.auth_base + "/oauth/token",
            "redirectURI": self.redirect_uri,
            "scopes": list(SCOPES),
            "environment": self.environment,
        }
