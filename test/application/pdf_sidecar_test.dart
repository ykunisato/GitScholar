import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/application/editing/pdf_sidecar_service.dart';
import 'package:gitscholar/domain/entities/entities.dart';

import '../fakes/test_env.dart';

void main() {
  late TestEnv env;
  late PdfSidecarService sidecar;
  var ids = 0;

  setUp(() async {
    env = await TestEnv.create();
    env.github.seed({
      'papers/paper.pdf': '%PDF-1.7 fake\n',
      'papers/read.pdf': '%PDF-1.7 fake\n',
      'papers/read.md': '# Read\n',
    });
    ids = 0;
    sidecar = PdfSidecarService(
      editing: env.editing,
      workspaces: env.workspaces,
      clock: () => DateTime.utc(2026, 9, 16, 10),
      newId: () => 'h${++ids}',
    );
  });
  tearDown(() => env.dispose());

  const rect = HighlightRect(left: 10, top: 100, right: 200, bottom: 88);

  group('sidecar paths', () {
    test('derive from the PDF name', () {
      expect(
        PdfSidecarService.annotationsPathFor('papers/paper.pdf'),
        'papers/paper.annotations.json',
      );
      expect(
        PdfSidecarService.notesPathFor('papers/paper.pdf'),
        'papers/paper.md',
      );
      expect(PdfSidecarService.notesPathFor('paper.pdf'), 'paper.md');
    });
  });

  group('highlights', () {
    test('are stored in the sidecar and read back', () async {
      final ws = await env.open();
      await sidecar.addHighlights(
        ws,
        'papers/paper.pdf',
        rectsByPage: {
          3: [rect],
        },
        color: HighlightColor.green,
        text: 'effect size',
      );
      final pending = await env.pending(ws);
      expect(pending.single.path, 'papers/paper.annotations.json');
      expect(pending.single.kind, ChangeKind.create);

      final loaded = await sidecar.load(ws, 'papers/paper.pdf');
      final h = loaded.highlights.single;
      expect(h.id, 'h1');
      expect(h.page, 3);
      expect(h.color, HighlightColor.green);
      expect(h.text, 'effect size');
      expect(h.rects.single, rect);
      expect(loaded.forPage(3), hasLength(1));
      expect(loaded.forPage(2), isEmpty);
    });

    test('a multi-page selection makes one highlight per page', () async {
      final ws = await env.open();
      final annotations = await sidecar.addHighlights(
        ws,
        'papers/paper.pdf',
        rectsByPage: {
          1: [rect],
          2: [rect, rect],
        },
        color: HighlightColor.yellow,
        text: 'spanning',
      );
      expect(annotations.highlights.map((h) => h.page), [1, 2]);
      expect(annotations.highlights.last.rects, hasLength(2));
    });

    test('removing the last one discards the pending sidecar', () async {
      final ws = await env.open();
      await sidecar.addHighlights(
        ws,
        'papers/paper.pdf',
        rectsByPage: {
          1: [rect],
        },
        color: HighlightColor.blue,
        text: 'a',
      );
      await sidecar.addHighlights(
        ws,
        'papers/paper.pdf',
        rectsByPage: {
          1: [rect],
        },
        color: HighlightColor.pink,
        text: 'b',
      );
      var left = await sidecar.removeHighlight(ws, 'papers/paper.pdf', 'h1');
      expect(left.highlights.map((h) => h.id), ['h2']);
      left = await sidecar.removeHighlight(ws, 'papers/paper.pdf', 'h2');
      expect(left.highlights, isEmpty);
      expect(await env.pending(ws), isEmpty);
    });

    test('malformed sidecar content reads as empty', () async {
      final ws = await env.open();
      await env.editing.saveText(
        ws,
        'papers/paper.annotations.json',
        'not json',
      );
      expect((await sidecar.load(ws, 'papers/paper.pdf')).highlights, isEmpty);
    });
  });

  group('notes', () {
    test('create the Markdown file with a heading and a link', () async {
      final ws = await env.open();
      final path = await sidecar.appendNote(
        ws,
        'papers/paper.pdf',
        text: 'Check the sample size',
        page: 4,
        quote: 'we recruited 30 students',
      );
      expect(path, 'papers/paper.md');
      final text = (await env.workspaces.loadFile(ws, path)).text;
      expect(
        text,
        '# paper\n'
        '\n'
        '[paper.pdf](<paper.pdf>)\n'
        '\n'
        '- **p.4** Check the sample size\n'
        '  > we recruited 30 students\n'
        '\n',
      );
    });

    test('append to the end of an existing file', () async {
      final ws = await env.open();
      await sidecar.appendNote(ws, 'papers/read.pdf', text: 'first', page: 1);
      await sidecar.appendNote(ws, 'papers/read.pdf', text: 'second', page: 9);
      final text = (await env.workspaces.loadFile(ws, 'papers/read.md')).text;
      expect(text, '# Read\n\n- **p.1** first\n\n- **p.9** second\n\n');
      final pending = await env.pending(ws);
      expect(pending.single.path, 'papers/read.md');
      expect(pending.single.kind, ChangeKind.modify);
    });

    test('keep multi-line notes inside the list item', () {
      expect(
        PdfSidecarService.noteBlock(text: 'one\ntwo', page: 2),
        '- **p.2** one\n  two\n\n',
      );
      expect(PdfSidecarService.noteBlock(text: 'plain'), '- plain\n\n');
    });
  });
}
