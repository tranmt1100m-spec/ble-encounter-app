import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/ble_config.dart';
import '../core/peer_id.dart';
import '../models/app_badge.dart';
import '../models/dot_avatar.dart';
import '../models/own_profile.dart';
import '../models/encounter_record.dart';
import '../models/template_message.dart';
import '../services/advertiser.dart';
import '../services/badge_service.dart';
import '../services/data_export_service.dart';
import '../services/game_storage.dart';
import '../services/piece_storage.dart';
import '../services/scanner.dart';
import '../services/profile_storage.dart';
import '../services/notification_service.dart';
import '../services/api_service.dart';
import '../services/token_service.dart';
import 'puzzle_providers.dart';

// スキャン間隔プロバイダー（設定画面 → サイクルへ即時反映）
final scanIntervalProvider = StateProvider<ScanInterval>((ref) => ScanInterval.two);

// ─── State ──────────────────────────────────────────────────────────────────

class AppState {
  final bool isLoading;
  final bool isRunning;
  final OwnProfile? ownProfile;
  final List<EncounterRecord> encounters;
  final List<AppBadge> badges;
  final bool hasNewEncounter;
  final List<AppBadge> newlyEarnedBadges;
  final String? errorMessage;

  const AppState({
    this.isLoading = true,
    this.isRunning = false,
    this.ownProfile,
    this.encounters = const [],
    this.badges = const [],
    this.hasNewEncounter = false,
    this.newlyEarnedBadges = const [],
    this.errorMessage,
  });

  AppState copyWith({
    bool? isLoading,
    bool? isRunning,
    OwnProfile? ownProfile,
    List<EncounterRecord>? encounters,
    List<AppBadge>? badges,
    bool? hasNewEncounter,
    List<AppBadge>? newlyEarnedBadges,
    String? errorMessage,
  }) =>
      AppState(
        isLoading:         isLoading ?? this.isLoading,
        isRunning:         isRunning ?? this.isRunning,
        ownProfile:        ownProfile ?? this.ownProfile,
        encounters:        encounters ?? this.encounters,
        badges:            badges ?? this.badges,
        hasNewEncounter:   hasNewEncounter ?? this.hasNewEncounter,
        newlyEarnedBadges: newlyEarnedBadges ?? this.newlyEarnedBadges,
        errorMessage:      errorMessage,
      );
}

// ─── Notifier ────────────────────────────────────────────────────────────────

class AppNotifier extends Notifier<AppState> {
  final _advertiser = BleAdvertiser();
  final _scanner    = BleScanner();
  final _storage    = ProfileStorage();
  final _rng        = Random();

  final _notifScheduled = <String, DateTime>{};
  bool _userStopped = false;

  bool   _cycleActive    = false;
  bool   _cycleOnActive  = false;
  bool   _starting       = false;
  Timer? _cycleTimer;
  Timer? _resolveTimer;   // 定期自動解析（電波解析ボタン不要化）
  ScanInterval _scanInterval = ScanInterval.two;

  StreamSubscription<EncounterEvent>?        _encounterSub;
  StreamSubscription<String>?                _departureSub;
  StreamSubscription<BluetoothAdapterState>? _btStateSub;

  @override
  AppState build() {
    _loadData();
    _btStateSub = FlutterBluePlus.adapterState.listen(_onBluetoothState);
    return const AppState();
  }

