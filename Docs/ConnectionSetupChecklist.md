# 自動連携の接続準備

KakeiroのMoneytree LINK連携を導入する開発者向けのチェックリストです。接続・サーバーへの本番配備は未検証です。コードのビルドだけでは金融機関への接続は有効になりません。

## 契約と対象範囲

- 利用目的・提供範囲・対象ユーザー数に適したAPI利用承認と契約条件を、提供元に確認する。
- 利用したい銀行・カード・証券について、対象口座・金融商品・通貨・認証方式・履歴期間・更新制限を確認する。
- API利用料と常時稼働サーバーの費用、データ保存先・保存期間・バックアップ条件を確認する。
- 口座番号・カード番号・氏名・連絡先・ログイン情報は、このファイルやGitリポジトリに記入しない。

金融機関の対応確認と実装上の制限は [FinancialConnections.md](FinancialConnections.md) を参照してください。

## 接続設定

| 項目 | 設定方法 |
| --- | --- |
| クライアントID・クライアント種別 | Moneytreeに登録したPublic PKCEクライアントの情報を使用 |
| 環境 | stagingとproductionを分離 |
| 戻り先 | 登録するURIとアプリ実装の `kakeiro://moneytree/callback` を一致させる |
| OAuthスコープ | `guest_read accounts_read transactions_read request_refresh investment_accounts_read investment_transactions_read` の利用権限を確認 |
| クライアント秘密情報 | サーバー側で必要な場合のみ、Git管理外の環境設定に保存。iPhoneへ埋め込まない |
| サーバーURL | iPhoneから到達できるHTTPSの接続先を用意 |
| 接続キー・保存データの暗号化鍵 | `Backend/generate_env.py` でローカル生成し、Git管理外の `.env` に保存 |

初期設定・HTTPS・暗号化保存・運用手順は [BackendSetup.md](BackendSetup.md) を参照してください。`.env.example` は設定の見本として保持し、実際の値は `.env` に設定します。

## 利用開始前の検証

- 検証環境で認可・取消・期限切れ・追加認証・通信失敗・ページングを確認する。
- 残高・明細・返金・カード返済・証券評価額を元のデータと照合する。
- 対応を確認した後に `MONEYTREE_SIGNED_AMOUNTS_VERIFIED` を有効にする。
- 更新要求の受付と完了を区別し、失敗時に前回データが保持されることを確認する。
- 定期更新は常時稼働するサーバーで行い、iPhoneのバックグラウンド実行時刻に依存しない。
- 実データ・ログ・バックアップ・秘密設定をソースコードや公開用アーカイブに含めない。
