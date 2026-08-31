// BLE 動作設定
// kDebugBle = true  → 高頻度スキャン・ゲート常時開放（実機テスト用）
// kDebugBle = false → 本番設定（実機ログ解析で最適化済み）
const bool kDebugBle = false;

// スキャン ON 秒数（固定）
const int kScanOnSeconds = kDebugBle ? 12 : 15;

// ゲート制御
const bool kGateAlwaysOpen = kDebugBle; // デバッグ時は常時開放

// ミニゲーム機能フラグ。
// 4種のゲーム(ピース集め/タワーRPG/水族館/しんけいすいじゃく)は
// 未検証の不具合が多く残っているため、リリースを急ぐ間は「近日公開」の
// プレースホルダーに差し替える。falseにするだけで元の実装へ復帰できる
// （lib/ui/home_screen.dart 参照）。ゲーム自体のコードは削除していない。
const bool kGameTabEnabled = false;

// ─── スキャン間隔設定 ──────────────────────────────────────────────────────────

enum ScanInterval {
  always,  // 常時検出
  one,     // 1分
  two,     // 2分（デフォルト）
  three,   // 3分
  five,    // 5分
  ten,     // 10分
}

extension ScanIntervalX on ScanInterval {
  String get label => switch (this) {
    ScanInterval.always => '常時検出',
    ScanInterval.one    => '1分に1回',
    ScanInterval.two    => '2分に1回',
    ScanInterval.three  => '3分に1回',
    ScanInterval.five   => '5分に1回',
    ScanInterval.ten    => '10分に1回',
  };

  bool get needsBatteryWarning =>
      this == ScanInterval.always || this == ScanInterval.one;

  // 間隔（分単位、always は 0）
  int get intervalMinutes => switch (this) {
    ScanInterval.always => 0,
    ScanInterval.one    => 1,
    ScanInterval.two    => 2,
    ScanInterval.three  => 3,
    ScanInterval.five   => 5,
    ScanInterval.ten    => 10,
  };

  // OFFサイクル秒数（ON=15秒固定、フォールバック用・クロック同期が使えない場合）
  int get offSeconds => kDebugBle ? 48 : switch (this) {
    ScanInterval.always => 2,   // ほぼ常時（短時間のみOFF）
    ScanInterval.one    => 45,  // 1分サイクル
    ScanInterval.two    => 105, // 2分サイクル（デフォルト）
    ScanInterval.three  => 165, // 3分サイクル
    ScanInterval.five   => 285, // 5分サイクル
    ScanInterval.ten    => 585, // 10分サイクル
  };

  static const prefKey = 'scan_interval_v1';

  static ScanInterval fromIndex(int i) =>
      ScanInterval.values.elementAtOrNull(i) ?? ScanInterval.two;
}