  Future<void> _onBluetoothState(BluetoothAdapterState btState) async {
    debugPrint('[App] BT state: $btState');
    if (btState == BluetoothAdapterState.on) {
      if (!_userStopped && !state.isLoading &&
          state.ownProfile != null && !state.isRunning) {
        await start();
      }
    } else if (btState == BluetoothAdapterState.off ||
               btState == BluetoothAdapterState.turningOff) {
      if (state.isRunning) {
        _stopCycle();
        await _encounterSub?.cancel();
        _encounterSub = null;
        await _departureSub?.cancel();
        _departureSub = null;
        try { await _scanner.stop(); } catch (e) {
          debugPrint('[App] scanner stop error: $e');
        }
        try { await _advertiser.stopAdvertise(); } catch (e) {
          debugPrint('[App] stopAdvertise(bt-off) error: $e');
        }
        try { await _advertiser.stopForegroundService(); } catch (e) {
          debugPrint('[App] stopForegroundService(bt-off) error: $e');
        }
        state = state.copyWith(isRunning: false, errorMessage: null);
        debugPrint('[App] BT off — fully stopped');
      }
    }
  }

  // エンカウント時刻 → 開門時刻（どの「ゲート」に属するか）
  static DateTime gateTimeFor(DateTime t) {
    if (t.hour < 9)  return DateTime(t.year, t.month, t.day, 9);
    if (t.hour < 12) return DateTime(t.year, t.month, t.day, 12);
    if (t.hour < 21) return DateTime(t.year, t.month, t.day, 21);
    // 21:00以降 → 翌日9:00
    final next = t.add(const Duration(days: 1));
    return DateTime(next.year, next.month, next.day, 9);
  }

  /// 「きょうの広場」に並べる開門の一覧。
  ///
  /// 21時以降のすれ違いは [gateTimeFor] により翌朝9時の開門へ割り当てられる。
  /// 今日の3つ（9/12/21）だけを並べると、21〜24時のすれ違いがどの行にも
  /// 現れず、ユーザーからは「出会っているのに何も起きない」状態になる。
  /// そのため21時を過ぎたら翌朝の開門も並べる。
  ///
  /// 不変条件: 任意の時刻 t について
  /// `gatesToShow(t).contains(gateTimeFor(t))` が成り立つこと。
  static List<DateTime> gatesToShow(DateTime now) {
    final gates = [
      DateTime(now.year, now.month, now.day, 9),
      DateTime(now.year, now.month, now.day, 12),
      DateTime(now.year, now.month, now.day, 21),
    ];
    if (now.hour >= 21) {
      final t = now.add(const Duration(days: 1));
      gates.add(DateTime(t.year, t.month, t.day, 9));
    }
    return gates;
  }

  Future<void> _loadData() async {
    final profile   = await _storage.loadOwnProfile();
    var encounters  = await _storage.loadEncounters();
    var badges      = await BadgeService.load();

    // スキャン間隔を復元
    final prefs = await SharedPreferences.getInstance();
    final savedInterval = prefs.getInt(ScanIntervalX.prefKey) ?? ScanInterval.two.index;
    _scanInterval = ScanIntervalX.fromIndex(savedInterval);
    ref.read(scanIntervalProvider.notifier).state = _scanInterval;

    // 自動救済: ゲート時刻が過去になった未開封エンカウントを解放
    final now = DateTime.now();
    final hasOldUnrevealed = encounters.any(
      (e) => !e.isRevealed && gateTimeFor(e.lastMet).isBefore(now),
    );
    if (hasOldUnrevealed) {
      encounters = encounters.map((e) {
        if (!e.isRevealed && gateTimeFor(e.lastMet).isBefore(now)) return e.reveal();
        return e;
      }).toList();
      await _storage.saveEncounters(encounters);
      debugPrint('[App] auto-rescued past unrevealed encounters');
    }

    // バッジ移行処理: アップデート済みユーザーにも遡及付与
    if (profile != null) {
      badges = await _migrateBadges(badges: badges, encounters: encounters);
    }

    // ドット絵補完: カケラに保存済みの相手の絵を名簿(EncounterRecord)へ移す。
    // v1.7.7以前に出会った人にも即ドット絵が表示されるようにする一回きりの移行。
    final piecesForPatch = await PuzzlePieceStorage.load();
    if (piecesForPatch.isNotEmpty) {
      bool patched = false;
      encounters = encounters.map((e) {
        if (e.peerPixels == null) {
          final match =
              piecesForPatch.where((p) => p.ownerId == e.peerId).firstOrNull;
          if (match != null && !match.piece.isEmpty) {
            patched = true;
            return e.withPixels(match.piece.toJson());
          }
        }
        return e;
      }).toList();
      if (patched) {
        await _storage.saveEncounters(encounters);
        debugPrint('[App] backfilled peer dot-art from kakera cache');
      }
    }

    state = state.copyWith(
      isLoading:  false,
      ownProfile: profile,
      encounters: encounters,
      badges:     badges,
    );
    if (profile != null) {
      // BLEの成否に関わらずドット絵・プロフィールはサーバーへ同期する
      _syncProfileToServer();
      // Defer BLE start until after the UI has rendered the home screen.
      await Future.delayed(const Duration(milliseconds: 300));
      await _autoStart();
    }
  }

