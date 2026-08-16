import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/piece_data.dart';
import '../../services/piece_storage.dart';
import '../../services/api_service.dart';
import '../../providers/ble_providers.dart' show appProvider;

// ─── Provider ───────────────────────────────────────────────────────────────

final _editorProvider = StateNotifierProvider.autoDispose<_EditorNotifier, _EditorState>(
  (ref) => _EditorNotifier(),
);

class _EditorState {
  final PieceData piece;
  final int       selectedColor;
  final List<List<int>> history; // undo用

  const _EditorState({
    required this.piece,
    required this.selectedColor,
    required this.history,
  });

  _EditorState copyWith({PieceData? piece, int? selectedColor, List<List<int>>? history}) =>
      _EditorState(
        piece:         piece         ?? this.piece,
        selectedColor: selectedColor ?? this.selectedColor,
        history:       history       ?? this.history,
      );
}

class _EditorNotifier extends StateNotifier<_EditorState> {
  _EditorNotifier()
      : super(_EditorState(
          piece:         PieceData(),
          selectedColor: 14, // 黒
          history:       [],
        ));

  void load(PieceData piece) {
    state = state.copyWith(piece: PieceData.clone(piece));
  }

  void selectColor(int c) => state = state.copyWith(selectedColor: c);

  void paint(int x, int y) {
    if (x < 0 || x >= PieceData.gridSize || y < 0 || y >= PieceData.gridSize) return;
    if (state.piece.getPixel(x, y) == state.selectedColor) return;
    final snapshot = List<int>.from(state.piece.pixels);
    final newPiece = PieceData.clone(state.piece);
    newPiece.setPixel(x, y, state.selectedColor);
    state = state.copyWith(
      piece:   newPiece,
      history: [...state.history, snapshot],
    );
  }

  void undo() {
    if (state.history.isEmpty) return;
    final prev = state.history.last;
    state = state.copyWith(
      piece:   PieceData(pixels: prev),
      history: state.history.sublist(0, state.history.length - 1),
    );
  }

  void clear() {
    final snapshot = List<int>.from(state.piece.pixels);
    state = state.copyWith(
      piece:   PieceData(),
      history: [...state.history, snapshot],
    );
  }
}

// ─── Screen ─────────────────────────────────────────────────────────────────

class PieceEditorScreen extends ConsumerStatefulWidget {
  const PieceEditorScreen({super.key});

  @override
  ConsumerState<PieceEditorScreen> createState() => _PieceEditorScreenState();
}

class _PieceEditorScreenState extends ConsumerState<PieceEditorScreen> {
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // 既存のピースをロード
    OwnPieceStorage.load().then((p) {
      if (p != null && mounted) {
        ref.read(_editorProvider.notifier).load(p);
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final piece = ref.read(_editorProvider).piece;
    await OwnPieceStorage.save(piece);
    final ok = await ApiService.savePieceData(piece.toJson());

    // プロフィールと同期
    final profile = ref.read(appProvider).ownProfile;
    if (profile != null) {
      await ApiService.syncProfile(
        displayName: profile.name,
        colorIndex:  profile.colorIndex,
        piecePixels: piece.toJson(),
      );
    }

    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'ピースを保存しました！' : 'ローカルのみ保存（サーバー未接続）'),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(_editorProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A1A),
        foregroundColor: Colors.white,
        title: const Text('マイピースを描く', style: TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: state.history.isEmpty ? null : ref.read(_editorProvider.notifier).undo,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: ref.read(_editorProvider.notifier).clear,
          ),
          IconButton(
            icon: _saving
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save),
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: Column(
        children: [
          // プレビュー（縮小表示）
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _PieceThumbnail(piece: state.piece, size: 48),
                const SizedBox(width: 12),
                const Text('プレビュー',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
          // キャンバス（タッチ描画）— 常に正方形
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _PixelCanvas(
                    piece:         state.piece,
                    selectedColor: state.selectedColor,
                    onPaint:       ref.read(_editorProvider.notifier).paint,
                  ),
                ),
              ),
            ),
          ),
          // カラーパレット
          _ColorPalette(
            selected: state.selectedColor,
            onSelect: ref.read(_editorProvider.notifier).selectColor,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ─── Canvas ──────────────────────────────────────────────────────────────────

class _PixelCanvas extends StatelessWidget {
  final PieceData piece;
  final int       selectedColor;
  final void Function(int x, int y) onPaint;

  const _PixelCanvas({
    required this.piece,
    required this.selectedColor,
    required this.onPaint,
  });

  Offset _toCell(Offset local, Size size) {
    final cellW = size.width  / PieceData.gridSize;
    final cellH = size.height / PieceData.gridSize;
    return Offset((local.dx / cellW).floorToDouble(), (local.dy / cellH).floorToDouble());
  }

  void _handle(Offset local, Size size) {
    final c = _toCell(local, size);
    onPaint(c.dx.toInt(), c.dy.toInt());
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      return GestureDetector(
        onPanStart:  (d) => _handle(d.localPosition, size),
        onPanUpdate: (d) => _handle(d.localPosition, size),
        onTapDown:   (d) => _handle(d.localPosition, size),
        child: CustomPaint(
          size: size,
          painter: _CanvasPainter(piece: piece, selectedColor: selectedColor),
        ),
      );
    });
  }
}

class _CanvasPainter extends CustomPainter {
  final PieceData piece;
  final int       selectedColor;

