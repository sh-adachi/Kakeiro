# Kakeiro 自動連携サーバー

Moneytree LINK を利用する、個人1人用のバックエンドです。iPhone の更新ボタンと、毎日午前0時（日本時間）の更新を同じ処理で実行します。Python 3.10 以上が必要です。以下の例は CI・Docker と同じ Python 3.12 を使用します。

**現在、本番の金融機関連携は有効になっていません。** Moneytree のクライアント登録と利用条件の確認、常時稼働サーバーの準備、実口座での照合が必要です。契約・有料サーバー作成は行っていません。

```sh
cd Backend
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python generate_env.py
```

AnyIO・cryptography はセキュリティ修正版に固定しています。macOS 付属の Python 3.9 は使用できません。既存環境を更新する場合も `pip install -r requirements.txt` を実行してください。Python 3.9 で作成した仮想環境は、Python 3.12 で作成した新しい仮想環境へ切り替えてください。

生成された `.env` に、Moneytree から提供された設定を入力して起動します。

```sh
.venv/bin/python -m kakeiro_backend
```

初期状態では `127.0.0.1:8787` に待ち受けます。iPhone から利用する際は、所有するサーバーの TLS リバースプロキシで HTTPS を設定してください。起動・停止、API、暗号化バックアップ、金融機関の制約は [導入手順](../Docs/BackendSetup.md)を参照してください。

```sh
.venv/bin/python -m unittest discover -s tests -v
```

テストは一時DBと架空のプロバイダー通信を使用します。HTTP テストのみローカルの一時ポートを使い、実口座や外部APIには接続しません。
