# サーバー（さくらVPS）— Supabaseからの移行

Supabaseの期限切れに伴い、バックエンドを自前サーバーへ全面移行した記録と運用手順。

- ホスト: `153.125.148.69`（Ubuntu 24.04 / 4core / 8GB / 100GB・**友人と共有**）
- APIエンドポイント: `https://153-125-148-69.sslip.io/v1`
- 配置先: `~/hajimemashite/server/`
- 最終更新: 2026-08-16

---

## 構成

```
Internet :443 ──> Caddy（自動TLS・セキュリティヘッダ・gzip）
                    └─ 内部ネットワークのみ ─> api（Go静的バイナリ）
                                                  └─ SQLite（named volume）
```

**なぜこの構成か**
- 共有サーバーなので常駐リソースを最小化したい → Go + SQLite（DB用の別プロセスが不要）
- PostgreSQLを立てると常時200MB以上を占有する。SQLiteなら実測 **3.2MB**
- TLSはCaddyが自動取得・自動更新（証明書運用の手作業がゼロになる）

**実測リソース**
| コンテナ | メモリ | イメージ |
|---|---|---|
| api | 3.2MB（上限256MB） | 13.8MB |
| caddy | 13.5MB（上限128MB） | 88.7MB |

---

## 容量削減の工夫

| 対象 | 手法 | 効果 |
|---|---|---|
| ドット絵 | 1画素4bitにパックしてBLOB保存 | 256要素JSON(約800B) → **128B**（約1/6） |
| APIイメージ | 多段ビルド＋`scratch`＋`-ldflags="-s -w"` | 13.8MB（Goツールチェーンはホストに不要） |
| トークン | 48時間経過分を自動削除＋1ユーザー3本まで | DBが増え続けない |
| バックアップ | `VACUUM INTO`で断片化を除いた複製・7世代 | 実測32KB/世代 |
| ログ | コンテナごとに5MB×3世代で上限 | ディスク圧迫を防止 |
| WAL | 定期`wal_checkpoint(TRUNCATE)` | WALファイルの肥大化を防止 |

---

## セキュリティ（検証済み）

| 項目 | 状態 |
|---|---|
| TLS | Let's Encrypt自動取得・自動更新。**TLS1.0/1.1は拒否**、1.2/1.3のみ |
| HTTP | 308でHTTPSへ強制リダイレクト |
| 認証 | Bearer APIキー。**SHA-256ハッシュで保存**（DB漏洩時も鍵は復元不能）・定数時間比較 |
| 認可 | 全APIで認証必須（未提示/不正はいずれも401） |
| レート制限 | 匿名登録5回/分・API120回/分（IP単位）。実測: 130連打中124回を429で遮断 |
| 攻撃面 | 公開は`/v1/*`のみ。他パスは404。管理API(2019)とAPI(8080)は**外部非公開** |
| 露出ポート | 22/80/443のみ（8080・5432・6379等はすべてclosed） |
| コンテナ | 非root(UID10001)・`read_only`・`cap_drop ALL`・`no-new-privileges` |
| 入力検証 | 本文32KB上限・名前20文字・画素値0-15・トークンは32桁hexのみ受理 |
| SQL | すべてプレースホルダ（文字列連結なし） |
| ヘッダ | HSTS / CSP / X-Content-Type-Options / X-Frame-Options / Referrer-Policy |
| 個人情報 | 保持しない。位置情報は一切扱わない。アクセスログにヘッダを残さない |

**変更していないもの（指示どおり）**: 各ユーザーのパスワード、SSH設定、既存の他ユーザーのコンテナ・イメージ。

---

## API

| メソッド | パス | 認証 | 用途（旧Supabase相当） |
|---|---|---|---|
| GET | `/v1/health` | 不要 | 死活監視 |
| POST | `/v1/auth/anon` | 不要 | 匿名ユーザー作成（signInAnonymously） |
| POST | `/v1/tokens/issue` | 必要 | BLEトークン発行（issue_token RPC） |
| POST | `/v1/tokens/resolve` | 必要 | トークン→プロフィール解決（resolve_tokens RPC） |
| POST | `/v1/profile` | 必要 | 表示名・色・ドット絵・バッジ更新（users upsert） |

APIキーは端末の`FlutterSecureStorage`に保存され、**有効期限を持たない**。
Supabase時代に発生していた「約6時間でセッション失効し同期が止まる」問題は構造的に起きない。

---

## 運用

```bash
# 状態確認
ssh itoen@153.125.148.69
cd ~/hajimemashite/server
docker compose ps
docker compose logs -f api          # ログ追尾
docker stats --no-stream            # リソース

# 更新デプロイ（ローカルから）
scp main.go Dockerfile compose.yml Caddyfile itoen@153.125.148.69:~/hajimemashite/server/
ssh itoen@153.125.148.69 'cd ~/hajimemashite/server && docker compose build && docker compose up -d'

# バックアップ確認（毎6時間・7世代・自動）
docker run --rm -v server_api-data:/d alpine ls -la /d/backups

# バックアップから復元
docker compose down
docker run --rm -v server_api-data:/d alpine sh -c 'cp /d/backups/app-YYYYMMDD.db /d/app.db && rm -f /d/app.db-wal /d/app.db-shm'
docker compose up -d
```

自動起動: `docker.service`が`enabled`＋コンテナが`restart: unless-stopped`のため、
サーバー再起動後も自動復帰する。

---

## 独自ドメインへ移行する場合

1. DNSのAレコードを`153.125.148.69`に向ける
2. `Caddyfile`のホスト名を差し替え
3. `lib/core/api_config.dart`の`apiBaseUrl`を差し替え
4. 再デプロイ（証明書はCaddyが自動取得）

sslip.ioは「IPをそのまま名前解決する公開DNS」であり、追加登録も費用も不要。
ただし第三者運営のため、長期運用では独自ドメインが望ましい。

---

## 移行時に踏んだ問題と対処

| 事象 | 原因 | 対処 |
|---|---|---|
| 証明書取得が失敗し続ける | ACMEの連絡先が`itoen@localhost`でドット無し→LE/ZeroSSL双方で拒否 | `email`設定を削除（未設定でも取得可能） |
| APIが`unable to open database file`で再起動ループ | `scratch`イメージ＋非rootで、名前付きボリューム`/data`の所有者がroot | ビルド段階で`/data`を作りUID10001所有にしてCOPY（初回ボリューム作成時に所有権が継承される） |