  // アップデート移行・インポート後のバッジ遡及付与
  // スタートバッジがなければ付与し、解放済みエンカウント数に応じたカウントバッジも付与
  Future<List<AppBadge>> _migrateBadges({
    required List<AppBadge> badges,
    required List<EncounterRecord> encounters,
  }) async {
    var updated = await BadgeService.awardStartBadge(badges);
    final totalRevealed = encounters.where((e) => e.isRevealed).length;
    if (totalRevealed > 0) {
      updated = await BadgeService.checkCountBadges(
        totalRevealed: totalRevealed,
        existing: updated,
      );
    }
    return updated;
  }

  Future<void> _autoStart() async {
    final ok = await requestPermissions();
    if (ok) await start();
  }

  // 名前・バッジ・ドット絵のサーバー同期。
  // BLEが起動できない状態（BT off等）でもドット絵は相手に届くべきなので
  // start() とは独立に _loadData からも呼ぶ。失敗しても次回起動で再送。
  Future<void> _syncProfileToServer() async {
    final p = state.ownProfile;
    if (p == null) return;
    final dotAvatar = await DotAvatarStorage.load();
    ApiService.syncProfile(
      displayName: p.name,
      colorIndex:  p.colorIndex,
      badgeLevel:  AppBadge.badgeLevelFrom(state.badges),
      piecePixels: (dotAvatar != null && !dotAvatar.isEmpty)
          ? dotAvatar.toPiecePixels()
          : null,
    );
  }

  // ─── Profile ─────────────────────────────────────────────────────────────

  Future<void> saveOwnProfile(OwnProfile profile) async {
    final isFirstSave = state.ownProfile == null;
    final withDate = profile.registeredAt != null
        ? profile
        : profile.copyWith(registeredAt: DateTime.now());
    await _storage.saveOwnProfile(withDate);
    state = state.copyWith(ownProfile: withDate, errorMessage: null);

    // 初回プロフィール設定時にスタートバッジを付与
    if (isFirstSave) {
      final updatedBadges = await BadgeService.awardStartBadge(state.badges);
      final newlyEarned = updatedBadges
          .where((b) => !state.badges.any((ob) => ob.id == b.id))
          .toList();
      state = state.copyWith(badges: updatedBadges, newlyEarnedBadges: newlyEarned);
      debugPrint('[App] start badge awarded');
    }

    if (state.isRunning) {
      debugPrint('[App] profile updated, next cycle will use new payload');
    } else if (isFirstSave) {
      await _autoStart();
    }
  }

  // ─── Permissions ─────────────────────────────────────────────────────────

  Future<bool> requestPermissions() async {
    // iOS: bluetoothScan/Advertise/Connect は NSBluetoothAlwaysUsageDescription にマッピングされる
    // Android: 個別権限が必要
    final permissions = [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      if (defaultTargetPlatform != TargetPlatform.iOS) Permission.locationWhenInUse,
      Permission.notification,
    ];

    final statuses = await permissions.request();

    final denied = statuses.entries
        .where((e) => e.value.isDenied || e.value.isPermanentlyDenied)
        .map((e) => e.key.toString())
        .toList();

    if (denied.isNotEmpty) {
      state = state.copyWith(errorMessage: '許可が必要です: ${denied.join(', ')}');
      return false;
    }
    return true;
  }

