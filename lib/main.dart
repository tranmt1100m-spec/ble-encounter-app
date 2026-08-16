import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'core/peer_id.dart';
import 'services/notification_service.dart';
import 'services/api_service.dart';
import 'services/token_service.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Fast: restore or generate device UID from SharedPreferences
  await PeerId.init();

  FlutterBluePlus.setLogLevel(LogLevel.warning, color: false);

  // Start UI immediately — don't block on heavy notification/timezone init
  runApp(
    const ProviderScope(
      child: App(),
    ),
  );

  // Heavy: timezone DB load + plugin init runs after first frame
  NotificationService.init();

  // 自前APIサーバー + 回転トークン初期化（オフライン時は永続PeerIdにフォールバック）
  try {
    await ApiService.init();
    await TokenService.init();
  } catch (e) {
    debugPrint('[main] server init error (offline?): $e');
  }
}
