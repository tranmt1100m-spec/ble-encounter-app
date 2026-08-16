# DESIGN_HANDOFF.md — UIブラッシュアップをデザイン側へ引き継ぐ手順

別セッション（デザイン特化のClaude）へUI改善を依頼し、その成果をこのリポジトリへ
戻すための手順書。**渡すもの・貼るプロンプト・返してもらう形式**を固定しておく。

---

## 1. 渡すファイル（この4つで足りる）

| ファイル | 行数 | なぜ必要か |
|---|---|---|
| `lib/ui/theme/palette.dart` | 95 | 配色・テキストスケール・影の定義。**デザインシステムそのもの** |
| `lib/ui/widgets/ui_kit.dart` | 470 | 既存の独自UI部品。ここに無い部品を新設すると世界観が崩れる |
| `PROMPT_GUIDE.md` | 136 | §2 UI方針 / §3 UX方針。Material禁止・ハードコード色禁止などの制約 |
| `CLAUDE.md` | 43 | 絶対維持事項（匿名性・気配演出・開門システム等） |

**改善したい画面のファイルを1つ追加**する（例: `lib/ui/today_screen.dart`）。
全画面を一度に渡すと精度が落ちるので、**1回につき1〜2画面**に絞る。

スクリーンショットも添付するとよい。実機から取得する場合:

```bash
adb exec-out screencap -p > today.png
```

---

## 2. 貼るプロンプト（そのままコピーで使える）

```
Flutterアプリ「はじめましてこんにちは」のUIをブラッシュアップしてください。
Bluetoothですれ違った人との出会いを楽しむコミュニティゲームです（SNSではない）。

添付ファイル:
- palette.dart … 配色・テキストスタイル定義
- ui_kit.dart  … 独自UI部品
- PROMPT_GUIDE.md … UI/UX方針
- CLAUDE.md … 絶対に壊してはいけない仕様
- <対象画面>.dart … 今回改善したい画面

【必ず守ること】
1. Material部品を使わない
   TopAppBar / NavigationBar / FAB / Card / Dialog は禁止。
   ui_kit.dart の SoftPanel / ChunkyButton / RoundIconButton / ScreenHeader /
   GameDock / SpeechBubble / StatChip / SectionLabel / CandyProgress を使う。
2. 色をハードコードしない
   必ず Palette の getter を使う（Palette.cream / ink / coral / teal など）。
   ライト=昼の広場（クリーム×パステル）、ダーク=夜の広場（藍×提灯色）の
   両方で成立させる。const TextStyle に Palette の色を入れない
   （Palette.night 切り替えに追従しなくなるため）。
3. 影は Palette.lift() / liftBig() を使う（ぼかさないハードシャドウ）
4. 文体はひらがな多めで温かく（「じぶん」「カケラ」「〜だよ」）
5. 数値を生で出さない（回数→抽象ラベル、時刻→時間帯表現）
6. アイコンは assets/icons・assets/gate のピクセルアイコン。絵文字アイコン禁止
   （文章内の絵文字装飾は可）

【出力形式】
- 変更後の Dart コードを**ファイル単位の全文**で返す（差分ではなく全文）
- 新しい共通部品を作った場合は ui_kit.dart への追加分も全文で返す
- 冒頭に「何をなぜ変えたか」を5行以内で書く
- pubspec への依存追加は避ける。どうしても必要なら理由を明記する

まず現状の課題を指摘してから、改善案を実装してください。
```

---

## 3. 成果をこのリポジトリへ戻す方法

**返ってきたDartコードをそのまま貼るだけでよい。** こちら側で以下を行う。

1. 該当ファイルへ反映
2. `flutter analyze` / `flutter test`（37件の回帰テスト）
3. 実機ビルド＆インストール、画面を目視確認
4. 問題なければ commit / push / Obsidian同期

デザイン側が制約を外していた場合（Material部品・ハードコード色など）は、
こちらで**世界観に合わせて直してから**取り込む。丸ごと捨てることはしない。

### レビュー時に必ず見る点

| 観点 | 確認内容 |
|---|---|
| 夜モード | `Palette.night = true` で崩れないか（設定画面から切替可能） |
| 端末差 | Pixel 5(1080x2340) と A202SH(1260x2730) の両方で確認 |
| 絶対維持事項 | 開門前に相手情報が出ていないか、正確な時刻が出ていないか |
| 回帰テスト | 37件が通るか |

---

## 4. 既知のUI課題（改善候補）

- **横向き時のオンボーディングが崩れる** — 説明文とページインジケータが重なる
  （`lib/ui/onboarding_screen.dart`）。縦向きでは問題なし
- `today_screen.dart` が1097行と大きく、部品の切り出し余地がある

---

関連: [PROMPT_GUIDE.md](PROMPT_GUIDE.md) / [CLAUDE.md](CLAUDE.md)
