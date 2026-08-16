// はじめましてこんにちは — 自前APIサーバー
//
// Supabase から移行した最小構成のバックエンド。
// 設計方針:
//   - 省リソース: Go 静的バイナリ + SQLite（別プロセスのDB不要、常駐RAM ~20MB）
//   - 省容量: ドット絵は 4bit/px にパックして 128byte で保存（JSON配列比 約6分の1）
//   - 堅牢: APIキーはハッシュ保存、全入力を検証、レート制限、プリペアドステートメント
//   - 匿名性: 個人情報は保持しない。位置情報は一切扱わない（アプリの絶対維持事項）
package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	_ "modernc.org/sqlite"
)

const (
	pixelCount     = 256              // 16x16 ドット絵
	packedPixels   = pixelCount / 2   // 4bit/px → 128 byte
	tokenTTL       = 24 * time.Hour   // BLEトークンの有効期間
	resolveWindow  = 48 * time.Hour   // 解析対象として受け付ける期間
	maxBodyBytes   = 32 << 10         // 32KB（ドット絵込みでも十分）
	maxNameRunes   = 20
	maxResolveList = 200
)

var db *sql.DB

// ─── レート制限（IP単位のトークンバケット）───────────────────────────────
type bucket struct {
	tokens float64
	last   time.Time
}

type limiter struct {
	mu       sync.Mutex
	buckets  map[string]*bucket
	rate     float64 // 1秒あたりの補充量
	capacity float64
}

func newLimiter(perMinute float64, burst float64) *limiter {
	return &limiter{buckets: map[string]*bucket{}, rate: perMinute / 60.0, capacity: burst}
}

func (l *limiter) allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	b, ok := l.buckets[key]
	if !ok {
		// メモリ肥大防止: 一定数を超えたら古いものを捨てる
		if len(l.buckets) > 10000 {
			for k, v := range l.buckets {
				if now.Sub(v.last) > 10*time.Minute {
					delete(l.buckets, k)
				}
			}
		}
		l.buckets[key] = &bucket{tokens: l.capacity - 1, last: now}
		return true
	}
	b.tokens += now.Sub(b.last).Seconds() * l.rate
	if b.tokens > l.capacity {
		b.tokens = l.capacity
	}
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

var (
	signupLimiter = newLimiter(5, 5)      // 匿名登録: 5回/分（新規ユーザー乱造の抑止）
	apiLimiter    = newLimiter(120, 60)   // 通常API: 120回/分
)

// ─── ドット絵の圧縮（4bit/px パック）─────────────────────────────────────
// 256個の 0-15 の値を 128 byte に詰める。JSON配列(約800byte)比で約6分の1。
func packPixels(px []int) ([]byte, error) {
	if len(px) != pixelCount {
		return nil, errors.New("pixels must be 256")
	}
	out := make([]byte, packedPixels)
	for i := 0; i < pixelCount; i += 2 {
		a, b := px[i], px[i+1]
		if a < 0 || a > 15 || b < 0 || b > 15 {
			return nil, errors.New("pixel value out of range")
		}
		out[i/2] = byte(a<<4 | b)
	}
	return out, nil
}

func unpackPixels(buf []byte) []int {
	if len(buf) != packedPixels {
		return nil
	}
	out := make([]int, pixelCount)
	for i, b := range buf {
		out[i*2] = int(b >> 4)
		out[i*2+1] = int(b & 0x0f)
	}
	return out
}

// ─── DB ─────────────────────────────────────────────────────────────────
func initDB(path string) error {
	var err error
	// WAL + NORMAL同期: 小規模同時アクセスで高速かつ安全
	db, err = sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(ON)")
	if err != nil {
		return err
	}
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(4)

	schema := `
CREATE TABLE IF NOT EXISTS users (
  id           TEXT PRIMARY KEY,
  key_hash     BLOB NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  color_index  INTEGER NOT NULL DEFAULT 0,
  piece_data   BLOB,
  badge_level  INTEGER NOT NULL DEFAULT 0,
  avatar_url   TEXT,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_users_key ON users(key_hash);

CREATE TABLE IF NOT EXISTS tokens (
  token     TEXT PRIMARY KEY,
  user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  issued_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tokens_issued ON tokens(issued_at);
CREATE INDEX IF NOT EXISTS idx_tokens_user ON tokens(user_id);
`
	_, err = db.Exec(schema)
	return err
}

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand の失敗は継続不能
	}
	return hex.EncodeToString(b)
}

