import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/domain/entities/entities.dart';
import 'package:gitscholar/domain/failures.dart';
import 'package:gitscholar/domain/services/file_kind_detector.dart';
import 'package:gitscholar/domain/services/ignore_rules.dart';
import 'package:gitscholar/domain/services/path_utils.dart';
import 'package:gitscholar/domain/services/tree_view.dart';

void main() {
  group('FileKindDetector', () {
    const table = {
      'a.pdf': FileKind.pdf,
      'x/n.ipynb': FileKind.notebook,
      'README.md': FileKind.markdown,
      'p.qmd': FileKind.markdown,
      'p.Rmd': FileKind.markdown,
      'a.py': FileKind.code,
      'model.R': FileKind.code,
      'refs.bib': FileKind.code,
      'cfg.yaml': FileKind.code,
      'data.csv': FileKind.code,
      'img.PNG': FileKind.image,
      'fig.svg': FileKind.image,
      'notes.txt': FileKind.text,
      'Makefile': FileKind.text,
      '.env.example': FileKind.text,
      'thing.xyz': FileKind.unknown,
    };
    for (final e in table.entries) {
      test(e.key, () => expect(FileKindDetector.fromPath(e.key), e.value));
    }

    test('content detection', () {
      expect(
        FileKindDetector.fromContent('a.xyz', Uint8List.fromList([0, 1, 2])),
        FileKind.binary,
      );
      expect(
        FileKindDetector.fromContent(
          'a.xyz',
          Uint8List.fromList(utf8.encode('hello')),
        ),
        FileKind.text,
      );
      expect(
        FileKindDetector.fromContent(
          'a.txt',
          Uint8List.fromList([0xff, 0xfe, 0x41]),
        ),
        FileKind.binary,
      );
      expect(FileKindDetector.isTextEditable(FileKind.code), isTrue);
      expect(FileKindDetector.isTextEditable(FileKind.pdf), isFalse);
      expect(FileKindDetector.maxViewerBytes(FileKind.pdf), 100 * 1024 * 1024);
    });
  });

  group('normalizePath', () {
    test('normalises', () {
      expect(normalizePath('a/./b'), 'a/b');
      expect(normalizePath('a//b/'), 'a/b');
      expect(normalizePath(' notes/x.md '), 'notes/x.md');
    });
    test('rejects', () {
      for (final bad in [
        '../x',
        'a/../b',
        '/etc/passwd',
        r'a\b',
        '',
        '.',
        'C:/x',
      ]) {
        expect(
          () => normalizePath(bad),
          throwsA(isA<ValidationFailure>()),
          reason: bad,
        );
      }
      expect(tryNormalizePath('../x'), isNull);
    });
    test('resolveRelativeLink', () {
      expect(
        resolveRelativeLink('notes/a.md', '../papers/a.pdf'),
        'papers/a.pdf',
      );
      expect(resolveRelativeLink('notes/a.md', './b.md#sec'), 'notes/b.md');
      expect(resolveRelativeLink('a.md', 'img/my%20fig.png'), 'img/my fig.png');
      expect(resolveRelativeLink('notes/a.md', '/README.md'), 'README.md');
      expect(resolveRelativeLink('a.md', 'https://x.org'), isNull);
      expect(resolveRelativeLink('a.md', '#top'), isNull);
      expect(resolveRelativeLink('a.md', '../../x'), isNull);
    });
  });

  group('IgnoreRules', () {
    final rules = IgnoreRules.fromFile(
      'notes/\n!notes/keep.md\ndata/*.csv\n/root.txt\n# comment\n\n',
    );
    test('defaults', () {
      expect(rules.isIgnored('.env'), isTrue);
      expect(rules.isIgnored('sub/.env'), isTrue);
      expect(rules.isIgnored('keys/server.pem'), isTrue);
      expect(rules.isIgnored('a/secrets/token.txt'), isTrue);
      expect(rules.isIgnored('secrets/token.txt'), isTrue);
      expect(rules.isIgnored('README.md'), isFalse);
    });
    test('directory pattern ignores children', () {
      expect(rules.isIgnored('notes/a.md'), isTrue);
      expect(rules.isIgnored('x/notes/a.md'), isTrue);
    });
    test(
      'negation cannot re-include inside ignored directory (gitignore semantics)',
      () {
        expect(rules.isIgnored('notes/keep.md'), isTrue);
        final r2 = IgnoreRules(['*.md', '!keep.md']);
        expect(r2.isIgnored('keep.md'), isFalse);
        expect(r2.isIgnored('other.md'), isTrue);
      },
    );
    test('anchored and wildcard', () {
      expect(rules.isIgnored('data/x.csv'), isTrue);
      expect(rules.isIgnored('data/sub/x.csv'), isFalse);
      expect(rules.isIgnored('root.txt'), isTrue);
      expect(rules.isIgnored('a/root.txt'), isFalse);
      expect(IgnoreRules(['file?.[ch]']).isIgnored('src/file1.c'), isTrue);
      expect(IgnoreRules(['a/**/z']).isIgnored('a/b/c/z'), isTrue);
    });
  });

  test('buildTree sorts directories first and flattens by expansion', () {
    final entries = [
      const TreeEntry(path: 'b.md', type: TreeEntryType.blob, sha: '1'),
      const TreeEntry(path: 'dir', type: TreeEntryType.tree, sha: 't'),
      const TreeEntry(path: 'dir/x.py', type: TreeEntryType.blob, sha: '2'),
      const TreeEntry(path: 'a.md', type: TreeEntryType.blob, sha: '3'),
    ];
    final root = buildTree(entries, const []);
    expect(flattenVisible(root, {}).map((n) => n.path), [
      'dir',
      'a.md',
      'b.md',
    ]);
    expect(flattenVisible(root, {'dir'}).map((n) => n.path), [
      'dir',
      'dir/x.py',
      'a.md',
      'b.md',
    ]);
    expect(filterFiles(root, 'X.P').single.path, 'dir/x.py');
    expect(root.children.first.depth, 0);
  });

  test('Settings json round trip and defaults', () {
    const s = Settings();
    expect(s.aiModel, 'claude-opus-5');
    expect(s.aiEffort, 'high');
    final s2 = Settings.fromJson(
      jsonDecode(jsonEncode(s.copyWith(aiEffort: 'low', locale: 'en').toJson()))
          as Map<String, dynamic>,
    );
    expect(s2.aiEffort, 'low');
    expect(s2.locale, 'en');
    expect(s2.copyWith(clearLocale: true).locale, isNull);
  });

  test('RepositoryRef effective AI access', () {
    final pub = RepositoryRef(
      owner: 'o',
      name: 'n',
      isPrivate: false,
      defaultBranch: 'main',
      updatedAt: DateTime(2026),
    );
    expect(pub.effectiveAiAccess, AiAccess.allowed);
    expect(
      pub.copyWith(aiAccess: AiAccess.denied).effectiveAiAccess,
      AiAccess.denied,
    );
    final priv = RepositoryRef(
      owner: 'o',
      name: 'p',
      isPrivate: true,
      defaultBranch: 'main',
      updatedAt: DateTime(2026),
    );
    expect(priv.effectiveAiAccess, AiAccess.ask);
  });
}
