import 'package:flutter/material.dart';
import '../models/dot_avatar.dart';
import '../models/piece_data.dart';
import '../services/api_service.dart';
import 'theme/palette.dart';
import 'widgets/ui_kit.dart';
import 'widgets/user_icon.dart';

/// ドット絵アイコンエディタ（16x16 / 32x32）
/// ペン・塗りつぶし・消しゴム・アンドゥ・即時プレビュー・保存
class AvatarEditorScreen extends StatefulWidget {
  const AvatarEditorScreen({super.key});

  @override
  State<AvatarEditorScreen> createState() => _AvatarEditorScreenState();
}

enum _Tool { pen, fill, eraser }

class _AvatarEditorScreenState extends State<AvatarEditorScreen> {
  DotAvatar _avatar = DotAvatar(size: 16);
  final List<List<int>> _history = [];
  int _color = 14; // 黒
  _Tool _tool = _Tool.pen;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    DotAvatarStorage.load().then((a) {
      if (mounted) {
        setState(() {
          if (a != null) _avatar = a;
          _loaded = true;
        });
      }
    });
  }

  void _pushHistory() {
    _history.add(List<int>.from(_avatar.pixels));
    if (_history.length > 60) _history.removeAt(0);
  }

  void _undo() {
    if (_history.isEmpty) return;
    setState(() {
      _avatar = DotAvatar(size: _avatar.size, pixels: _history.removeLast());
    });
  }

  void _clear() {
    _pushHistory();
    setState(() => _avatar = DotAvatar(size: _avatar.size));
  }

  void _switchSize(int newSize) {
    if (newSize == _avatar.size) return;
    _history.clear();
    setState(() {
      final old = _avatar;
      final next = DotAvatar(size: newSize);
      // 16→32 は2倍拡大、32→16 は間引きで引き継ぐ
      for (int y = 0; y < newSize; y++) {
        for (int x = 0; x < newSize; x++) {
          final sx = (x * old.size / newSize).floor();
          final sy = (y * old.size / newSize).floor();
          next.setPixel(x, y, old.getPixel(sx, sy));
        }
      }
      _avatar = next;
    });
  }

  void _applyAt(int x, int y, {required bool isNewStroke}) {
    if (x < 0 || x >= _avatar.size || y < 0 || y >= _avatar.size) return;
    final paintColor = _tool == _Tool.eraser ? PieceData.transparent : _color;
    if (_tool == _Tool.fill) {
      if (!isNewStroke) return;
      _pushHistory();
      setState(() {
        final next = DotAvatar.clone(_avatar);
        next.fill(x, y, paintColor);
        _avatar = next;
      });
      return;
    }
    if (_avatar.getPixel(x, y) == paintColor) return;
    if (isNewStroke) _pushHistory();
    setState(() {
      final next = DotAvatar.clone(_avatar);
      next.setPixel(x, y, paintColor);
      _avatar = next;
    });
  }

  Future<void> _save() async {
    await DotAvatarStorage.save(_avatar);
    OwnAvatarNotifier.update(_avatar); // 全画面のUserIconを即時更新
    // サーバーへ同期（すれ違った相手の Today/広場/カケラ にこの絵が表示される）
    // 失敗しても起動時 start() で再同期されるため best-effort
    if (!_avatar.isEmpty) {
      ApiService.savePieceData(_avatar.toPiecePixels());
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('アイコンを保存しました！')),
    );
    Navigator.pop(context, _avatar);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.cream,
      body: !_loaded
          ? Center(child: CircularProgressIndicator(color: Palette.coral))
          : Column(
              children: [
                ScreenHeader(
                  title: 'アイコンをつくる',
                  emoji: '🎨',
                  trailing: Row(
                    children: [
                      RoundIconButton(icon: Icons.undo, onTap: _undo),
                      const SizedBox(width: 8),
                      RoundIconButton(icon: Icons.delete_outline, onTap: _clear),
                      const SizedBox(width: 8),
                      RoundIconButton(
                          icon: Icons.close,
                          onTap: () => Navigator.pop(context)),
                    ],
                  ),
                ),

                // プレビュー＋サイズ切替
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: Row(
                    children: [
                      SoftPanel(
                        padding: const EdgeInsets.all(8),
                        child: DotAvatarView(avatar: _avatar, sizePx: 56),
                      ),
                      const SizedBox(width: 8),
                      SoftPanel(
                        padding: const EdgeInsets.all(6),
                        child: DotAvatarView(avatar: _avatar, sizePx: 28, radius: 8),
                      ),
                      const Spacer(),
                      _SizeToggle(
                        size: _avatar.size,
                        onChanged: _switchSize,
                      ),
                    ],
                  ),
                ),

                // キャンバス
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: SoftPanel(
                          padding: const EdgeInsets.all(8),
                          child: _EditorCanvas(
                            avatar: _avatar,
                            onPaint: _applyAt,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // ツール選択
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _ToolButton(
                        emoji: '✏️', label: 'ペン',
                        selected: _tool == _Tool.pen,
                        onTap: () => setState(() => _tool = _Tool.pen),
                      ),
                      const SizedBox(width: 10),
                      _ToolButton(
                        emoji: '🪣', label: '塗る',
                        selected: _tool == _Tool.fill,
                        onTap: () => setState(() => _tool = _Tool.fill),
                      ),
                      const SizedBox(width: 10),
                      _ToolButton(
                        emoji: '🧽', label: '消す',
                        selected: _tool == _Tool.eraser,
                        onTap: () => setState(() => _tool = _Tool.eraser),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                // パレット
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    alignment: WrapAlignment.center,
                    children: List.generate(PieceData.palette.length, (i) {
                      if (i == PieceData.transparent) {
                        return const SizedBox.shrink();
                      }
                      final sel = i == _color && _tool != _Tool.eraser;
                      return GestureDetector(
                        onTap: () => setState(() {
                          _color = i;
                          if (_tool == _Tool.eraser) _tool = _Tool.pen;
                        }),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          width: sel ? 36 : 30,
                          height: sel ? 36 : 30,
                          decoration: BoxDecoration(
                            color: PieceData.palette[i],
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: sel ? Palette.ink : Colors.white,
                              width: sel ? 2.5 : 1.5,
                            ),
                            boxShadow: sel ? Palette.lift() : null,
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                const SizedBox(height: 14),

                // 保存
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: ChunkyButton(
                    label: 'このアイコンにする',
                    emoji: '✨',
                    onTap: _save,
                  ),
                ),
              ],
            ),
    );
  }
}

// ─── サイズ切替（16/32）──────────────────────────────────────────────────────
class _SizeToggle extends StatelessWidget {
  final int size;
  final ValueChanged<int> onChanged;
  const _SizeToggle({required this.size, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget seg(int s) {
      final sel = size == s;
      return GestureDetector(
        onTap: () => onChanged(s),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: sel ? Palette.coral : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text('$s×$s',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: sel ? Colors.white : Palette.inkSoft)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Palette.creamDeep,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(children: [seg(16), seg(32)]),
    );
  }
}

// ─── ツールボタン ────────────────────────────────────────────────────────────
class _ToolButton extends StatelessWidget {
  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ToolButton({
    required this.emoji,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? Palette.teal : Palette.card,
          borderRadius: BorderRadius.circular(20),
          boxShadow: Palette.lift(selected ? Palette.tealDeep : null),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : Palette.ink)),
          ],
        ),
      ),
    );
  }
}

