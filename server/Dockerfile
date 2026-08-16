# 多段ビルド: ホストにGoツールチェーンを入れずに静的バイナリを作る。
# 最終イメージは scratch ベースで約15MB（ディスク節約）。
FROM golang:1.23-alpine AS build
WORKDIR /src

# 依存だけ先に取得してレイヤキャッシュを効かせる
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true

COPY main.go ./
RUN go mod tidy && \
    CGO_ENABLED=0 GOOS=linux go build \
      -trimpath -ldflags="-s -w" -o /out/api .

# 実行ユーザー(10001)が書ける /data をイメージ内に用意しておく。
# Dockerは名前付きボリューム初回作成時にイメージ側の所有権ごと引き継ぐため、
# これで非rootコンテナでもSQLiteが書き込める（chownのための特権が不要）。
RUN mkdir -p /out/data && chown -R 10001:10001 /out/data

# ─── 実行イメージ ───────────────────────────────────────────────────────
FROM scratch
# TLS検証用のCA証明書（外部通信はしないが将来用に最小限だけ同梱）
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/api /api
COPY --from=build --chown=10001:10001 /out/data /data

# 非rootで動かす（scratchなのでUID指定のみ。/data はcomposeでvolumeを割り当て）
USER 10001:10001
ENV DB_PATH=/data/app.db
EXPOSE 8080
ENTRYPOINT ["/api"]
