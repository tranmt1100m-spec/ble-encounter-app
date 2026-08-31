import 'package:flutter/material.dart';
import 'theme/palette.dart';
import 'widgets/ui_kit.dart';

/// 未完成機能を一時的に隠すための汎用プレースホルダー画面。
///
/// 機能そのものは削除せず、呼び出し元でフラグ分岐して差し替える運用にする
/// （例: lib/core/ble_config.dart の kGameTabEnabled）。
class ComingSoonScreen extends StatelessWidget {
  final String title;
  final String asset;
  final String message;

  const ComingSoonScreen({
    super.key,
    required this.title,
    required this.asset,
    this.message = '準備中だよ。もう少し待っててね',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Palette.cream,
      child: Column(
        children: [
          ScreenHeader(title: title, asset: asset),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SoftPanel(
                  padding: const EdgeInsets.symmetric(
                      vertical: 32, horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('🚧', style: TextStyle(fontSize: 52)),
                      const SizedBox(height: 14),
                      Text('近日公開',
                          style: Ts.title.copyWith(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      Text(message,
                          style: Ts.caption, textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
