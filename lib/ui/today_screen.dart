import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ble_config.dart';
import '../models/encounter_record.dart';
import '../providers/ble_providers.dart'
    show appProvider, AppState, AppNotifier, scanIntervalProvider;
import 'encounter_helpers.dart';
import 'theme/palette.dart';
import 'widgets/peer_icon.dart';
import 'widgets/ui_kit.dart';

/// 今日タブ = アプリの顔。
/// 「人が集まっている楽しさ」を円弧カルーセルで表現する。
class TodayScreen extends ConsumerStatefulWidget {
  const TodayScreen({super.key});

  @override
  ConsumerState<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends ConsumerState<TodayScreen> {
  Timer? _clockTimer;
  Timer? _bannerTimer;
  bool _showBanner = false;
  final _rng = Random();

  @override
  void initState() {
    super.initState();
    // パフォーマンス: 秒毎の全画面rebuildをやめ、30秒毎の状態同期のみ行う。
    // 秒針カウントダウンは _CountdownText が自前で更新し、
    // 開門瞬間は onDone コールバックで即時反映する。
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _bannerTimer?.cancel();
    super.dispose();
  }

  static DateTime _gateFor(DateTime t) => AppNotifier.gateTimeFor(t);

  /// 画面に並べる開門の一覧（判定は AppNotifier.gatesToShow に集約）。
  List<DateTime> _todayGates() => AppNotifier.gatesToShow(DateTime.now());

  List<EncounterRecord> _forGate(List<EncounterRecord> enc, DateTime gate) =>
      enc.where((e) => _gateFor(e.lastMet) == gate).toList();

  void _onEncounterDetected() {
    if (_bannerTimer != null) return;
    final delay = Duration(minutes: _rng.nextInt(21) + 10);
    _bannerTimer = Timer(delay, () {
      if (mounted) setState(() => _showBanner = true);
    });
  }

  void _onGateRevealed() {
    _bannerTimer?.cancel();
    _bannerTimer = null;
    setState(() => _showBanner = false);
    ref.read(appProvider.notifier).revealToday();
  }

  String _gateLabel(DateTime gate) {
    final now = DateTime.now();
    final isTomorrow =
        gate.year != now.year || gate.month != now.month || gate.day != now.day;
    final base = gate.hour == 9
        ? '朝'
        : gate.hour == 12
            ? '昼'
            : gate.hour == 21
                ? '夜'
                : '${gate.hour}:00';
    return isTomorrow ? 'あしたの$base' : base;
  }

  String _gateAsset(int hour) {
    if (hour == 9) return 'assets/gate/gate_morning.png';
    if (hour == 12) return 'assets/gate/gate_noon.png';
    return 'assets/gate/gate_night.png';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appProvider);

    ref.listen<AppState>(appProvider, (prev, next) {
      if (next.hasNewEncounter && !(prev?.hasNewEncounter ?? false)) {
        _onEncounterDetected();
      }
    });

    final gates = _todayGates();
    final now = DateTime.now();
    final si = ref.watch(scanIntervalProvider);

    final todayRevealed = state.encounters
        .where(
            (e) => e.isRevealed && gates.any((g) => _gateFor(e.lastMet) == g))
        .toList()
      ..sort((a, b) => b.lastMet.compareTo(a.lastMet));

    final todayStart = DateTime(now.year, now.month, now.day);
    final cutoff30 = todayStart.subtract(const Duration(days: 30));
    final recentHistory = state.encounters
        .where((e) =>
            e.isRevealed &&
            e.lastMet.isBefore(todayStart) &&
            e.lastMet.isAfter(cutoff30))
        .toList()
      ..sort((a, b) => b.lastMet.compareTo(a.lastMet));

    return Container(
      color: Palette.cream,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: ScreenHeader(
              title: 'きょうの広場',
              asset: 'assets/icons/tab_today.png',
              trailing: _ScanBadge(running: state.isRunning, si: si),
            ),
          ),

          // ─── すれ違いバナー ───────────────────────────────────
          if (_showBanner)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: SoftPanel(
                  color: Palette.sun.withValues(alpha: 0.25),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Text('👋', style: TextStyle(fontSize: 22)),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '誰かとすれ違えています！\n次の開門時刻に確認できます',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Palette.ink),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ─── 円弧カルーセル（今日出会った人たち）──────────────
          SliverToBoxAdapter(
            child: _MeetingPlaza(
              people: todayRevealed,
              isRunning: state.isRunning,
            ),
          ),

          // ─── 開門ゲート ───────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Column(
                children: gates.map((gate) {
                  final enc = _forGate(state.encounters, gate);
                  final isOpen = kGateAlwaysOpen || now.isAfter(gate);
                  final unrev = enc.where((e) => !e.isRevealed).toList();
                  final revCount = enc.where((e) => e.isRevealed).length;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _GatePanel(
                      asset: _gateAsset(gate.hour),
                      label: _gateLabel(gate),
                      hour: gate.hour,
                      isOpen: isOpen,
                      gateTime: gate,
                      onGateOpen: () {
                        if (mounted) setState(() {});
                      },
                      revCount: revCount,
                      unrevCount: unrev.length,
                      onReveal: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => _SwipeCardScreen(
                              encounters: unrev,
                              onReveal: _onGateRevealed,
                            ),
                            fullscreenDialog: true,
                          ),
                        );
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          // ─── 過去30日の履歴 ────────────────────────────────────
          if (recentHistory.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: SectionLabel('📖', 'さいきんの出会い',
                    trailing: Text('${recentHistory.length}人', style: Ts.caption)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverList.builder(
                itemCount: recentHistory.length,
                itemBuilder: (ctx, i) =>
                    _HistoryTile(encounter: recentHistory[i]),
              ),
            ),
          ],

          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }
}

/// あいまいな出会い時間帯ラベル（正確な時刻・場所は出さない）
String _fuzzyMetLabel(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 60) return '✨ さっき すれ違ったよ';
  final h = t.hour;
  if (h >= 5 && h < 10) return '🌅 あさ すれ違ったよ';
  if (h >= 10 && h < 16) return '☀️ ひるま すれ違ったよ';
  if (h >= 16 && h < 19) return '🌇 ゆうがた すれ違ったよ';
  return '🌙 よる すれ違ったよ';
}

