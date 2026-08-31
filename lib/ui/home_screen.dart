import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/ble_providers.dart';
import '../services/notification_service.dart';
import 'theme/palette.dart';
import 'widgets/ui_kit.dart';
import 'widgets/user_icon.dart';
import 'today_screen.dart';
import 'plaza_screen.dart';
import 'minigame_screen.dart';
import 'coming_soon_screen.dart';
import '../core/ble_config.dart';
import 'badge_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'puzzle/puzzle_board_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  int _selectedIndex = 0;

  static const _screens = <Widget>[
    TodayScreen(),
    PlazaScreen(),
    kGameTabEnabled
        ? MinigameScreen()
        : ComingSoonScreen(
            title: 'ゲームセンター', asset: 'assets/icons/tab_game.png'),
    BadgeScreen(),
    PuzzleBoardScreen(),
    ProfileScreen(),
    SettingsScreen(),
  ];

  static const _dockItems = [
    DockItem(asset: 'assets/icons/tab_today.png', label: '今日'),
    DockItem(asset: 'assets/icons/tab_plaza.png', label: '広場'),
    DockItem(asset: 'assets/icons/tab_game.png', label: 'ゲーム'),
    DockItem(asset: 'assets/icons/tab_badge.png', label: 'バッジ'),
    DockItem(asset: 'assets/icons/tab_kakera.png', label: 'カケラ'),
    // じぶんタブはユーザー作成ドット絵（未作成時はデフォルトドット絵）
    DockItem(custom: UserIcon(size: 26, radius: 7), label: 'じぶん'),
    DockItem(asset: 'assets/icons/tab_settings.png', label: '設定'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.onDailyNotificationTap = () {
      if (mounted) setState(() => _selectedIndex = 0);
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showNewBadgeIfAny();
    });
  }

  @override
  void dispose() {
    NotificationService.onDailyNotificationTap = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      final appState = ref.read(appProvider);
      if (!appState.isRunning && appState.ownProfile != null) {
        ref.read(appProvider.notifier).start();
      }
    }
  }

  void _showNewBadgeIfAny() {
    ref.listenManual(appProvider.select((s) => s.newlyEarnedBadges), (_, next) {
      if (next.isEmpty || !mounted) return;
      for (final badge in next) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${badge.emoji} バッジ獲得: ${badge.title}'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ));
      }
      ref.read(appProvider.notifier).clearNewBadges();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.cream,
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: GameDock(
        items: _dockItems,
        selected: _selectedIndex,
        onSelect: (i) {
          if (i == 0 || i == 1) {
            ref.read(appProvider.notifier).clearNewEncounterFlag();
          }
          setState(() => _selectedIndex = i);
        },
      ),
    );
  }
}
