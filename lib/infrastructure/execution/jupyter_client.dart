import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../domain/failures.dart';
import '../../domain/repositories/execution_backend.dart';

/// Opens a WebSocket (injectable for tests).
typedef WebSocketConnector =
    WebSocketChannel Function(Uri uri, Map<String, String> headers);

/// Jupyter Server REST + kernel WebSocket client (docs/11 T-050).
/// JupyterHub works by using the user server URL as [baseUrl].
class JupyterClient implements ExecutionBackend {
  JupyterClient({
    required String baseUrl,
    required this.token,
    http.Client? client,
    WebSocketConnector? connect,
    bool allowInsecure = false,
  }) : baseUri = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
       _http = client ?? http.Client(),
       _connect =
           connect ??
           ((uri, headers) =>
               IOWebSocketChannel.connect(uri, headers: headers)) {
    if (baseUri.scheme != 'https' && !allowInsecure) {
      throw const ValidationFailure('Jupyter URL must use https');
    }
  }

  final Uri baseUri;
  final String token;
  final http.Client _http;
  final WebSocketConnector _connect;
  final _session = const Uuid().v4();

  Map<String, String> get _headers => {'Authorization': 'token $token'};

  Uri _api(String path) => baseUri.resolve(path);

  String _encPath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  Future<http.Response> _req(String method, String path, {Object? body}) async {
    final req = http.Request(method, _api(path))..headers.addAll(_headers);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req));
    } on SocketException catch (e) {
      throw NetworkFailure(e.message, cause: e);
    } on http.ClientException catch (e) {
      throw NetworkFailure(e.message, cause: e);
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw AuthFailure('Jupyter authentication failed (${res.statusCode})');
    }
    if (res.statusCode == 404) {
      throw NotFoundFailure('Jupyter: not found $path');
    }
    if (res.statusCode >= 400) {
      throw UnknownFailure('Jupyter error ${res.statusCode}: ${res.body}');
    }
    return res;
  }

  @override
  Future<String> status() async {
    final res = await _req('GET', 'api');
    final j = jsonDecode(res.body);
    return j is Map ? '${j['version'] ?? 'unknown'}' : 'unknown';
  }

  @override
  Future<List<KernelSpecInfo>> kernelSpecs() async {
    final j =
        jsonDecode((await _req('GET', 'api/kernelspecs')).body)
            as Map<String, dynamic>;
    final specs = (j['kernelspecs'] as Map?) ?? const {};
    return [
      for (final e in specs.entries)
        KernelSpecInfo(
          name: '${e.key}',
          displayName:
              '${((e.value as Map)['spec'] as Map?)?['display_name'] ?? e.key}',
          language: '${((e.value as Map)['spec'] as Map?)?['language'] ?? ''}',
        ),
    ];
  }

  @override
  Future<String> startKernel(String name) async {
    final j =
        jsonDecode(
              (await _req('POST', 'api/kernels', body: {'name': name})).body,
            )
            as Map<String, dynamic>;
    return j['id'] as String;
  }

  @override
  Future<void> interrupt(String kernelId) =>
      _req('POST', 'api/kernels/$kernelId/interrupt');

  @override
  Future<void> restart(String kernelId) =>
      _req('POST', 'api/kernels/$kernelId/restart');

  @override
  Future<void> shutdown(String kernelId) =>
      _req('DELETE', 'api/kernels/$kernelId');

  @override
  Future<void> uploadFile(String path, Uint8List bytes) async {
    final parts = path.split('/');
    for (var i = 1; i < parts.length; i++) {
      final dir = parts.sublist(0, i).join('/');
      try {
        await _req('GET', 'api/contents/${_encPath(dir)}?content=0');
      } on NotFoundFailure {
        await _req(
          'PUT',
          'api/contents/${_encPath(dir)}',
          body: {'type': 'directory'},
        );
      }
    }
    await _req(
      'PUT',
      'api/contents/${_encPath(path)}',
      body: {
        'type': 'file',
        'format': 'base64',
        'content': base64Encode(bytes),
      },
    );
  }

  @override
  Future<Uint8List> downloadFile(String path) async {
    final j =
        jsonDecode(
              (await _req(
                'GET',
                'api/contents/${_encPath(path)}?type=file&format=base64',
              )).body,
            )
            as Map;
    final content = '${j['content'] ?? ''}';
    return j['format'] == 'base64'
        ? base64Decode(content.replaceAll('\n', ''))
        : Uint8List.fromList(utf8.encode(content));
  }

  /// Builds an `execute_request` (messaging protocol 5.3).
  Map<String, dynamic> executeRequest(String msgId, String code) => {
    'header': {
      'msg_id': msgId,
      'username': 'gitscholar',
      'session': _session,
      'msg_type': 'execute_request',
      'version': '5.3',
      'date': DateTime.now().toUtc().toIso8601String(),
    },
    'parent_header': <String, dynamic>{},
    'metadata': <String, dynamic>{},
    'content': {
      'code': code,
      'silent': false,
      'store_history': true,
      'user_expressions': <String, dynamic>{},
      'allow_stdin': false,
      'stop_on_error': true,
    },
    'channel': 'shell',
    'buffers': <Object>[],
  };

  @override
  Stream<ExecOutput> execute(String kernelId, String code) async* {
    final wsScheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    final uri = _api(
      'api/kernels/$kernelId/channels',
    ).replace(scheme: wsScheme, queryParameters: {'session_id': _session});
    final channel = _connect(uri, _headers);
    final msgId = const Uuid().v4();
    try {
      await channel.ready;
    } on Object catch (e) {
      throw NetworkFailure('Cannot connect to kernel: $e', cause: e);
    }
    channel.sink.add(jsonEncode(executeRequest(msgId, code)));
    try {
      await for (final raw in channel.stream) {
        if (raw is! String) continue;
        final msg = jsonDecode(raw) as Map<String, dynamic>;
        final parent = (msg['parent_header'] as Map?)?['msg_id'];
        if (parent != msgId) continue;
        final type = (msg['header'] as Map?)?['msg_type'] ?? msg['msg_type'];
        final content = Map<String, dynamic>.from(
          (msg['content'] as Map?) ?? const {},
        );
        final out = parseIopub('$type', content);
        if (out != null) yield out;
        if (type == 'status' && content['execution_state'] == 'idle') break;
      }
    } finally {
      await channel.sink.close();
    }
  }

  /// Converts an iopub message to [ExecOutput].
  static ExecOutput? parseIopub(String type, Map<String, dynamic> content) {
    switch (type) {
      case 'stream':
        return ExecStream(
          '${content['name'] ?? 'stdout'}',
          '${content['text'] ?? ''}',
        );
      case 'display_data':
      case 'execute_result':
        return ExecDisplay(
          Map<String, dynamic>.from((content['data'] as Map?) ?? const {}),
          metadata: Map<String, dynamic>.from(
            (content['metadata'] as Map?) ?? const {},
          ),
          isResult: type == 'execute_result',
          executionCount: content['execution_count'] as int?,
        );
      case 'error':
        return ExecError(
          '${content['ename'] ?? ''}',
          '${content['evalue'] ?? ''}',
          [for (final l in (content['traceback'] as List?) ?? const []) '$l'],
        );
      case 'execute_input':
        final n = content['execution_count'];
        return n is int ? ExecInput(n) : null;
      default:
        return null;
    }
  }
}
