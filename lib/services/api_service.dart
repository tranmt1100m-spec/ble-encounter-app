import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../core/api_config.dart';

/// 自前サーバー（さくらVPS）との通信。旧 SupabaseService の置き換え。
///
/// 認証は失効しないAPIキー方式（SecureStorageに保管）。
/// Supabase時代に起きていた「約6時間でセッションが切れて同期が止まる」問題が
/// 構造的に発生しない。
///
/// 公開メソッドのシグネチャは旧 SupabaseService と揃えてあるため、
/// 呼び出し側（providers / resolver / editor）の変更は最小限で済む。
class ApiService {
  ApiService._();

  static const _store = FlutterSecureStorage();
  static const _keyApiKey = 'api_key_v1';
  static const _keyUserId = 'api_user_id_v1';
  static const _timeout = Duration(seconds: 12);

  static String? _apiKey;
  static String? _userId;

  static String? get userId => _userId;
  static bool get isReady => _apiKey != null && _userId != null;

  /// 起動時に呼ぶ。保存済みの資格情報を復元し、無ければ匿名登録する。
  static Future<void> init() async {
    _apiKey = await _store.read(key: _keyApiKey);
    _userId = await _store.read(key: _keyUserId);
    if (_apiKey == null || _userId == null) {
      await _signUpAnonymously();
    } else {
      debugPrint('[Api] restored uid=${_userId!.substring(0, 8)}');
    }
  }

  /// 匿名ユーザーを新規作成（旧 signInAnonymously 相当）。
  /// 本名・メール・電話などは一切送らない（匿名性の維持）。
  static Future<bool> _signUpAnonymously() async {
    try {
      final res = await http
          .post(Uri.parse('$apiBaseUrl/auth/anon'))
          .timeout(_timeout);
      if (res.statusCode != 200) {
        debugPrint('[Api] signup failed: ${res.statusCode}');
        return false;
      }
      final m = jsonDecode(res.body) as Map<String, dynamic>;
      _apiKey = m['api_key'] as String;
      _userId = m['user_id'] as String;
      await _store.write(key: _keyApiKey, value: _apiKey);
      await _store.write(key: _keyUserId, value: _userId);
      debugPrint('[Api] anonymous signup OK uid=${_userId!.substring(0, 8)}');
      return true;
    } catch (e) {
      debugPrint('[Api] signup error: $e');
      return false;
    }
  }

  /// 未登録なら登録を試みる（オフライン起動後の自己回復）
  static Future<bool> _ready() async {
    if (isReady) return true;
    return _signUpAnonymously();
  }

  static Map<String, String> get _headers => {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json; charset=utf-8',
      };

  // ─── Token ───────────────────────────────────────────────────────

  /// BLEで流す使い捨てトークンを発行（24時間有効）
  static Future<String?> issueToken() async {
    if (!await _ready()) return null;
    try {
      final res = await http
          .post(Uri.parse('$apiBaseUrl/tokens/issue'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) {
        debugPrint('[Api] issueToken: ${res.statusCode}');
        return null;
      }
      return (jsonDecode(res.body) as Map<String, dynamic>)['token'] as String?;
    } catch (e) {
      debugPrint('[Api] issueToken: $e');
      return null;
    }
  }

  /// 収集したトークンを相手プロフィールへ解決。
  /// 通信エラー時は null を返す（成功して0件の [] と区別する）。
  /// null のときは呼び出し側がトークンを保持し続けるため、すれ違いが消えない。
  static Future<List<Map<String, dynamic>>?> resolveTokens(
      List<String> tokens) async {
    if (tokens.isEmpty) return [];
    if (!await _ready()) return null;
    try {
      final res = await http
          .post(Uri.parse('$apiBaseUrl/tokens/resolve'),
              headers: _headers, body: jsonEncode({'tokens': tokens}))
          .timeout(_timeout);
      if (res.statusCode != 200) {
        debugPrint('[Api] resolveTokens: ${res.statusCode}');
        return null;
      }
      return (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('[Api] resolveTokens: $e');
      return null;
    }
  }

  // ─── Profile ─────────────────────────────────────────────────────

  /// 表示名・色・ドット絵・バッジレベルをサーバーへ同期。
  /// ドット絵はサーバー側で4bit/pxに圧縮され128バイトで保存される。
  static Future<bool> syncProfile({
    required String displayName,
    required int colorIndex,
    List<int>? piecePixels,
    int? badgeLevel,
  }) async {
    if (!await _ready()) return false;
    try {
      final res = await http
          .post(Uri.parse('$apiBaseUrl/profile'),
              headers: _headers,
              body: jsonEncode({
                'display_name': displayName,
                'color_index': colorIndex,
                if (piecePixels != null) 'piece_data': piecePixels,
                if (badgeLevel != null) 'badge_level': badgeLevel,
              }))
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[Api] syncProfile: $e');
      return false;
    }
  }

  /// ドット絵だけを更新（エディタ保存時）
  static Future<bool> savePieceData(List<int> pixels) async {
    if (!await _ready()) return false;
    try {
      final res = await http
          .post(Uri.parse('$apiBaseUrl/profile'),
              headers: _headers, body: jsonEncode({'piece_data': pixels}))
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[Api] savePieceData: $e');
      return false;
    }
  }
}
