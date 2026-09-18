import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/services/github_url.dart';

void main() {
  group('parseGitHubUrl', () {
    test('plain repository link', () {
      final t = parseGitHubUrl('https://github.com/alice/research')!;
      expect(t.fullName, 'alice/research');
      expect(t.branch, isNull);
      expect(t.path, isNull);
      expect(t.location, '/ws/alice/research');
    });

    test('finds the link inside shared text', () {
      final t = parseGitHubUrl(
        'これ見て https://github.com/alice/research のリポジトリ',
      )!;
      expect(t.fullName, 'alice/research');
    });

    test('blob link carries branch and path', () {
      final t = parseGitHubUrl(
        'https://github.com/alice/research/blob/main/notes/a.md',
      )!;
      expect(t.branch, 'main');
      expect(t.path, 'notes/a.md');
      expect(t.location, '/ws/alice/research?branch=main&path=notes%2Fa.md');
    });

    test('tree link to a directory', () {
      final t = parseGitHubUrl(
        'https://github.com/alice/research/tree/dev/papers',
      )!;
      expect(t.branch, 'dev');
      expect(t.path, 'papers');
    });

    test('tree link to a branch root keeps the branch', () {
      final t = parseGitHubUrl('https://github.com/alice/research/tree/dev')!;
      expect(t.branch, 'dev');
      expect(t.path, isNull);
      expect(t.location, '/ws/alice/research?branch=dev');
    });

    test('other repository pages open the repository', () {
      expect(
        parseGitHubUrl('https://github.com/alice/research/issues/12')!.location,
        '/ws/alice/research',
      );
      expect(
        parseGitHubUrl(
          'https://github.com/alice/research/discussions/7',
        )!.fullName,
        'alice/research',
      );
    });

    test('clone url drops the .git suffix', () {
      expect(
        parseGitHubUrl('https://github.com/alice/research.git')!.fullName,
        'alice/research',
      );
    });

    test('www host and query strings', () {
      expect(
        parseGitHubUrl(
          'https://www.github.com/alice/research?tab=readme',
        )!.fullName,
        'alice/research',
      );
    });

    test('rejects non-repository links', () {
      expect(parseGitHubUrl('https://github.com/settings/profile'), isNull);
      expect(parseGitHubUrl('https://github.com/alice'), isNull);
      expect(parseGitHubUrl('https://gitlab.com/alice/research'), isNull);
      expect(parseGitHubUrl('https://example.com/github.com/a/b'), isNull);
      expect(parseGitHubUrl('リンクはありません'), isNull);
    });

    test('equality is by value', () {
      expect(
        parseGitHubUrl('https://github.com/a/b'),
        parseGitHubUrl('https://github.com/a/b'),
      );
    });
  });
}
