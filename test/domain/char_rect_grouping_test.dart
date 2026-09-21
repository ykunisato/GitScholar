import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/domain/services/char_rect_grouping.dart';

/// 1文字ぶんの矩形。PDF座標なので y は上が大きい。
HighlightRect glyph({
  required double left,
  required double top,
  double size = 10,
}) =>
    HighlightRect(left: left, top: top, right: left + size, bottom: top - size);

void main() {
  group('groupCharRects', () {
    test('横書きの連続した文字は1本の帯になる', () {
      final rects = groupCharRects([
        glyph(left: 100, top: 500),
        glyph(left: 110, top: 500),
        glyph(left: 120, top: 500),
      ]);
      expect(rects, hasLength(1));
      expect(rects.single.left, 100);
      expect(rects.single.right, 130);
    });

    test('縦書きの連続した文字も1本の帯になる', () {
      // これが対応前は1文字ずつ別々の矩形になっていた。
      final rects = groupCharRects([
        glyph(left: 400, top: 700),
        glyph(left: 400, top: 690),
        glyph(left: 400, top: 680),
      ]);
      expect(rects, hasLength(1));
      expect(rects.single.top, 700);
      expect(rects.single.bottom, 670);
      expect(rects.single.left, 400);
      expect(rects.single.right, 410);
    });

    test('横書きで行が変わると分かれる', () {
      final rects = groupCharRects([
        glyph(left: 100, top: 500),
        glyph(left: 110, top: 500),
        glyph(left: 100, top: 480),
      ]);
      expect(rects, hasLength(2));
    });

    test('縦書きで列が変わると分かれる', () {
      final rects = groupCharRects([
        glyph(left: 400, top: 700),
        glyph(left: 400, top: 690),
        glyph(left: 380, top: 700),
      ]);
      expect(rects, hasLength(2));
    });

    test('同じ行でも段組みをまたぐと分かれる', () {
      final rects = groupCharRects([
        glyph(left: 100, top: 500),
        glyph(left: 300, top: 500),
      ]);
      expect(rects, hasLength(2), reason: '字送りが飛んでいる');
    });

    test('面積のない矩形は無視する', () {
      final rects = groupCharRects([
        glyph(left: 100, top: 500),
        const HighlightRect(left: 110, top: 500, right: 110, bottom: 500),
        glyph(left: 110, top: 500),
      ]);
      expect(rects, hasLength(1));
      expect(rects.single.right, 120);
    });

    test('空の入力は空を返す', () {
      expect(groupCharRects(const []), isEmpty);
    });
  });
}
