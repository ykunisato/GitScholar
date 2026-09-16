import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'dto.dart';
import 'exception.dart';

/// Stores ETags and cached bodies for conditional requests.
abstract class ETagCache {
  /// Returns the cached entry for [url].
  Future<ETagEntry?> get(String url);

  /// Stores an entry for [url].
  Future<void> put(String url, ETagEntry entry);
}

/// An ETag and its response body.
class ETagEntry {
  /// Creates an entry.
  const ETagEntry(this.etag, this.body);

  /// ETag header value.
  final String etag;

  /// Response body.
  final String body;
}

/// In-memory [ETagCache].
class MemoryETagCache implements ETagCache {
  final _map = <String, ETagEntry>{};

  @override
  Future<ETagEntry?> get(String url) async => _map[url];

  @override
  Future<void> put(String url, ETagEntry entry) async => _map[url] = entry;
}

/// GitHub REST client. See docs/04_github_integration.md §2.
class GitHubClient {
  /// Creates a client.
  GitHubClient({
    required this.token,
    http.Client? client,
    this.baseUrl = 'https://api.github.com',
    ETagCache? etagCache,
    this.onRateLimit,
  }) : _http = client ?? http.Client(),
       _etags = etagCache ?? MemoryETagCache();

  /// Access token.
  final String token;

  /// API base URL.
  final String baseUrl;

  /// Called with `x-ratelimit-remaining` after every response.
  final void Function(int remaining, DateTime? resetAt)? onRateLimit;

  final http.Client _http;
  final ETagCache _etags;

  /// Maximum repositories fetched by [listUserRepos].
  static const maxRepos = 1000;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  String _enc(String s) => Uri.encodeComponent(s);

  String _repoPath(String owner, String name) =>
      '/repos/${_enc(owner)}/${_enc(name)}';

  /// Encodes a slash-separated path segment by segment.
  String _encPath(String path) => path.split('/').map(_enc).join('/');

