// ignore_for_file: avoid_dynamic_calls

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitscholar/application/execution/execution_service.dart';
import 'package:gitscholar/domain/failures.dart';
import 'package:gitscholar/domain/repositories/execution_backend.dart';
import 'package:gitscholar/infrastructure/execution/jupyter_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nbformat/nbformat.dart';

import '../fakes/test_env.dart';

class FakeBackend implements ExecutionBackend {
  final uploads = <String, Uint8List>{};
  final executed = <String>[];
  var interrupts = 0;
  var counter = 0;
  Duration delay = Duration.zero;

  @override
  Future<String> status() async => '2.0';
  @override
  Future<List<KernelSpecInfo>> kernelSpecs() async => const [
    KernelSpecInfo(
      name: 'python3',
      displayName: 'Python 3',
      language: 'python',
    ),
  ];
  @override
  Future<String> startKernel(String name) async => 'k-$name';
  @override
  Stream<ExecOutput> execute(String kernelId, String code) async* {
    executed.add(code);
    await Future<void>.delayed(delay);
    yield ExecInput(++counter);
    if (code.contains('raise')) {
      yield const ExecError('ValueError', 'boom', [
        'Traceback',
        'ValueError: boom',
      ]);
      return;
    }
    yield const ExecStream('stdout', 'hello ');
    yield const ExecStream('stdout', 'world\n');
    yield const ExecDisplay({'image/png': 'iVBOR', 'text/plain': '<Figure>'});
  }

  @override
  Future<void> interrupt(String kernelId) async => interrupts++;
  @override
  Future<void> restart(String kernelId) async {}
  @override
  Future<void> shutdown(String kernelId) async {}
  @override
  Future<void> uploadFile(String path, Uint8List bytes) async =>
      uploads[path] = bytes;
  @override
  Future<Uint8List> downloadFile(String path) async => uploads[path]!;
}

