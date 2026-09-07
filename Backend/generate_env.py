"""Generate .env once; never print secrets or overwrite existing credentials."""
import os
import secrets
from pathlib import Path

from cryptography.fernet import Fernet


def main():
    template = Path(__file__).with_name(".env.example").read_text(encoding="utf-8")
    contents = template.replace("GENERATE_RANDOM_OWNER_TOKEN", secrets.token_urlsafe(48)).replace("GENERATE_FERNET_KEY", Fernet.generate_key().decode("ascii"))
    path = Path(__file__).with_name(".env")
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        raise SystemExit(".env はすでにあります。既存の認証情報・暗号化鍵は変更していません。") from None
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(contents)
    print(".env を作成しました。Moneytree の設定を入力してから起動してください。秘密情報は表示していません。")


if __name__ == "__main__":
    main()