// ─── 共通ヘルパ ─────────────────────────────────────────────────────────
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func clientIP(r *http.Request) string {
	// Caddy が付与する X-Forwarded-For の先頭のみ信頼（直前段は自分の管理下）
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.IndexByte(xff, ','); i > 0 {
			return strings.TrimSpace(xff[:i])
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// Bearer トークンからユーザーを特定する。キーはハッシュ照合（DB漏洩時も鍵は復元不能）
func authUser(r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return "", false
	}
	key := strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
	if len(key) < 32 || len(key) > 128 {
		return "", false
	}
	sum := sha256.Sum256([]byte(key))

	var id string
	var stored []byte
	err := db.QueryRow(`SELECT id, key_hash FROM users WHERE key_hash = ?`, sum[:]).Scan(&id, &stored)
	if err != nil {
		return "", false
	}
	// 念のため定数時間比較
	if subtle.ConstantTimeCompare(sum[:], stored) != 1 {
		return "", false
	}
	return id, true
}

// ─── ハンドラ ───────────────────────────────────────────────────────────

// POST /v1/auth/anon — 匿名ユーザー作成（Supabase の signInAnonymously 相当）
// 返す api_key は端末の SecureStorage に保存され、以後の認証に使う。
// 有効期限を持たないため、旧実装で起きた「約6時間でセッション失効し同期が止まる」問題が起きない。
func handleAuthAnon(w http.ResponseWriter, r *http.Request) {
	if !signupLimiter.allow(clientIP(r)) {
		writeErr(w, http.StatusTooManyRequests, "too many signups")
		return
	}
	id := randHex(16)
	key := randHex(32)
	sum := sha256.Sum256([]byte(key))
	now := time.Now().Unix()

	_, err := db.Exec(
		`INSERT INTO users (id, key_hash, created_at, updated_at) VALUES (?, ?, ?, ?)`,
		id, sum[:], now, now)
	if err != nil {
		log.Printf("auth/anon insert: %v", err)
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"user_id": id, "api_key": key})
}