  Future<http.Response> _send(
    String method,
    String pathOrUrl, {
    Object? body,
    Map<String, String>? extraHeaders,
  }) async {
    final uri = Uri.parse(
      pathOrUrl.startsWith('http') ? pathOrUrl : '$baseUrl$pathOrUrl',
    );
    final req = http.Request(method, uri)
      ..headers.addAll(_headers)
      ..headers.addAll(extraHeaders ?? const {});
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req));
    } on SocketException catch (e) {
      throw GitHubApiException(0, e.message);
    } on http.ClientException catch (e) {
      throw GitHubApiException(0, e.message);
    } on TimeoutException {
      throw const GitHubApiException(0, 'timeout');
    }
    final remaining = int.tryParse(res.headers['x-ratelimit-remaining'] ?? '');
    if (remaining != null) {
      final reset = int.tryParse(res.headers['x-ratelimit-reset'] ?? '');
      onRateLimit?.call(
        remaining,
        reset == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true),
      );
    }
    if (res.statusCode >= 400) {
      var message = res.reasonPhrase ?? 'HTTP ${res.statusCode}';
      try {
        final j = jsonDecode(res.body);
        if (j is Map && j['message'] is String) {
          message = j['message'] as String;
        }
      } on FormatException {
        // Non-JSON error body.
      }
      throw GitHubApiException(res.statusCode, message, headers: res.headers);
    }
    return res;
  }

  /// GET with ETag support. Returns the body (cached on 304).
  Future<String> _getCached(String path) async {
    final url = '$baseUrl$path';
    final cached = await _etags.get(url);
    final res = await _send(
      'GET',
      path,
      extraHeaders: {if (cached != null) 'If-None-Match': cached.etag},
    );
    if (res.statusCode == 304 && cached != null) return cached.body;
    final etag = res.headers['etag'];
    if (etag != null) await _etags.put(url, ETagEntry(etag, res.body));
    return res.body;
  }

  Map<String, dynamic> _obj(String body) =>
      jsonDecode(body) as Map<String, dynamic>;

  /// `GET /user`.
  Future<UserDto> getUser() async =>
      UserDto.fromJson(_obj((await _send('GET', '/user')).body));

  /// `GET /user/repos`, following `Link` pagination up to [maxRepos].
  Future<List<RepoDto>> listUserRepos({
    void Function(int fetched)? onProgress,
  }) async {
    final out = <RepoDto>[];
    String? next =
        '$baseUrl/user/repos?per_page=100&sort=updated'
        '&affiliation=owner,collaborator,organization_member';
    while (next != null && out.length < maxRepos) {
      final res = await _send('GET', next);
      for (final r in jsonDecode(res.body) as List) {
        out.add(RepoDto.fromJson(r as Map<String, dynamic>));
      }
      onProgress?.call(out.length);
      next = parseNextLink(res.headers['link']);
    }
    return out.length > maxRepos ? out.sublist(0, maxRepos) : out;
  }

  /// Extracts the `rel="next"` URL from a `Link` header.
  static String? parseNextLink(String? link) {
    if (link == null) return null;
    for (final part in link.split(',')) {
      final m = RegExp(r'<([^>]+)>;\s*rel="next"').firstMatch(part.trim());
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// `GET /repos/{owner}/{repo}`.
  Future<RepoDto> getRepo(String owner, String name) async =>
      RepoDto.fromJson(_obj((await _send('GET', _repoPath(owner, name))).body));

  /// `GET /repos/{owner}/{repo}/branches`.
  Future<List<BranchDto>> listBranches(String owner, String name) async {
    final out = <BranchDto>[];
    String? next = '$baseUrl${_repoPath(owner, name)}/branches?per_page=100';
    while (next != null) {
      final res = await _send('GET', next);
      for (final b in jsonDecode(res.body) as List) {
        out.add(BranchDto.fromJson(b as Map<String, dynamic>));
      }
      next = parseNextLink(res.headers['link']);
    }
    return out;
  }

  /// `GET /repos/{owner}/{repo}/git/ref/heads/{branch}` returning commit SHA.
  Future<String> getBranchHeadSha(
    String owner,
    String name,
    String branch,
  ) async {
    final body = await _getCached(
      '${_repoPath(owner, name)}/git/ref/heads/${_encPath(branch)}',
    );
    return (_obj(body)['object'] as Map<String, dynamic>)['sha'] as String;
  }

  /// `GET /repos/{owner}/{repo}/git/commits/{sha}`.
  Future<CommitDto> getCommit(String owner, String name, String sha) async =>
      CommitDto.fromJson(
        _obj(await _getCached('${_repoPath(owner, name)}/git/commits/$sha')),
      );

  /// `GET /repos/{owner}/{repo}/git/trees/{sha}?recursive=1`.
  Future<TreeDto> getTree(
    String owner,
    String name,
    String treeSha, {
    bool recursive = true,
  }) async => TreeDto.fromJson(
    _obj(
      await _getCached(
        '${_repoPath(owner, name)}/git/trees/$treeSha'
        '${recursive ? '?recursive=1' : ''}',
      ),
    ),
  );

  /// `GET /repos/{owner}/{repo}/git/blobs/{sha}` (raw bytes).
  Future<Uint8List> getBlobRaw(String owner, String name, String sha) async {
    final res = await _send(
      'GET',
      '${_repoPath(owner, name)}/git/blobs/$sha',
      extraHeaders: {'Accept': 'application/vnd.github.raw+json'},
    );
    return res.bodyBytes;
  }

  /// `POST /repos/{owner}/{repo}/git/blobs` returning the blob SHA.
  Future<String> createBlob(String owner, String name, Uint8List bytes) async {
    final res = await _send(
      'POST',
      '${_repoPath(owner, name)}/git/blobs',
      body: {'content': base64Encode(bytes), 'encoding': 'base64'},
    );
    return _obj(res.body)['sha'] as String;
  }

  /// `POST /repos/{owner}/{repo}/git/trees` returning the tree SHA.
  Future<String> createTree(
    String owner,
    String name, {
    required String baseTree,
    required List<TreeItem> items,
  }) async {
    final res = await _send(
      'POST',
      '${_repoPath(owner, name)}/git/trees',
      body: {
        'base_tree': baseTree,
        'tree': [for (final i in items) i.toJson()],
      },
    );
    return _obj(res.body)['sha'] as String;
  }

  /// `POST /repos/{owner}/{repo}/git/commits` returning the commit SHA.
  Future<String> createCommit(
    String owner,
    String name, {
    required String message,
    required String tree,
    required List<String> parents,
  }) async {
    final res = await _send(
      'POST',
      '${_repoPath(owner, name)}/git/commits',
      body: {'message': message, 'tree': tree, 'parents': parents},
    );
    return _obj(res.body)['sha'] as String;
  }

  /// `PATCH /repos/{owner}/{repo}/git/refs/heads/{branch}`.
  ///
  /// Always fast-forward only; GitScholar never force-updates
  /// (docs/06_editing_diff_commit.md §4).
  Future<void> updateRef(
    String owner,
    String name,
    String branch,
    String sha,
  ) async {
    await _send(
      'PATCH',
      '${_repoPath(owner, name)}/git/refs/heads/${_encPath(branch)}',
      body: {'sha': sha, 'force': false},
    );
  }

  /// `POST /repos/{owner}/{repo}/git/refs`.
  Future<void> createRef(
    String owner,
    String name,
    String branch,
    String sha,
  ) async {
    await _send(
      'POST',
      '${_repoPath(owner, name)}/git/refs',
      body: {'ref': 'refs/heads/$branch', 'sha': sha},
    );
  }

  /// `PUT /repos/{owner}/{repo}/contents/{path}`.
  Future<ContentsPutResult> putContents(
    String owner,
    String name,
    String path, {
    required String message,
    required Uint8List content,
    required String branch,
    String? sha,
  }) async {
    final res = await _send(
      'PUT',
      '${_repoPath(owner, name)}/contents/${_encPath(path)}',
      body: {
        'message': message,
        'content': base64Encode(content),
        'branch': branch,
        'sha': ?sha,
      },
    );
    final j = _obj(res.body);
    final commit = j['commit'] as Map<String, dynamic>;
    return ContentsPutResult(
      contentSha: (j['content'] as Map<String, dynamic>)['sha'] as String,
      commitSha: commit['sha'] as String,
      treeSha: (commit['tree'] as Map<String, dynamic>)['sha'] as String,
    );
  }

  /// `GET /rate_limit`.
  Future<RateLimitDto> getRateLimit() async {
    final resources =
        _obj((await _send('GET', '/rate_limit')).body)['resources']
            as Map<String, dynamic>;
    final core = resources['core'] as Map<String, dynamic>;
    return RateLimitDto(
      limit: core['limit'] as int,
      remaining: core['remaining'] as int,
      resetAt: DateTime.fromMillisecondsSinceEpoch(
        (core['reset'] as int) * 1000,
        isUtc: true,
      ),
    );
  }

  /// Closes the underlying HTTP client.
  void close() => _http.close();
}
