import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/services/git_attributes.dart';

void main() {
  group('isLfsTracked', () {
    const typical = '*.pdf filter=lfs diff=lfs merge=lfs -text\n';

    test('matches the extension at any depth', () {
      expect(isLfsTracked(typical, 'paper.pdf'), isTrue);
      expect(isLfsTracked(typical, '1-to-read/図解雑学 複雑系.pdf'), isTrue);
    });

    test('leaves other files alone', () {
      expect(isLfsTracked(typical, 'notes/paper.md'), isFalse);
      expect(isLfsTracked(typical, 'paper.annotations.json'), isFalse);
    });

    test('ignores lines without the lfs filter', () {
      expect(isLfsTracked('*.pdf text\n', 'a.pdf'), isFalse);
      expect(isLfsTracked('# *.pdf filter=lfs\n', 'a.pdf'), isFalse);
    });

    test('honours a directory prefix', () {
      const attrs = 'papers/*.pdf filter=lfs\n';
      expect(isLfsTracked(attrs, 'papers/a.pdf'), isTrue);
      expect(isLfsTracked(attrs, 'other/a.pdf'), isFalse);
      expect(isLfsTracked(attrs, 'papers/deep/a.pdf'), isFalse);
    });

    test('handles ** and anchoring', () {
      expect(isLfsTracked('**/*.psd filter=lfs\n', 'a/b/c.psd'), isTrue);
      expect(isLfsTracked('/root.bin filter=lfs\n', 'root.bin'), isTrue);
      expect(isLfsTracked('/root.bin filter=lfs\n', 'sub/root.bin'), isFalse);
    });

    test('no file or no rules means not tracked', () {
      expect(isLfsTracked(null, 'a.pdf'), isFalse);
      expect(isLfsTracked('', 'a.pdf'), isFalse);
    });
  });
}