// ─── 描画キャンバス ──────────────────────────────────────────────────────────
class _EditorCanvas extends StatelessWidget {
  final DotAvatar avatar;
  final void Function(int x, int y, {required bool isNewStroke}) onPaint;

  const _EditorCanvas({required this.avatar, required this.onPaint});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final side = constraints.maxWidth;
      void handle(Offset local, bool isNew) {
        final cell = side / avatar.size;
        onPaint((local.dx / cell).floor(), (local.dy / cell).floor(),
            isNewStroke: isNew);
      }

      return GestureDetector(
        onTapDown: (d) => handle(d.localPosition, true),
        onPanStart: (d) => handle(d.localPosition, true),
        onPanUpdate: (d) => handle(d.localPosition, false),
        child: CustomPaint(
          size: Size.square(side),
          painter: _GridCanvasPainter(avatar: avatar),
        ),
      );
    });
  }
}

class _GridCanvasPainter extends CustomPainter {
  final DotAvatar avatar;
  _GridCanvasPainter({required this.avatar});

  @override
  void paint(Canvas canvas, Size size) {
    final n = avatar.size;
    final cell = size.width / n;
    final paint = Paint();

    for (int y = 0; y < n; y++) {
      for (int x = 0; x < n; x++) {
        final idx = avatar.getPixel(x, y);
        // 透明は市松模様で示す
        if (idx == PieceData.transparent) {
          paint.color = (x + y) % 2 == 0
              ? const Color(0xFFF3E7D3)
              : const Color(0xFFEADDC5);
        } else {
          paint.color = PieceData.paletteColor(idx);
        }
        canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), paint);
      }
    }
    // グリッド線
    final grid = Paint()
      ..color = const Color(0x224A3C31)
      ..strokeWidth = 0.5;
    for (int i = 0; i <= n; i++) {
      canvas.drawLine(Offset(i * cell, 0), Offset(i * cell, size.height), grid);
      canvas.drawLine(Offset(0, i * cell), Offset(size.width, i * cell), grid);
    }
  }

  @override
  bool shouldRepaint(covariant _GridCanvasPainter old) => true;
}