  // ─── Start ───────────────────────────────────────────────────────────────

  Future<void> start() async {
    _userStopped = false;
    if (state.isRunning || _starting) return;
    _starting = true;
    final profile = state.ownProfile;
    if (profile == null) {
      state = state.copyWith(errorMessage: 'プロフィールを設定してください');
      return;
    }
    try {
      final btState = await FlutterBluePlus.adapterState.first;
      if (btState != BluetoothAdapterState.on) {
        debugPrint('[App] BT not ready ($btState), waiting...');
        return;
      }
    } catch (_) {}

    try {
      await _encounterSub?.cancel();
      await _departureSub?.cancel();
      _encounterSub = _scanner.encounters.listen(_onEncounter);
      _departureSub = _scanner.departures.listen(_onDeparture);

      await _advertiser.startForegroundService();
      state = state.copyWith(isRunning: true, errorMessage: null);
      _starting = false; // isRunning=true になったのでロック解放
      debugPrint('[App] cycle started peerId=${PeerId.hex}');

      _startCycle();
      _startAutoResolve();

      await NotificationService.scheduleGateNotifications();

      // バッジレベル＋ドット絵をサーバーに同期（相手側の Today/広場/カケラ表示用）
      _syncProfileToServer();
    } catch (e) {
      debugPrint('[App] start error: $e');
      state = state.copyWith(isRunning: false, errorMessage: '起動エラー: $e');
    } finally {
      _starting = false;
    }
  }

  // ─── 間欠スキャンサイクル ─────────────────────────────────────────────────

  void _startCycle() {
    _cycleActive = true;
    _cycleTimer?.cancel();
    _doCycleOn(); // 即時1回目を開始
  }

  void _stopCycle() {
    _cycleActive = false;
    _cycleTimer?.cancel();
    _cycleTimer = null;
    _resolveTimer?.cancel();
    _resolveTimer = null;
  }

  // ─── 定期自動解析（サーバーファースト）────────────────────────────────
  // 3分ごとに保留トークンをサーバーで解析。電波解析ボタンを押さなくても
  // 広場・カケラコレクションが自動更新される。
  void _startAutoResolve() {
    _resolveTimer?.cancel();
    _resolveTimer = Timer.periodic(const Duration(minutes: 3), (_) => _autoResolveNow());
    // 起動直後にも一度実行（前回セッションの残りトークンを処理）
    Future.delayed(const Duration(seconds: 5), _autoResolveNow);
  }

  // 日付が変わった未開封エンカウントを自動公開する。
  // ミニゲーム（開封演出）を実施しなくても履歴が広場に残る。
  // ゲート前の当日分は対象外（プライバシー仕様・開封演出は維持）。
  Future<void> _rescuePastDays() async {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final needs = state.encounters
        .any((e) => !e.isRevealed && e.lastMet.isBefore(todayStart));
    if (!needs) return;
    final list = state.encounters.map((e) {
      if (!e.isRevealed && e.lastMet.isBefore(todayStart)) return e.reveal();
      return e;
    }).toList();
    state = state.copyWith(encounters: list);
    await _storage.saveEncounters(list);
    debugPrint('[App] rescued unrevealed encounters from past days');
  }