// POST /v1/tokens/issue — BLEで流す使い捨てトークンを発行（issue_token RPC 相当）
func handleIssueToken(w http.ResponseWriter, r *http.Request) {
	uid, ok := authUser(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	token := randHex(16) // 16byte = 32hex（BLEペイロードの仕様どおり）
	now := time.Now()
	if _, err := db.Exec(
		`INSERT INTO tokens (token, user_id, issued_at) VALUES (?, ?, ?)`,
		token, uid, now.Unix()); err != nil {
		log.Printf("issue_token: %v", err)
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	// 同一ユーザーの古いトークンを整理（DB肥大防止）。直近3本だけ残す。
	_, _ = db.Exec(`DELETE FROM tokens WHERE user_id = ? AND token NOT IN (
	                  SELECT token FROM tokens WHERE user_id = ? ORDER BY issued_at DESC LIMIT 3)`, uid, uid)

	writeJSON(w, http.StatusOK, map[string]any{
		"token":      token,
		"expires_at": now.Add(tokenTTL).Unix(),
	})
}

type resolveReq struct {
	Tokens []string `json:"tokens"`
}

type resolvedUser struct {
	Token       string `json:"token"`
	UserID      string `json:"user_id"`
	DisplayName string `json:"display_name"`
	ColorIndex  int    `json:"color_index"`
	PieceData   []int  `json:"piece_data"`
	BadgeLevel  int    `json:"badge_level"`
	AvatarURL   string `json:"avatar_url,omitempty"`
}

// POST /v1/tokens/resolve — 収集したトークンを相手プロフィールへ解決（resolve_tokens RPC 相当）
func handleResolveTokens(w http.ResponseWriter, r *http.Request) {
	uid, ok := authUser(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var req resolveReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad request")
		return
	}
	if len(req.Tokens) == 0 {
		writeJSON(w, http.StatusOK, []resolvedUser{})
		return
	}
	if len(req.Tokens) > maxResolveList {
		req.Tokens = req.Tokens[:maxResolveList]
	}

	// 期限切れトークンの掃除（旧SupabaseのRPCと同じ挙動。DB使用量を自動で抑える）
	_, _ = db.Exec(`DELETE FROM tokens WHERE issued_at < ?`, time.Now().Add(-resolveWindow).Unix())

	// プレースホルダを組み立て（値はバインドするのでSQLインジェクションは発生しない）
	args := make([]any, 0, len(req.Tokens))
	ph := make([]string, 0, len(req.Tokens))
	for _, t := range req.Tokens {
		t = strings.ToLower(strings.TrimSpace(t))
		if len(t) != 32 { // 16byteのhexのみ受理
			continue
		}
		if _, err := hex.DecodeString(t); err != nil {
			continue
		}
		args = append(args, t)
		ph = append(ph, "?")
	}
	if len(args) == 0 {
		writeJSON(w, http.StatusOK, []resolvedUser{})
		return
	}

	q := `SELECT t.token, u.id, u.display_name, u.color_index, u.piece_data, u.badge_level, COALESCE(u.avatar_url,'')
	      FROM tokens t JOIN users u ON u.id = t.user_id
	      WHERE t.token IN (` + strings.Join(ph, ",") + `)`
	rows, err := db.Query(q, args...)
	if err != nil {
		log.Printf("resolve: %v", err)
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	defer rows.Close()

	out := []resolvedUser{}
	for rows.Next() {
		var ru resolvedUser
		var packed []byte
		if err := rows.Scan(&ru.Token, &ru.UserID, &ru.DisplayName, &ru.ColorIndex,
			&packed, &ru.BadgeLevel, &ru.AvatarURL); err != nil {
			continue
		}
		if ru.UserID == uid {
			continue // 自分は除外
		}
		ru.PieceData = unpackPixels(packed)
		out = append(out, ru)
	}
	writeJSON(w, http.StatusOK, out)
}

type profileReq struct {
	DisplayName *string `json:"display_name"`
	ColorIndex  *int    `json:"color_index"`
	PieceData   []int   `json:"piece_data"`
	BadgeLevel  *int    `json:"badge_level"`
}

// POST /v1/profile — 自分のプロフィール更新（users テーブル upsert 相当）
func handleProfile(w http.ResponseWriter, r *http.Request) {
	uid, ok := authUser(r)
	if !ok {
		writeErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var req profileReq
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad request")
		return
	}

	sets := []string{"updated_at = ?"}
	args := []any{time.Now().Unix()}

	if req.DisplayName != nil {
		n := strings.TrimSpace(*req.DisplayName)
		if len([]rune(n)) > maxNameRunes {
			n = string([]rune(n)[:maxNameRunes])
		}
		sets = append(sets, "display_name = ?")
		args = append(args, n)
	}
	if req.ColorIndex != nil {
		c := *req.ColorIndex
		if c < 0 || c > 63 {
			c = 0
		}
		sets = append(sets, "color_index = ?")
		args = append(args, c)
	}
	if req.BadgeLevel != nil {
		b := *req.BadgeLevel
		if b < 0 {
			b = 0
		}
		if b > 255 {
			b = 255
		}
		sets = append(sets, "badge_level = ?")
		args = append(args, b)
	}
	if req.PieceData != nil {
		packed, err := packPixels(req.PieceData)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "invalid piece_data")
			return
		}
		sets = append(sets, "piece_data = ?")
		args = append(args, packed)
	}

	args = append(args, uid)
	if _, err := db.Exec(`UPDATE users SET `+strings.Join(sets, ", ")+` WHERE id = ?`, args...); err != nil {
		log.Printf("profile: %v", err)
		writeErr(w, http.StatusInternalServerError, "server error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// GET /v1/health — 監視用（認証不要・内部情報は出さない）
func handleHealth(w http.ResponseWriter, r *http.Request) {
	if err := db.Ping(); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "db down")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// ─── ミドルウェア ───────────────────────────────────────────────────────
func withCommon(next http.HandlerFunc, method string, limited bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != method {
			w.Header().Set("Allow", method)
			writeErr(w, http.StatusMethodNotAllowed, "method not allowed")
			return
		}
		if limited && !apiLimiter.allow(clientIP(r)) {
			writeErr(w, http.StatusTooManyRequests, "rate limited")
			return
		}
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Cache-Control", "no-store")
		next(w, r)
	}
}

// dbPath と同じディレクトリ配下に sub を作ったパスを返す（path/filepath を持ち込まない軽量版）
func filepathJoin(dbPath, sub string) string {
	i := strings.LastIndexByte(dbPath, '/')
	if i < 0 {
		return sub
	}
	return dbPath[:i] + "/" + sub
}

// 指定世代数を超える古いバックアップを削除する（ディスクを一定量に保つ）
func pruneBackups(dir string, keep int) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() && strings.HasPrefix(e.Name(), "app-") && strings.HasSuffix(e.Name(), ".db") {
			names = append(names, e.Name())
		}
	}
	if len(names) <= keep {
		return
	}
	sortStrings(names) // 日付形式なので辞書順＝時系列順
	for _, n := range names[:len(names)-keep] {
		_ = os.Remove(dir + "/" + n)
	}
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

func main() {
	dbPath := os.Getenv("DB_PATH")
	if dbPath == "" {
		dbPath = "/data/app.db"
	}
	if err := initDB(dbPath); err != nil {
		log.Fatalf("db init: %v", err)
	}
	defer db.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("/v1/health", withCommon(handleHealth, http.MethodGet, false))
	mux.HandleFunc("/v1/auth/anon", withCommon(handleAuthAnon, http.MethodPost, false))
	mux.HandleFunc("/v1/tokens/issue", withCommon(handleIssueToken, http.MethodPost, true))
	mux.HandleFunc("/v1/tokens/resolve", withCommon(handleResolveTokens, http.MethodPost, true))
	mux.HandleFunc("/v1/profile", withCommon(handleProfile, http.MethodPost, true))

	srv := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    8 << 10,
	}

	// 定期メンテナンス: 期限切れトークンの掃除 + バックアップ世代管理。
	// 別プロセス・別イメージを立てずにAPI内で完結させ、常駐リソースを増やさない。
	go func() {
		backupDir := filepathJoin(dbPath, "backups")
		_ = os.MkdirAll(backupDir, 0o700)
		time.Sleep(30 * time.Second) // 起動直後に1回（デプロイ直後の復旧点を確保）
		for {
			if res, err := db.Exec(`DELETE FROM tokens WHERE issued_at < ?`,
				time.Now().Add(-resolveWindow).Unix()); err == nil {
				n, _ := res.RowsAffected()
				if n > 0 {
					log.Printf("gc: removed %d expired tokens", n)
				}
				_, _ = db.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`)
			}

			// VACUUM INTO は断片化を除いた最小サイズの複製を作る（圧縮を兼ねる）
			dst := backupDir + "/app-" + time.Now().Format("20060102") + ".db"
			_ = os.Remove(dst) // 同日分は上書き
			if _, err := db.Exec(`VACUUM INTO ?`, dst); err != nil {
				log.Printf("backup: %v", err)
			} else {
				pruneBackups(backupDir, 7) // 7世代だけ残す
			}

			time.Sleep(6 * time.Hour)
		}
	}()

	go func() {
		log.Println("api listening on :8080")
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	log.Println("shutdown complete")
}
