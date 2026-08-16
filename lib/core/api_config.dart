/// 自前APIサーバーの接続先。
///
/// さくらのVPS上で Caddy(自動TLS) + Go/SQLite の構成で稼働。
/// ドメインは sslip.io（IPをそのまま名前解決する公開DNS）を利用しているため、
/// 独自ドメインを取得したらこの1行を差し替えるだけで移行できる。
const apiBaseUrl = 'https://153-125-148-69.sslip.io/v1';