void main() {
  late TestEnv env;
  late FakeBackend backend;
  late ExecutionService exec;

  setUp(() async {
    env = await TestEnv.create();
    env.github.seed({
      'notebooks/analysis.ipynb': serializeNotebook(
        Notebook(
          cells: [
            CodeCell(id: 'a', source: 'print("hi")'),
            CodeCell(id: 'b', source: 'raise ValueError'),
            CodeCell(id: 'c', source: 'never'),
          ],
          metadata: {
            'kernelspec': {'language': 'python', 'name': 'python3'},
          },
        ),
      ),
      'notebooks/data.csv': 'x\n1\n',
      'other/x.py': 'x',
    });
    backend = FakeBackend();
    exec = ExecutionService(
      backend: backend,
      db: env.db,
      workspaces: env.workspaces,
      editing: env.editing,
    );
  });
  tearDown(() => env.dispose());

  test('runCode collects output and summarises for AI', () async {
    final r = await exec.runCode('print(1)');
    expect(r.hasError, isFalse);
    final text = r.toText();
    expect(text, contains('hello world'));
    expect(text, contains('[image output: 1]'));
    expect(exec.log.single.label, 'print(1)');
  });

  test('timeout interrupts', () async {
    backend.delay = const Duration(milliseconds: 200);
    final r = await exec.runCode(
      'slow',
      timeout: const Duration(milliseconds: 20),
    );
    expect(r.timedOut, isTrue);
    expect(r.hasError, isTrue);
    expect(backend.interrupts, 1);
  });

  test('sync uploads directory once, then only changed files', () async {
    final ws = await env.open();
    expect(await exec.syncForPath(ws, 'notebooks/analysis.ipynb'), 2);
    expect(
      backend.uploads.keys,
      containsAll([
        'gitscholar/alice__research/notebooks/analysis.ipynb',
        'gitscholar/alice__research/notebooks/data.csv',
      ]),
    );
    expect(await exec.syncForPath(ws, 'notebooks/analysis.ipynb'), 0);
    await env.editing.saveText(ws, 'notebooks/data.csv', 'x\n2\n');
    expect(await exec.syncForPath(ws, 'notebooks/analysis.ipynb'), 1);
  });

  test(
    'runNotebookCells updates outputs, stops at error, saves pending',
    () async {
      final ws = await env.open();
      final nb = parseNotebook(
        (await env.workspaces.loadFile(ws, 'notebooks/analysis.ipynb')).text!,
      );
      final updated = await exec.runNotebookCells(
        ws,
        'notebooks/analysis.ipynb',
        nb,
        [0, 1, 2],
      );
      final c0 = updated.cells[0] as CodeCell;
      expect(
        c0.outputs.first,
        isA<StreamOutput>().having((o) => o.text, 'merged', 'hello world\n'),
      );
      expect(c0.outputs[1], isA<DisplayDataOutput>());
      expect(c0.executionCount, isNotNull);
      expect((updated.cells[1] as CodeCell).outputs.single, isA<ErrorOutput>());
      expect((updated.cells[2] as CodeCell).outputs, isEmpty);
      expect(backend.executed.first, contains('os.chdir'));
      final saved = parseNotebook(
        (await env.workspaces.loadFile(ws, 'notebooks/analysis.ipynb')).text!,
      );
      expect((saved.cells[0] as CodeCell).outputs, hasLength(2));
    },
  );

  test('renderQuarto path helper', () {
    expect(
      ExecutionService.renderedPath('manuscript/paper.qmd', 'html'),
      'manuscript/paper.html',
    );
  });

  group('JupyterClient', () {
    test('rejects http unless allowed', () {
      expect(
        () => JupyterClient(baseUrl: 'http://x', token: 't'),
        throwsA(isA<ValidationFailure>()),
      );
      JupyterClient(
        baseUrl: 'http://localhost:8888',
        token: 't',
        allowInsecure: true,
      );
    });

    test('REST calls send token and parse', () async {
      final requests = <http.Request>[];
      final client = JupyterClient(
        baseUrl: 'https://hub.example.org/user/alice',
        token: 'tok',
        client: MockClient((req) async {
          requests.add(req);
          final p = req.url.path;
          if (p.endsWith('/api')) {
            return http.Response('{"version":"2.14"}', 200);
          }
          if (p.endsWith('/api/kernelspecs')) {
            return http.Response(
              jsonEncode({
                'kernelspecs': {
                  'ir': {
                    'spec': {'display_name': 'R', 'language': 'R'},
                  },
                },
              }),
              200,
            );
          }
          if (p.endsWith('/api/kernels')) {
            return http.Response('{"id":"k1"}', 201);
          }
          if (req.method == 'GET' && p.contains('/api/contents/dir')) {
            return http.Response('', 404);
          }
          return http.Response('{}', 200);
        }),
      );
      expect(await client.status(), '2.14');
      expect(requests.first.headers['Authorization'], 'token tok');
      expect(
        requests.first.url.toString(),
        'https://hub.example.org/user/alice/api',
      );
      expect((await client.kernelSpecs()).single.language, 'R');
      expect(await client.startKernel('ir'), 'k1');
      await client.uploadFile('dir/a b.txt', Uint8List.fromList([1]));
      final put = requests.lastWhere((r) => r.method == 'PUT');
      expect(put.url.path, endsWith('/api/contents/dir/a%20b.txt'));
      expect(jsonDecode(put.body)['format'], 'base64');
      expect(
        requests.where(
          (r) => r.method == 'PUT' && r.url.path.endsWith('/api/contents/dir'),
        ),
        hasLength(1),
      );
    });

    test('401 maps to AuthFailure', () async {
      final client = JupyterClient(
        baseUrl: 'https://x',
        token: 't',
        client: MockClient((_) async => http.Response('', 403)),
      );
      expect(client.status(), throwsA(isA<AuthFailure>()));
    });

    test('execute request and iopub parsing', () {
      final client = JupyterClient(baseUrl: 'https://x', token: 't');
      final req = client.executeRequest('id1', 'print(1)');
      expect(req['header']['msg_type'], 'execute_request');
      expect(req['header']['version'], '5.3');
      expect(req['content']['code'], 'print(1)');
      expect(
        JupyterClient.parseIopub('stream', {'name': 'stderr', 'text': 'w'}),
        isA<ExecStream>(),
      );
      expect(
        JupyterClient.parseIopub('execute_result', {
          'data': {'text/plain': '1'},
          'execution_count': 3,
        }),
        isA<ExecDisplay>().having((d) => d.isResult, 'result', isTrue),
      );
      expect(
        JupyterClient.parseIopub('error', {
          'ename': 'E',
          'evalue': 'v',
          'traceback': ['t'],
        }),
        isA<ExecError>(),
      );
      expect(
        JupyterClient.parseIopub('execute_input', {'execution_count': 2}),
        isA<ExecInput>(),
      );
      expect(
        JupyterClient.parseIopub('status', {'execution_state': 'busy'}),
        isNull,
      );
    });
  });
}
