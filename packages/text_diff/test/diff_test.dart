import 'dart:math';

import 'package:test/test.dart';
import 'package:text_diff/text_diff.dart';

void main() {
  group('splitLines', () {
    test('empty', () => expect(splitLines(''), isEmpty));
    test(
      'trailing newline does not add a line',
      () => expect(splitLines('a\nb\n'), ['a', 'b']),
    );
    test('no trailing newline', () => expect(splitLines('a\nb'), ['a', 'b']));
    test('crlf normalised', () => expect(splitLines('a\r\nb\r\n'), ['a', 'b']));
  });

  group('diffLines', () {
    test('empty to empty', () => expect(diffLines('', ''), isEmpty));

    test('insert only', () {
      final d = diffLines('', 'a\nb\n');
      expect(d.map((l) => l.op), [DiffOp.insert, DiffOp.insert]);
      expect(d.first.newLineNo, 1);
      expect(stats(d).added, 2);
    });

    test('delete only', () {
      final d = diffLines('a\nb\n', '');
      expect(d.map((l) => l.op), [DiffOp.delete, DiffOp.delete]);
      expect(stats(d).deleted, 2);
    });

    test('replace middle line', () {
      final d = diffLines('a\nb\nc\n', 'a\nx\nc\n');
      expect(d.map((l) => l.toString()), [' a', '-b', '+x', ' c']);
      expect(d[3].oldLineNo, 3);
      expect(d[3].newLineNo, 3);
    });

    test('no common lines', () {
      final d = diffLines('a\nb', 'c\nd');
      expect(stats(d).added, 2);
      expect(stats(d).deleted, 2);
    });

    test('trailing newline difference is ignored at line level', () {
      expect(diffLines('a\n', 'a').every((l) => l.op == DiffOp.equal), isTrue);
    });

    test('too large throws', () {
      final big = List.filled(maxDiffLines + 1, 'x').join('\n');
      expect(() => diffLines(big, ''), throwsA(isA<DiffTooLarge>()));
    });

    test('property: apply(diff) == b and revert(diff) == a', () {
      final rnd = Random(42);
      String gen() => List.generate(
        rnd.nextInt(30),
        (_) => String.fromCharCode(97 + rnd.nextInt(4)),
      ).join('\n');
      for (var i = 0; i < 300; i++) {
        final a = gen();
        final b = gen();
        final d = diffLines(a, b);
        expect(applyDiff(d), splitLines(b), reason: 'a=$a b=$b');
        expect(revertDiff(d), splitLines(a), reason: 'a=$a b=$b');
      }
    });

    test('minimal edit for simple case', () {
      final d = diffLines('a\nb\nc\nd\n', 'a\nc\nd\ne\n');
      expect(stats(d).added, 1);
      expect(stats(d).deleted, 1);
    });
  });

  group('hunks and unified', () {
    test('no changes yields no hunks', () {
      expect(toHunks(diffLines('a\nb', 'a\nb')), isEmpty);
    });

    test('single hunk with context', () {
      final a = List.generate(10, (i) => 'l$i').join('\n');
      final b = a.replaceFirst('l5', 'X');
      final hunks = toHunks(diffLines(a, b), context: 2);
      expect(hunks, hasLength(1));
      expect(hunks.single.header, '@@ -4,5 +4,5 @@');
    });

    test('distant changes produce two hunks', () {
      final a = List.generate(30, (i) => 'l$i').join('\n');
      final b = a.replaceFirst('l1\n', 'X\n').replaceFirst('l28', 'Y');
      expect(toHunks(diffLines(a, b)), hasLength(2));
    });

    test('insert into empty file header', () {
      final hunks = toHunks(diffLines('', 'a\n'));
      expect(hunks.single.header, '@@ -0,0 +1 @@');
    });

    test('unified output', () {
      final out = toUnified(
        toHunks(diffLines('a\nb\n', 'a\nc\n')),
        oldPath: 'x.txt',
        newPath: 'x.txt',
      );
      expect(out, '--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n a\n-b\n+c\n');
    });
  });

  test('DiffLine equality and toString', () {
    const l = DiffLine(DiffOp.equal, 'a', oldLineNo: 1, newLineNo: 1);
    expect(l, const DiffLine(DiffOp.equal, 'a', oldLineNo: 1, newLineNo: 1));
    expect(
      l.hashCode,
      const DiffLine(DiffOp.equal, 'a', oldLineNo: 1, newLineNo: 1).hashCode,
    );
    expect(const DiffTooLarge(5).toString(), contains('5'));
  });
}