  Future<void> _autoResolveNow() async {
    await _rescuePastDays();
    try {
      final pending = await PendingScanStorage.getAllTokens();
      if (pending.isEmpty) return;
      debugPrint('[AutoResolve] ${pending.length} tokens pending...');
      await ref.read(puzzleProvider.notifier).resolvePending(
        onProfileResolved: (profile) {
          upsertFromServerProfile(
            peerId:     profile.userId,
            name:       profile.displayName,
            colorIndex: profile.colorIndex,
            metAt:      profile.metAt,
            badgeLevel: profile.badgeLevel,
            avatarUrl:  profile.avatarUrl,
            pixels:     profile.pixels,
          );
        },
      );
    } catch (e) {
      debugPrint('[AutoResolve] error: $e');
    }
  }

  // デバイスの時計に同期した「次の境界時刻まで」の待機時間を計算
  // 例: 間隔5分なら 0,5,10,15... 分の時刻に揃える
  Duration _timeToNextBoundary() {
    if (_scanInterval == ScanInterval.always) return const Duration(seconds: 2);
    if (kDebugBle) return Duration(seconds: _scanInterval.offSeconds);
    final now = DateTime.now();
    final intervalSec = _scanInterval.intervalMinutes * 60;
    final currentSec = now.minute * 60 + now.second;
    final elapsed = currentSec % intervalSec;
    final remaining = intervalSec - elapsed;
    // 残り2秒未満なら次の境界まで待つ（即時再起動を防ぐ）
    return Duration(seconds: remaining < 2 ? intervalSec : remaining);
  }

  Future<void> _doCycleOn() async {
    if (!_cycleActive || _userStopped) return;
    // 並列実行防止: 前回の _doCycleOn がまだ async 処理中なら skip
    if (_cycleOnActive) {
      debugPrint('[Cycle] _doCycleOn skip (already running)');
      return;
    }
    _cycleOnActive = true;
    try {
      final profile = state.ownProfile;
      if (profile == null) return;

      final btState = await FlutterBluePlus.adapterState.first;
      if (btState != BluetoothAdapterState.on) {
        // BT がオフなら 30 秒後に再試行
        _cycleTimer = Timer(const Duration(seconds: 30), _doCycleOn);
        return;
      }
      final badgeLevel = AppBadge.badgeLevelFrom(state.badges);
      final tokenBytes = Uint8List.fromList(TokenService.tokenBytes);
      // Phase3: 現在の使い捨てトークンをBLEに流す（オフライン時はPeerIdにフォールバック）
      _scanner.setOwnTokenHex(TokenService.hexToken);
      await _advertiser.startAdvertise(tokenBytes, profile.toScanPayload(badgeLevel: badgeLevel));
      await _scanner.start();
      debugPrint('[Cycle] BLE ON — ${kScanOnSeconds}s badge=$badgeLevel');
    } catch (e) {
      debugPrint('[Cycle] ON error: $e');
    } finally {
      _cycleOnActive = false;
    }
    _cycleTimer = Timer(Duration(seconds: kScanOnSeconds), _doCycleOff);
  }

  Future<void> _doCycleOff() async {
    if (!_cycleActive) return;
    try { await _scanner.stop(); } catch (e) {
      debugPrint('[Cycle] scan stop error: $e');
    }
    try { await _advertiser.stopAdvertise(); } catch (e) {
      debugPrint('[Cycle] advertise stop error: $e');
    }
    final delay = _timeToNextBoundary();
    debugPrint('[Cycle] BLE OFF — 次の境界まで${delay.inSeconds}s待機 (interval=${_scanInterval.label})');
    _cycleTimer = Timer(delay, _doCycleOn);
  }

  // ─── Stop ────────────────────────────────────────────────────────────────

  Future<void> stop() async {
    _userStopped = true;
    if (!state.isRunning) return;
    _stopCycle(); // サイクルタイマーをキャンセル
    await _encounterSub?.cancel();
    await _departureSub?.cancel();
    _encounterSub = null;
    _departureSub = null;
    try { await _scanner.stop(); } catch (e) {
      debugPrint('[App] scanner stop error: $e');
    }
    try { await _advertiser.stopAdvertise(); } catch (e) {
      debugPrint('[App] stopAdvertise error: $e');
    }
    try { await _advertiser.stopForegroundService(); } catch (e) {
      debugPrint('[App] stopForegroundService error: $e');
    }
    state = state.copyWith(isRunning: false);
    debugPrint('[App] fully stopped (cycle + scan + advertise)');
  }

