import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/peer_id.dart';
import 'api_service.dart';

/// BLEで流す使い捨てトークンを管理する。
/// サーバー未接続時は永続PeerIdにフォールバックし、既存機能を維持する。
class TokenService {
  static const _store      = FlutterSecureStorage();
  static const _keyToken   = 'ble_token_v1';
  static const _keyExpiry  = 'ble_token_expiry_v1';

  static String?   _token;
  static DateTime? _expiry;

  // 現在の有効なBLEトークン (hex 32文字 = 16バイト)
  // サーバー未接続の場合は永続PeerIdを返す（後方互換）
  static String get hexToken => _token ?? PeerId.hex;

  // BLEペイロード用バイト列 (16バイト)
  static List<int> get tokenBytes {
    final h = hexToken;
    return List.generate(16, (i) => int.parse(h.substring(i * 2, i * 2 + 2), radix: 16));
  }

  static bool get _needsRefresh {
    if (_token == null) return true;
    if (_expiry == null) return true;
    // 有効期限まで2時間未満 → 更新
    return _expiry!.difference(DateTime.now()).inHours < 2;
  }

  static Future<void> init() async {
    _token  = await _store.read(key: _keyToken);
    final e = await _store.read(key: _keyExpiry);
    if (e != null) _expiry = DateTime.tryParse(e);

    if (_needsRefresh) await refresh();
  }

  static Future<void> refresh() async {
    final newToken = await ApiService.issueToken();
    if (newToken == null) {
      debugPrint('[Token] refresh failed → using permanent PeerId');
      return;
    }
    _token  = newToken;
    _expiry = DateTime.now().add(const Duration(hours: 24));
    await _store.write(key: _keyToken,  value: _token);
    await _store.write(key: _keyExpiry, value: _expiry!.toIso8601String());
    debugPrint('[Token] refreshed: ${_token!.substring(0, 8)}... expires $_expiry');
  }
}
