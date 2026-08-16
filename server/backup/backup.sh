#!/bin/sh
# DBバックアップをGoogle Driveへ退避する。
#
# APIコンテナが6時間ごとに VACUUM INTO で作る /data/backups/app-YYYYMMDD.db を
# 暗号化してアップロードする。サーバーが失われても復元できる状態を保つのが目的。
#
# 実行: cron から毎日1回。手動確認は `sh backup.sh` でよい。
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)"
VOLUME=server_api-data
REMOTE=gdrive-crypt:hajimemashite
KEEP_DAYS=30
STAGING="$DIR/staging"
LOG="$DIR/backup.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

mkdir -p "$STAGING"

# 1) ボリューム内の最新バックアップを取り出す
#    （APIは非rootで動くためファイル所有者は10001。rootのalpineで読み出す）
docker run --rm \
  -v "$VOLUME":/d:ro \
  -v "$STAGING":/out \
  alpine sh -c '
    set -e
    latest=$(ls -1 /d/backups/app-*.db 2>/dev/null | sort | tail -1)
    [ -n "$latest" ] || { echo "no backup file found" >&2; exit 1; }
    cp "$latest" /out/
    echo "$latest"
  ' > "$STAGING/.latest" 2>>"$LOG"

FILE=$(basename "$(cat "$STAGING/.latest")")
log "staged $FILE"

# 2) 暗号化してアップロード（rcloneはコンテナで動かす。ホストには入れない）
docker run --rm \
  -v "$DIR/rclone.conf":/config/rclone/rclone.conf:ro \
  -v "$STAGING":/data:ro \
  rclone/rclone copy "/data/$FILE" "$REMOTE" >> "$LOG" 2>&1

log "uploaded $FILE"

# 3) 30日より古い世代をリモートから削除
docker run --rm \
  -v "$DIR/rclone.conf":/config/rclone/rclone.conf:ro \
  rclone/rclone delete "$REMOTE" --min-age "${KEEP_DAYS}d" >> "$LOG" 2>&1

COUNT=$(docker run --rm \
  -v "$DIR/rclone.conf":/config/rclone/rclone.conf:ro \
  rclone/rclone lsf "$REMOTE" 2>>"$LOG" | wc -l)
log "remote generations: $COUNT"

# 4) 手元の一時ファイルは残さない
rm -f "$STAGING"/*.db "$STAGING/.latest"

# 5) ログが無限に伸びないよう直近500行だけ残す
tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
