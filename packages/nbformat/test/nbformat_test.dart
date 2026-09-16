import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:nbformat/nbformat.dart';
import 'package:test/test.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

void main() {
  group('round trip', () {
    for (final name in [
      'empty.ipynb',
      'markdown_only.ipynb',
      'outputs.ipynb',
      'v44_no_ids.ipynb',
    ]) {
      test(name, () {
        final original = fixture(name);
        final nb = parseNotebook(original);
        final out = serializeNotebook(nb);
        expect(jsonDecode(out), _normalise(jsonDecode(original)));
        expect(serializeNotebook(parseNotebook(out)), out);
      });
    }

    test('large stream round trip', () {
      final text = List.generate(5000, (i) => 'line $i\n').join();
      final nb = Notebook(
        cells: [
          CodeCell(
            id: 'x',
            outputs: [StreamOutput(name: 'stdout', text: text)],
          ),
        ],
      );
      final back = parseNotebook(serializeNotebook(nb));
      final out =
          (back.cells.single as CodeCell).outputs.single as StreamOutput;
      expect(out.text, text);
    });
  });

  group('parse', () {
    test('source string or list gives same result', () {
      final nb = parseNotebook(fixture('outputs.ipynb'));
      expect(nb.cells[0].source, "print('hello')\nprint('world')");
      expect(nb.cells[1].source, 'plt.plot([1,2])');
    });

    test('outputs typed', () {
      final nb = parseNotebook(fixture('outputs.ipynb'));
      final c0 = nb.cells[0] as CodeCell;
      expect(c0.outputs[0], isA<StreamOutput>());
      expect((c0.outputs[1] as StreamOutput).isStderr, isTrue);
      expect(c0.tags, ['setup']);
      final c1 = nb.cells[1] as CodeCell;
      expect(
        (c1.outputs.single as DisplayDataOutput).data.preferred(),
        'image/png',
      );
      final c2 = nb.cells[2] as CodeCell;
      final r = c2.outputs.single as ExecuteResultOutput;
      expect(r.executionCount, 3);
      expect(r.data.preferred(), 'text/html');
      expect(jsonDecode(r.data.entries['application/json']!), {
        'a': [1],
      });
      final c3 = nb.cells[3] as CodeCell;
      expect(c3.outputsHidden, isTrue);
      expect(c3.sourceHidden, isFalse);
      expect((c3.outputs.single as ErrorOutput).ename, 'ZeroDivisionError');
      expect(nb.cells[4].extra.containsKey('attachments'), isTrue);
      expect(nb.cells[5], isA<RawCell>());
      expect(nb.language, 'python');
    });

    test('language from kernelspec', () {
      expect(parseNotebook(fixture('v44_no_ids.ipynb')).language, 'R');
      expect(Notebook().language, isNull);
    });

    test('nbformat 3 rejected', () {
      expect(
        () => parseNotebook('{"nbformat":3,"nbformat_minor":0,"cells":[]}'),
        throwsA(isA<NbformatException>()),
      );
    });

    test('invalid input rejected', () {
      expect(() => parseNotebook('{'), throwsA(isA<NbformatException>()));
      expect(() => parseNotebook('[]'), throwsA(isA<NbformatException>()));
      expect(
        () => parseNotebook('{"nbformat":4}'),
        throwsA(isA<NbformatException>()),
      );
      expect(
        () => parseNotebook('{"cells":[]}'),
        throwsA(isA<NbformatException>()),
      );
      expect(
        () => parseNotebook(
          '{"nbformat":4,"cells":[{"cell_type":"weird","source":""}]}',
        ),
        throwsA(isA<NbformatException>()),
      );
      expect(
        () => parseNotebook('{"nbformat":4,"cells":[1]}'),
        throwsA(isA<NbformatException>()),
      );
      expect(
        () => parseNotebook(
          '{"nbformat":4,"cells":[{"cell_type":"code",'
          '"outputs":[{"output_type":"x"}]}]}',
        ),
        throwsA(isA<NbformatException>()),
      );
      expect(
        () => parseNotebook(
          '{"nbformat":4,"cells":[{"cell_type":"code","outputs":[1]}]}',
        ),
        throwsA(isA<NbformatException>()),
      );
    });

    test('unknown fields kept', () {
      final nb = parseNotebook(fixture('v44_no_ids.ipynb'));
      expect(nb.extra['custom_top_level'], {'keep': true});
    });
  });

  group('ids', () {
    test('4.4 does not gain ids', () {
      final out =
          jsonDecode(
                serializeNotebook(parseNotebook(fixture('v44_no_ids.ipynb'))),
              )
              as Map<String, dynamic>;
      expect((out['cells'] as List).first, isNot(contains('id')));
    });

    test('4.5 new cell gets 8-char id', () {
      final nb = parseNotebook(fixture('empty.ipynb'));
      nb.cells.add(MarkdownCell(source: 'hi'));
      serializeNotebook(nb);
      expect(nb.cells.single.id, matches(RegExp(r'^[a-z0-9]{8}$')));
      expect(Notebook.newCellId(Random(1)), hasLength(8));
    });
  });

  group('helpers', () {
    test('splitMultiline / joinMultiline', () {
      expect(splitMultiline(''), isEmpty);
      expect(splitMultiline('a\nb'), ['a\n', 'b']);
      expect(splitMultiline('a\n'), ['a\n']);
      expect(joinMultiline(null), '');
      expect(joinMultiline(5), '5');
    });

    test('stripAnsi', () {
      expect(stripAnsi('\x1b[0;31mErr\x1b[0m'), 'Err');
    });

    test('plain text rendering replaces images', () {
      final text = notebookToPlainText(parseNotebook(fixture('outputs.ipynb')));
      expect(text, contains('[cell 0, code]'));
      expect(text, contains('[image/png output]'));
      expect(text, isNot(contains('iVBORw0KGgo')));
      expect(text, contains('ZeroDivisionError: division by zero'));
      expect(text, contains('   a\n0  1'));
    });

    test('truncates long outputs', () {
      final nb = Notebook(
        cells: [
          CodeCell(
            outputs: [StreamOutput(name: 'stdout', text: 'x' * 50)],
          ),
        ],
      );
      expect(
        notebookToPlainText(nb, maxOutputChars: 10),
        contains('[truncated]'),
      );
    });

    test('copy is deep', () {
      final nb = parseNotebook(fixture('outputs.ipynb'));
      final c = nb.copy();
      (c.cells[0] as CodeCell).outputs.clear();
      c.metadata['x'] = 1;
      c.cells[0].metadata['tags'] = <String>[];
      expect((nb.cells[0] as CodeCell).outputs, hasLength(2));
      expect(nb.metadata.containsKey('x'), isFalse);
      expect(nb.cells[0].tags, ['setup']);
      expect(c.cells[1].copy(), isA<CodeCell>());
      expect(c.cells[4].copy(), isA<MarkdownCell>());
      expect(c.cells[5].copy(), isA<RawCell>());
      expect(
        (nb.cells[3] as CodeCell).copy().outputs.single,
        isA<ErrorOutput>(),
      );
      expect(
        (nb.cells[2] as CodeCell).copy().outputs.single,
        isA<ExecuteResultOutput>(),
      );
    });

    test('MimeBundle', () {
      expect(MimeBundle().preferred(), isNull);
      expect(MimeBundle({'x/y': 'a'}).preferred(), 'x/y');
      expect(MimeBundle.isJsonMime('application/vnd.plotly.v1+json'), isTrue);
      expect(const NbformatException('m').toString(), contains('m'));
    });
  });
}

/// Normalises string-form multiline fields to list form for comparison.
Object? _normalise(Object? json) {
  if (json is Map) {
    return {
      for (final e in json.entries)
        e.key: switch (e.key) {
          'source' ||
          'text' when e.value is String => splitMultiline(e.value as String),
          'data' when e.value is Map => {
            for (final d in (e.value as Map).entries)
              d.key:
                  d.value is String && !(d.key as String).startsWith('image/')
                  ? splitMultiline(d.value as String)
                  : d.value,
          },
          _ => _normalise(e.value),
        },
    };
  }
  if (json is List) return [for (final x in json) _normalise(x)];
  return json;
}
