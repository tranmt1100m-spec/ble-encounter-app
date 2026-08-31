// 回帰テスト: 開門時刻ロジック
// 過去の重大バグ「0時バグ」「18時バグ」を再現ケースとして固定化する。
// このテストが落ちたら、過去バグが再発している。
import 'package:flutter_test/flutter_test.dart';
import 'package:ble_encounter/providers/ble_providers.dart';

void main() {
  DateTime at(int hour, [int minute = 0]) =>
      DateTime(2026, 7, 4, hour, minute);

  group('gateTimeFor 基本境界', () {
    test('8:59 は当日9時ゲート', () {
      expect(AppNotifier.gateTimeFor(at(8, 59)), DateTime(2026, 7, 4, 9));
    });
    test('9:00 ちょうどは当日12時ゲート', () {
      expect(AppNotifier.gateTimeFor(at(9, 0)), DateTime(2026, 7, 4, 12));
    });
    test('11:59 は当日12時ゲート', () {
      expect(AppNotifier.gateTimeFor(at(11, 59)), DateTime(2026, 7, 4, 12));
    });
    test('12:00 ちょうどは当日21時ゲート', () {
      expect(AppNotifier.gateTimeFor(at(12, 0)), DateTime(2026, 7, 4, 21));
    });
    test('20:59 は当日21時ゲート', () {
      expect(AppNotifier.gateTimeFor(at(20, 59)), DateTime(2026, 7, 4, 21));
    });
    test('21:00 ちょうどは翌日9時ゲート', () {
      expect(AppNotifier.gateTimeFor(at(21, 0)), DateTime(2026, 7, 5, 9));
    });
    test('23:59 は翌日9時ゲート', () {
      expect(AppNotifier.gateTimeFor(at(23, 59)), DateTime(2026, 7, 5, 9));
    });
  });

  group('【回帰】0時バグ', () {
    // かつて日付をまたぐ深夜のすれ違いが間違ったゲートに割り当てられた
    test('0:00 は当日9時ゲート（翌日でも前日でもない）', () {
      expect(AppNotifier.gateTimeFor(at(0, 0)), DateTime(2026, 7, 4, 9));
    });
    test('0:30 は当日9時ゲート', () {
      expect(AppNotifier.gateTimeFor(at(0, 30)), DateTime(2026, 7, 4, 9));
    });
    test('月末0時台でも月ズレしない (7/31 0:10 → 7/31 9:00)', () {
      expect(AppNotifier.gateTimeFor(DateTime(2026, 7, 31, 0, 10)),
          DateTime(2026, 7, 31, 9));
    });
  });

  group('【回帰】18時バグ', () {
    // かつて18時台が誤ったゲート（翌朝扱い等）になった
    test('18:00 は当日21時ゲート', () {
      expect(AppNotifier.gateTimeFor(at(18, 0)), DateTime(2026, 7, 4, 21));
    });
    test('18:30 は当日21時ゲート', () {
      expect(AppNotifier.gateTimeFor(at(18, 30)), DateTime(2026, 7, 4, 21));
    });
    test('18:59 は当日21時ゲート', () {
      expect(AppNotifier.gateTimeFor(at(18, 59)), DateTime(2026, 7, 4, 21));
    });
  });

  group('月末・年末の日またぎ', () {
    test('12/31 22:00 → 翌年1/1 9:00', () {
      expect(AppNotifier.gateTimeFor(DateTime(2026, 12, 31, 22)),
          DateTime(2027, 1, 1, 9));
    });
    test('7/31 21:30 → 8/1 9:00', () {
      expect(AppNotifier.gateTimeFor(DateTime(2026, 7, 31, 21, 30)),
          DateTime(2026, 8, 1, 9));
    });
  });

  group('【回帰】21時以降のすれ違いが画面から消えるバグ', () {
    // 21〜24時のすれ違いは翌朝9時ゲートに割り当てられるが、
    // 画面が「今日の9/12/21」しか並べていなかったため、どの行にも現れず
    // 「出会っているのに何も起きない」状態になっていた。
    test('22:00 時点の一覧に翌朝9時の開門が含まれる', () {
      final gates = AppNotifier.gatesToShow(at(22));
      expect(gates.contains(DateTime(2026, 7, 5, 9)), isTrue);
    });

    test('20:59 時点では翌朝の開門を並べない', () {
      final gates = AppNotifier.gatesToShow(at(20, 59));
      expect(gates.length, 3);
      expect(gates.contains(DateTime(2026, 7, 5, 9)), isFalse);
    });

    test('不変条件: どの時刻のすれ違いも必ずいずれかの開門行に現れる', () {
      for (var h = 0; h < 24; h++) {
        for (final m in [0, 30, 59]) {
          final t = at(h, m);
          expect(
            AppNotifier.gatesToShow(t).contains(AppNotifier.gateTimeFor(t)),
            isTrue,
            reason: '$h:$m のすれ違いがどの開門にも割り当たっていない',
          );
        }
      }
    });

    test('月またぎでも翌朝の開門が正しい (7/31 22:00 → 8/1 9:00)', () {
      final gates = AppNotifier.gatesToShow(DateTime(2026, 7, 31, 22));
      expect(gates.last, DateTime(2026, 8, 1, 9));
    });
  });
}