// ─── スキャン状態バッジ ──────────────────────────────────────────────────────
class _ScanBadge extends StatelessWidget {
  final bool running;
  final ScanInterval si;
  const _ScanBadge({required this.running, required this.si});

  @override
  Widget build(BuildContext context) {
    return StatChip(
      emoji: running ? '📡' : '💤',
      label: running ? 'スキャン中' : 'おやすみ中',
      color: running
          ? Palette.teal.withValues(alpha: 0.22)
          : Palette.creamDeep,
    );
  }
}

// ─── 出会いの広場（円弧カルーセル）────────────────────────────────────────────
class _MeetingPlaza extends StatefulWidget {
  final List<EncounterRecord> people;
  final bool isRunning;
  const _MeetingPlaza({required this.people, required this.isRunning});

  @override
  State<_MeetingPlaza> createState() => _MeetingPlazaState();
}

class _MeetingPlazaState extends State<_MeetingPlaza>
    with SingleTickerProviderStateMixin {
  late final PageController _ctrl;
  late final AnimationController _bob; // ぷるぷる待機アニメ
  double _page = 0;
  bool _celebrate = false; // 新しい出会いの祝福演出
  bool _warmup = true; // 起動直後のストレージ復元を「新しい出会い」と誤認しない

  @override
  void initState() {
    super.initState();
    _ctrl = PageController(viewportFraction: 0.31)
      ..addListener(() {
        if (mounted) setState(() => _page = _ctrl.page ?? 0);
      });
    _bob = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat();
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) _warmup = false;
    });
  }

  @override
  void didUpdateWidget(_MeetingPlaza old) {
    super.didUpdateWidget(old);
    // 新規ユーザー出現 → 祝福演出（2.5秒）。起動直後の復元ロードでは出さない
    if (!_warmup && widget.people.length > old.people.length) {
      setState(() => _celebrate = true);
      Future.delayed(const Duration(milliseconds: 2500), () {
        if (mounted) setState(() => _celebrate = false);
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final people = widget.people;

    if (people.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: SoftPanel(
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
          child: Column(
            children: [
              Text(widget.isRunning ? '🔭' : '🌙',
                  style: const TextStyle(fontSize: 52)),
              const SizedBox(height: 12),
              Text(
                widget.isRunning ? 'だれか来ないかな…' : 'スキャンはおやすみ中',
                style: Ts.title,
              ),
              const SizedBox(height: 6),
              Text(
                widget.isRunning
                    ? '外に出て誰かとすれ違うと、ここに集まってくるよ'
                    : '設定からスキャンを再開できます',
                style: Ts.caption,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final centerIdx = _page.round().clamp(0, people.length - 1);
    final center = people[centerIdx];
    final phrase = center.template.phraseText;

    return Column(
      children: [
        const SizedBox(height: 4),
        // 人数（出会いの祝福トーン）
        Text('きょうは ${people.length}人 と出会えたよ 🎊',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w800, color: Palette.ink)),
        const SizedBox(height: 10),

        // 吹き出し（中央の人のひとこと）
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: SpeechBubble(
            key: ValueKey(centerIdx),
            text: '"$phrase"',
          ),
        ),
        const SizedBox(height: 2),

        // 円弧カルーセル（祝福演出をスタック）
        SizedBox(
          height: 168,
          child: Stack(
            children: [
              PageView.builder(
                controller: _ctrl,
                itemCount: people.length,
                itemBuilder: (ctx, i) {
                  final delta = (i - _page);
                  final dist = delta.abs();
                  // 中央が大きく、離れるほど小さく＆下に沈む（円弧）
                  final scale = (1.0 - dist * 0.28).clamp(0.55, 1.0);
                  final dy = pow(dist, 1.5) * 34.0;
                  final opacity = (1.0 - dist * 0.35).clamp(0.35, 1.0);

                  return AnimatedBuilder(
                    animation: _bob,
                    builder: (_, child) {
                      // ぷるぷる待機: 各人が少しずつ違う位相でゆれる
                      final bobDy =
                          sin(_bob.value * 2 * pi + i * 1.3) * 2.5;
                      return Transform.translate(
                        offset: Offset(0, dy + bobDy),
                        child: child,
                      );
                    },
                    child: Transform.scale(
                      scale: scale,
                      child: Opacity(
                        opacity: opacity,
                        child: _PlazaPerson(
                          encounter: people[i],
                          isCenter: i == centerIdx,
                          onTap: () {
                            if (i == centerIdx) return;
                            _ctrl.animateToPage(i,
                                duration: const Duration(milliseconds: 350),
                                curve: Curves.easeOutCubic);
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
              // ─── 新しい出会いの祝福 ─────────────────────────
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _celebrate ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: Center(
                    child: AnimatedScale(
                      scale: _celebrate ? 1.0 : 0.6,
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.elasticOut,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 10),
                        decoration: BoxDecoration(
                          color: Palette.sun,
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: Palette.liftBig(Palette.sunDeep),
                        ),
                        child: const Text(
                          '🎉 あたらしい出会い！',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // 中央の人の名前
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Column(
            key: ValueKey('name$centerIdx'),
            children: [
              Text(center.name,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: Palette.ink)),
              const SizedBox(height: 2),
              Text(
                '${center.template.statusText} · ${encounterLabel(center.meetCount)}',
                style: Ts.caption,
              ),
              const SizedBox(height: 2),
              // プライバシー配慮: 正確な時刻は出さず、あいまいな時間帯だけ伝える
              Text(_fuzzyMetLabel(center.lastMet), style: Ts.tiny),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlazaPerson extends StatelessWidget {
  final EncounterRecord encounter;
  final bool isCenter;
  final VoidCallback onTap;
  const _PlazaPerson({
    required this.encounter,
    required this.isCenter,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        Palette.pastelAvatars[encounter.colorIndex % Palette.pastelAvatars.length];

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // ドット絵を主役に: 相手の作品を大きく・にじませず表示
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: isCenter ? Colors.white : Colors.white70,
              borderRadius: BorderRadius.circular(22),
              boxShadow: isCenter
                  ? [
                      BoxShadow(
                          color: color.withValues(alpha: 0.55),
                          blurRadius: 18,
                          spreadRadius: 2)
                    ]
                  : Palette.lift(),
            ),
            child: PeerIcon(
              encounter: encounter,
              size: 96,
              circle: false,
              radius: 18,
            ),
          ),
          // 足元の影（地面に立っている感）
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: 44,
            height: 8,
            decoration: BoxDecoration(
              color: Palette.ink.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 開門ゲートパネル ────────────────────────────────────────────────────────
class _GatePanel extends StatelessWidget {
  final String asset;
  final String label;
  final int hour;
  final bool isOpen;
  final DateTime gateTime;
  final VoidCallback onGateOpen;
  final int revCount;
  final int unrevCount;
  final VoidCallback onReveal;

  const _GatePanel({
    required this.asset,
    required this.label,
    required this.hour,
    required this.isOpen,
    required this.gateTime,
    required this.onGateOpen,
    required this.revCount,
    required this.unrevCount,
    required this.onReveal,
  });

  @override
  Widget build(BuildContext context) {
    final hh = hour.toString().padLeft(2, '0');
    final hasUnrev = unrevCount > 0;

    return SoftPanel(
      color: isOpen && hasUnrev
          ? Palette.coral.withValues(alpha: 0.13)
          : Palette.card,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(asset,
                width: 44, height: 44,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$labelの開門',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Palette.ink)),
              Text('$hh:00', style: Ts.caption),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: isOpen
                ? (hasUnrev
                    ? ChunkyButton(
                        label: '$unrevCount人 あける！',
                        emoji: '🔓',
                        onTap: onReveal,
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            revCount > 0 ? '✅ $revCount人 確認済み' : '出会いなし',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: revCount > 0
                                    ? Palette.tealDeep
                                    : Palette.inkFaint),
                          ),
                        ],
                      ))
                : Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      const Text('⏳', style: TextStyle(fontSize: 14)),
                      const SizedBox(width: 6),
                      _CountdownText(target: gateTime, onDone: onGateOpen),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// カウントダウン専用Widget。
/// 自前の1秒タイマーでこのTextだけを更新し、画面全体のrebuildを避ける。
/// 0になったら onDone で親に通知して開門状態へ切り替える。
class _CountdownText extends StatefulWidget {
  final DateTime target;
  final VoidCallback onDone;
  const _CountdownText({required this.target, required this.onDone});

  @override
  State<_CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<_CountdownText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (DateTime.now().isAfter(widget.target)) {
        _timer?.cancel();
        widget.onDone(); // 開門の瞬間だけ親をrebuild
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.target.difference(DateTime.now());
    final r = remaining.isNegative ? Duration.zero : remaining;
    final rh = r.inHours.toString().padLeft(2, '0');
    final rm = (r.inMinutes % 60).toString().padLeft(2, '0');
    final rs = (r.inSeconds % 60).toString().padLeft(2, '0');
    return Text('$rh:$rm:$rs',
        style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Palette.inkSoft,
            fontFeatures: const [FontFeature.tabularFigures()]));
  }
}

// ─── 履歴タイル ──────────────────────────────────────────────────────────────
class _HistoryTile extends StatelessWidget {
  final EncounterRecord encounter;
  const _HistoryTile({required this.encounter});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SoftPanel(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            PeerIcon(encounter: encounter, size: 38, circle: false, radius: 10),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(encounter.name,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                          color: Palette.ink)),
                  Text(fmtDate(encounter.lastMet), style: Ts.tiny),
                ],
              ),
            ),
            Text(encounterLabel(encounter.meetCount),
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Palette.inkSoft)),
          ],
        ),
      ),
    );
  }
}

// ─── スワイプカード画面（開封演出・既存ロジック維持）──────────────────────────
class _SwipeCardScreen extends StatefulWidget {
  final List<EncounterRecord> encounters;
  final VoidCallback onReveal;
  const _SwipeCardScreen({required this.encounters, required this.onReveal});

  @override
  State<_SwipeCardScreen> createState() => _SwipeCardScreenState();
}

class _SwipeCardScreenState extends State<_SwipeCardScreen> {
  final _ctrl = PageController();
  int _page = 0;
  bool _done = false;

  void _next() {
    if (_page < widget.encounters.length - 1) {
      _ctrl.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut);
    } else {
      _complete();
    }
  }

  void _skipAll() => _complete();

  void _complete() {
    if (_done) return;
    setState(() => _done = true);
    widget.onReveal();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.encounters.length;

    if (_done) {
      return Scaffold(
        backgroundColor: Palette.cream,
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('🎉', style: TextStyle(fontSize: 72)),
                const SizedBox(height: 24),
                Text('今日は $total 人と出会いました！',
                    style: Ts.heading, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text('広場に追加されました', style: Ts.caption),
                const SizedBox(height: 40),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 60),
                  child: ChunkyButton(
                    label: 'とじる',
                    onTap: () => Navigator.pop(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Palette.cream,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                    total,
                    (i) => Container(
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i == _page
                                ? Palette.coral
                                : Palette.inkFaint,
                          ),
                        )),
              ),
            ),
            Positioned.fill(
              top: 36,
              child: PageView.builder(
                controller: _ctrl,
                itemCount: total,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (ctx, i) => _EncounterCard(
                  encounter: widget.encounters[i],
                  onNext: _next,
                  isLast: i == total - 1,
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 16,
              child: TextButton.icon(
                onPressed: _skipAll,
                icon: Icon(Icons.fast_forward,
                    size: 16, color: Palette.inkSoft),
                label:
                    Text('スキップ', style: TextStyle(color: Palette.inkSoft)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 出会いカード（レアリティ演出は既存維持）───────────────────────────────────
class _EncounterCard extends StatelessWidget {
  final EncounterRecord encounter;
  final VoidCallback onNext;
  final bool isLast;
  const _EncounterCard(
      {required this.encounter, required this.onNext, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final color =
        Palette.pastelAvatars[encounter.colorIndex % Palette.pastelAvatars.length];
    final initial =
        encounter.name.isNotEmpty ? encounter.name.characters.first : '?';
    final rarity = cardRarityOf(encounter.meetCount);
    final tmpl = encounter.template;
    final cardBg = _rarityCardBackground(rarity, context);
    final isCommon = rarity == CardRarity.common;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: rarityBorderColor(rarity).withValues(alpha: 0.3),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Container(
                  decoration: cardBg,
                  width: double.infinity,
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: rarityBorderColor(rarity)
                                  .withValues(alpha: 0.7)),
                        ),
                        child: Text(
                          rarityLabel(rarity),
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isCommon
                                  ? rarityBorderColor(rarity)
                                  : Colors.white),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // 開封の主役はドット絵。白台座に大きく飾る
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(26),
                          boxShadow: [
                            BoxShadow(
                                color: color.withValues(alpha: 0.5),
                                blurRadius: 24,
                                spreadRadius: 6),
                          ],
                        ),
                        child: PeerIcon(
                            encounter: encounter,
                            size: 116,
                            circle: false,
                            radius: 20),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        encounter.name,
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: isCommon ? Palette.ink : Colors.white,
                            ),
                      ),
                      const SizedBox(height: 20),
                      Divider(
                          color: isCommon
                              ? Palette.inkFaint
                              : Colors.white.withValues(alpha: 0.4)),
                      const SizedBox(height: 12),
                      _InfoRow(
                          icon: Icons.calendar_today_outlined,
                          label: '初めて出会った日',
                          value: fmtDate(encounter.firstMet),
                          light: !isCommon),
                      if (encounter.prefecture >= 0)
                        _InfoRow(
                            icon: Icons.place_outlined,
                            label: '出身地',
                            value: _prefName(encounter.prefecture),
                            light: !isCommon),
                      const SizedBox(height: 12),
                      Divider(
                          color: isCommon
                              ? Palette.inkFaint
                              : Colors.white.withValues(alpha: 0.4)),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: isCommon
                              ? Palette.creamDeep
                              : Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Text(
                              '💬 "${tmpl.phraseText}"',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontStyle: FontStyle.italic,
                                  color: isCommon ? Palette.ink : Colors.white),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${tmpl.statusText}  ·  ${tmpl.hobbyCategoryText}',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: isCommon
                                      ? Palette.inkSoft
                                      : Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          ChunkyButton(
            label: isLast ? 'かんりょう！' : 'つぎへ',
            emoji: isLast ? '✅' : '➡️',
            onTap: onNext,
          ),
          const SizedBox(height: 8),
          Text('← スワイプでも操作できます →', style: Ts.tiny),
        ],
      ),
    );
  }
}

String _prefName(int code) {
  const names = [
    '北海道', '青森', '岩手', '宮城', '秋田', '山形', '福島',
    '茨城', '栃木', '群馬', '埼玉', '千葉', '東京', '神奈川',
    '新潟', '富山', '石川', '福井', '山梨', '長野',
    '岐阜', '静岡', '愛知', '三重',
    '滋賀', '京都', '大阪', '兵庫', '奈良', '和歌山',
    '鳥取', '島根', '岡山', '広島', '山口',
    '徳島', '香川', '愛媛', '高知',
    '福岡', '佐賀', '長崎', '熊本', '大分', '宮崎', '鹿児島', '沖縄',
  ];
  if (code < 0 || code >= names.length) return '不明';
  return names[code];
}

BoxDecoration _rarityCardBackground(CardRarity r, BuildContext context) {
  switch (r) {
    case CardRarity.hologram:
      return const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xFFB721FF),
            Color(0xFF21D4FD),
            Color(0xFFFF6B6B),
            Color(0xFFFFE66D)
          ],
          stops: [0.0, 0.33, 0.66, 1.0],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      );
    case CardRarity.gradient:
      return const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      );
    case CardRarity.craft:
      return const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFD4A574), Color(0xFFA07850)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      );
    case CardRarity.common:
      return BoxDecoration(color: Palette.card);
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool light;
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.light = false,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon,
                size: 16, color: light ? Colors.white70 : Palette.inkSoft),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: light ? Colors.white70 : Palette.inkSoft)),
            const Spacer(),
            Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: light ? Colors.white : Palette.ink)),
          ],
        ),
      );
}