  _CanvasPainter({required this.piece, required this.selectedColor});

  @override
  void paint(Canvas canvas, Size size) {
    final g    = PieceData.gridSize;
    final cw   = size.width  / g;
    final ch   = size.height / g;
    final bg   = const Color(0xFF1A1A2E);
    final grid = const Color(0x33FFFFFF);

    for (int y = 0; y < g; y++) {
      for (int x = 0; x < g; x++) {
        final idx   = piece.getPixel(x, y);
        final color = idx == PieceData.transparent ? bg : PieceData.paletteColor(idx);
        final rect  = Rect.fromLTWH(x * cw, y * ch, cw, ch);
        canvas.drawRect(rect, Paint()..color = color);
        canvas.drawRect(rect, Paint()
          ..color = grid
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5);
      }
    }
  }

  @override
  bool shouldRepaint(_CanvasPainter old) => true;
}

// ─── Palette ─────────────────────────────────────────────────────────────────

class _ColorPalette extends StatelessWidget {
  final int    selected;
  final void Function(int) onSelect;

  const _ColorPalette({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF111122),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        alignment: WrapAlignment.center,
        children: List.generate(PieceData.palette.length, (i) {
          if (i == PieceData.transparent) return const SizedBox.shrink(); // 透明は別枠
          final isSelected = i == selected;
          return GestureDetector(
            onTap: () => onSelect(i),
            child: Container(
              width: 30, height: 30,
              decoration: BoxDecoration(
                color: PieceData.palette[i],
                border: Border.all(
                  color: isSelected ? Colors.white : Colors.white24,
                  width: isSelected ? 2.5 : 1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ─── Thumbnail ───────────────────────────────────────────────────────────────

class PieceThumbnailWidget extends StatelessWidget {
  final PieceData piece;
  final double    size;
  final bool      locked;

  const PieceThumbnailWidget({
    super.key,
    required this.piece,
    this.size = 48,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    if (locked) {
      return Container(
        width: size, height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.white12),
        ),
        child: Center(
          child: Icon(Icons.lock_outline, color: Colors.white24, size: size * 0.4),
        ),
      );
    }
    return _PieceThumbnail(piece: piece, size: size);
  }
}

class _PieceThumbnail extends StatefulWidget {
  final PieceData piece;
  final double    size;
  const _PieceThumbnail({required this.piece, required this.size});

  @override
  State<_PieceThumbnail> createState() => _PieceThumbnailState();
}

class _PieceThumbnailState extends State<_PieceThumbnail> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _buildImage();
  }

  @override
  void didUpdateWidget(_PieceThumbnail old) {
    super.didUpdateWidget(old);
    _buildImage();
  }

  Future<void> _buildImage() async {
    // toArgbList は 0xAARRGGBB の Uint32。リトルエンディアンでバイト列にすると
    // B,G,R,A の順になるため、PixelFormat は bgra8888 を使う（rgba8888 だと赤青反転）。
    final argb = widget.piece.toArgbList();
    final codec = await ui.ImageDescriptor.raw(
      await ui.ImmutableBuffer.fromUint8List(
        Uint8List.sublistView(argb.buffer.asByteData()),
      ),
      width:            PieceData.gridSize,
      height:           PieceData.gridSize,
      pixelFormat:      ui.PixelFormat.bgra8888,
    ).instantiateCodec();
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _image = frame.image);
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) {
      return SizedBox(width: widget.size, height: widget.size);
    }
    // AspectRatio で常に正方形を保証（縦長/横長に潰れない）
    final img = RawImage(
      image:         _image,
      filterQuality: FilterQuality.none, // ピクセルアート用（補間なし）
      fit:           BoxFit.contain,
    );
    if (widget.size == double.infinity) {
      return AspectRatio(aspectRatio: 1, child: img);
    }
    return SizedBox(
      width:  widget.size,
      height: widget.size,
      child:  img,
    );
  }
}