  void clearNewEncounterFlag() {
    state = state.copyWith(hasNewEncounter: false);
  }

  void clearNewBadges() {
    state = state.copyWith(newlyEarnedBadges: []);
  }

  // 結果演出完了時: ゲート時刻が過去の unrevealed を一斉に解放 → バッジチェック
  Future<void> revealToday() async {
    final now = DateTime.now();
    final list = state.encounters.map((e) {
      if (!e.isRevealed && gateTimeFor(e.lastMet).isBefore(now)) return e.reveal();
      return e;
    }).toList();

    final totalRevealed = list.where((e) => e.isRevealed).length;
    final updatedBadges = await BadgeService.checkCountBadges(
      totalRevealed: totalRevealed,
      existing: state.badges,
    );
    final newlyEarned = updatedBadges
        .where((b) => !state.badges.any((ob) => ob.id == b.id))
        .toList();

    state = state.copyWith(
      encounters:        list,
      hasNewEncounter:   false,
      badges:            updatedBadges,
      newlyEarnedBadges: newlyEarned,
    );
    await _storage.saveEncounters(list);

    // バッジが増えたらサーバーにも反映（相手の広場に表示されるため）
    if (newlyEarned.isNotEmpty && state.ownProfile != null) {
      ApiService.syncProfile(
        displayName: state.ownProfile!.name,
        colorIndex:  state.ownProfile!.colorIndex,
        badgeLevel:  AppBadge.badgeLevelFrom(updatedBadges),
      );
    }
  }

  // ─── Encounter ───────────────────────────────────────────────────────────

  Future<void> _onEncounter(EncounterEvent event) async {
    // Phase3: スキャンしたトークンをローカルキューに保存（サーバーで解析）
    PendingScanStorage.add(event.peerId, event.time);

    // サーバーファースト: BLEにプロフィールが含まれている場合のみ即座にEncounterRecord作成
    // トークンのみの場合はサーバー解析後にEncounterRecordが作成される
    if (event.name.isNotEmpty) {
      await _upsertEncounter(
        peerId:         event.peerId,
        name:           event.name,
        colorIndex:     event.colorIndex,
        prefecture:     event.prefecture,
        template:       event.template,
        rssi:           event.rssi,
        peerBadgeLevel: event.peerBadgeLevel,
      );
      debugPrint('[App] encountered: ${event.name}');
    } else {
      debugPrint('[App] token captured (server-first): ${event.peerId.substring(28)}');
      state = state.copyWith(hasNewEncounter: true);
    }
  }

  // 切断イベント → ランダム 10〜30分後に通知スケジュール
  Future<void> _onDeparture(String peerId) async {
    final last = _notifScheduled[peerId];
    final now  = DateTime.now();
    if (last != null && now.difference(last).inHours < 12) {
      debugPrint('[Departure] skip notif for ${peerId.substring(28)} (cooldown)');
      return;
    }
    _notifScheduled[peerId] = now;

    final delayMin = _rng.nextInt(21) + 10; // 10〜30分
    await NotificationService.scheduleEncounterNotification(
      peerId:       peerId,
      delayMinutes: delayMin,
    );
    debugPrint('[Departure] scheduled notif in ${delayMin}min for ${peerId.substring(28)}');
  }

  Future<void> setScanInterval(ScanInterval interval) async {
    _scanInterval = interval;
    ref.read(scanIntervalProvider.notifier).state = interval;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(ScanIntervalX.prefKey, interval.index);
    debugPrint('[App] scanInterval → ${interval.label}');
  }

