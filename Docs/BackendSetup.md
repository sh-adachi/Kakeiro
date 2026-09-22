# 自動連携サーバーの導入

Kakeiro v0.2は個人1人用です。実口座との接続・サーバーへの本番配備は未実施です。まず[費用と契約の準備一覧](ConnectionSetupChecklist.md)で、契約可否・対象金融機関・利用料金・保存条件を確認してください。

## 契約後に設定するもの

- Moneytree LINKの公開PKCEクライアントID、staging／production環境、登録済み戻り先 `kakeiro://moneytree/callback`。
- `guest_read accounts_read transactions_read request_refresh investment_accounts_read investment_transactions_read` の許可。
- 常時稼働するサーバー、所有するドメイン、HTTPS証明書。手持ちMacの場合もスリープ・電源断の間は更新できません。
- サーバー接続キーと保存データの暗号化鍵。`Backend/generate_env.py`でローカル生成します。秘密値はチャット・GitHubへ貼り付けません。

## ローカル準備

Python 3.10 以上が必要です。以下は CI・Docker と揃えた Python 3.12 の例です。macOS 付属の Python 3.9 では、セキュリティ修正版の依存パッケージをインストールできません。

```sh
cd Backend
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python generate_env.py
```

生成された `.env` のMoneytree設定を編集し、`.venv/bin/python -m kakeiro_backend` で起動します。既定は `127.0.0.1:8787`、データは `data/kakeiro.sqlite3`。アプリにはサーバーのHTTPS URLと `KAKEIRO_API_TOKEN` を設定し、「金融機関を連携」から公式認証画面へ進みます。iPhoneからMacの127.0.0.1には接続できないため、実運用では到達可能なHTTPS URLを用意します。

## 常時稼働とHTTPS

Dockerが使えるサーバー向けに `Backend/compose.example.yaml` と `Caddyfile.example` を同梱しています。Docker本番稼働・証明書発行はまだ検証していません。ドメインのDNSをサーバーへ向け、`.env` の `KAKEIRO_DOMAIN` を自身のドメインに変更した後、次の操作で起動します。

```sh
docker compose -f compose.example.yaml up -d --build
docker compose -f compose.example.yaml ps
```

外部公開ポートはHTTPS用443と証明書検証用80のみです。バックエンドの8787は直接公開しません。停止は `docker compose -f compose.example.yaml down`。`--volumes` を付けると保存データが削除されるため、通常の停止には付けません。OSの再起動後もDocker自体が起動する設定と、空き容量・プロセスの監視が必要です。

## 更新動作

サーバーは日本時間の日付で更新ジョブを記録し、0時を迎えた後の定期チェックで取得を開始します。停止していた場合は再起動後に当日分を補います。受付202は完了扱いにせず、金融機関の更新状況と取得結果を確認して保存します。自動更新に対応しない連携は前回値を保持し、警告を返します。口座別取得日時が異なる場合があります。

更新要求は手動・定期を合わせてMoneytreeの1日4回上限を管理します。金融機関独自の上限、認証待ち、メンテナンスは別です。iPhoneは起動時・表示中の定期読込・OSが許可したバックグラウンド実行時にサーバーの保存結果を取得します。iPhoneで0時ちょうどの反映は保証できません。

## 本番データの照合

`MONEYTREE_SIGNED_AMOUNTS_VERIFIED=false` の間、本番スナップショットの公開を停止します。stagingで残高・明細・カード返済・返金・証券評価額を元の画面と照合し、提供元に金額符号とカテゴリの規約を確認してから有効化します。入金は正、出金は負、カード債務残高は負という前提です。支出カテゴリの正数は返金、収入カテゴリの負数は取消として減算します。

現在はJPY整数のみ。外貨、未対応の口座種類、不明な分類を含む場合は取得を拒否して前回データを残します。証券の保有内訳は取得確認しますが、アプリに銘柄別の表示はありません。公開資料だけでは実口座の完全な互換性を保証できません。

## 保存・解除

OAuthトークン・識別情報・金融スナップショットはFernetで暗号化してSQLiteに保存します。接続キーと暗号化鍵は `.env` にあるため、ファイル自体とサーバーへのアクセス権を保護してください。バックアップはサービスを停止したうえでデータディレクトリ全体と暗号化鍵をそれぞれ保管します。鍵を失うと復号できません。Git管理対象にはしません。

連携解除はサーバーの認証情報を削除し、提供元にも失効を要求します。保存済み履歴は保持します。完全削除が必要な場合はバックアップ要否を確認し、サービス停止後に保存ボリューム・バックアップを削除してください。iPhone内の家計簿削除とは別です。複数人でサーバー接続キーを共有する構成には対応していません。

## APIとテスト

すべてのエンドポイントで `Authorization: Bearer <接続キー>` が必要です。

| メソッド・パス | 用途 |
| --- | --- |
| GET `/v1/status` | 接続・更新中・最終成功・次回予定・エラーと警告 |
| GET `/v1/provider` | 公開クライアントの認可設定 |
| POST `/v1/connection` | 利用者が許可したOAuthトークンを保存 |
| DELETE `/v1/connection` | 認証情報の削除・失効要求 |
| POST `/v1/sync` | 非同期更新を要求 |
| GET `/v1/snapshot` | 完了済みデータ。初回未完了は409 |

日時はエポックミリ秒、金額は整数円です。スナップショットは口座ごとの取得済み明細全体で、途中ページを公開しません。`revision`と取得日時でアプリの反映を判定します。

```sh
.venv/bin/python -m unittest discover -s tests -v
```

テストは架空データと一時DB・ローカルHTTPのみを使います。本番API、常時稼働環境、実機からの外部HTTPS接続は契約・配備後に検証してください。