  Future<void> _upsertEncounter({
    required String peerId,
    required String name,
    required int colorIndex,
    required int prefecture,
    required TemplateMessage template,
    required int rssi,
    int peerBadgeLevel = 0,
    String? avatarUrl,
    List<int>? peerPixels,
  }) async {
    final now  = DateTime.now();
    final list = List<EncounterRecord>.from(state.encounters);
    final idx  = list.indexWhere((e) => e.peerId == peerId);

    if (idx >= 0) {
      final existing = list.removeAt(idx);
      final newMeetCount =
          existing.metToday ? existing.meetCount : existing.meetCount + 1;
      list.insert(0, EncounterRecord(
        peerId:         existing.peerId,
        name:           name,
        colorIndex:     existing.colorIndex,
        prefecture:     prefecture != -1 ? prefecture : existing.prefecture,
        firstMet:       existing.firstMet,
        lastMet:        now,
        meetCount:      newMeetCount,
        rssi:           rssi,
        template:       template,
        isRevealed:     existing.isRevealed && existing.metToday,
        peerBadgeLevel: peerBadgeLevel > 0 ? peerBadgeLevel : existing.peerBadgeLevel,
        avatarUrl:      avatarUrl ?? existing.avatarUrl,
        peerPixels:     peerPixels ?? existing.peerPixels, // ドット絵は最新を保持
      ));
    } else {
      list.insert(0, EncounterRecord(
        peerId:         peerId,
        name:           name,
        colorIndex:     colorIndex,
        prefecture:     prefecture,
        firstMet:       now,
        lastMet:        now,
        meetCount:      1,
        rssi:           rssi,
        template:       template,
        peerBadgeLevel: peerBadgeLevel,
        avatarUrl:      avatarUrl,
        peerPixels:     peerPixels,
      ));
    }

    // 履歴保持: 手動削除しない限り消さない（容量保護の上限のみ）
    final trimmed = list.take(1000).toList();
    state = state.copyWith(encounters: trimmed, hasNewEncounter: true);
    await _storage.saveEncounters(trimmed);
  }

  // サーバーファースト: サーバー解析結果からEncounterRecordを作成/更新
  Future<void> upsertFromServerProfile({
    required String peerId,
    required String name,
    required int colorIndex,
    required DateTime metAt,
    int badgeLevel = 0,
    String? avatarUrl,
    List<int>? pixels,
  }) async {
    await _upsertEncounter(
      peerId: peerId,
      name: name,
      colorIndex: colorIndex,
      prefecture: -1,
      template: const TemplateMessage(),
      rssi: 0,
      peerBadgeLevel: badgeLevel,
      avatarUrl: avatarUrl,
      peerPixels: pixels,
    );
  }

  // データのインポート（機種変移行用）
  Future<void> applyImport(ImportResult result) async {
    if (result.profile != null) {
      await _storage.saveOwnProfile(result.profile!);
    }
    await _storage.saveEncounters(result.encounters);
    await GameStorage.save(result.gameData);

    // インポートファイルにバッジが含まれていない（旧バージョンからのファイル）場合は
    // 既存バッジを維持したまま遡及付与を行う
    final baseBadges = result.badges.isNotEmpty ? result.badges : state.badges;
    final finalBadges = await _migrateBadges(
      badges:     baseBadges,
      encounters: result.encounters,
    );
    await BadgeService.save(finalBadges);

    state = state.copyWith(
      ownProfile: result.profile ?? state.ownProfile,
      encounters: result.encounters,
      badges:     finalBadges,
    );
    debugPrint('[App] import applied: ${result.encounters.length} encounters, ${finalBadges.length} badges');
  }

  void dispose() {
    _stopCycle();
    _btStateSub?.cancel();
    _encounterSub?.cancel();
    _departureSub?.cancel();
    _scanner.dispose();
  }
}

// ─── Provider ────────────────────────────────────────────────────────────────

final appProvider = NotifierProvider<AppNotifier, AppState>(AppNotifier.new);
