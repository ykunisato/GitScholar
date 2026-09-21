import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'dto.dart';
import 'exception.dart';
import 'lfs.dart';
import 'threads.dart';

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

  // ------------------------------------------------- issues / discussions

  /// `GET /repos/{owner}/{repo}/issues`, newest activity first.
  ///
  /// Pull requests are returned by the same endpoint and are filtered out.
  Future<List<IssueDto>> listIssues(
    String owner,
    String name, {
    int perPage = 30,
    bool openOnly = true,
  }) async {
    final res = await _send(
      'GET',
      '${_repoPath(owner, name)}/issues'
          '?per_page=$perPage&sort=updated&direction=desc'
          '&state=${openOnly ? 'open' : 'all'}',
    );
    return [
      for (final i in jsonDecode(res.body) as List)
        if (!IssueDto.isPullRequest(i as Map<String, dynamic>))
          IssueDto.fromJson(i),
    ];
  }

  /// `GET /repos/{owner}/{repo}/issues/{number}`.
  Future<IssueDto> getIssue(String owner, String name, int number) async =>
      IssueDto.fromJson(
        _obj(
          (await _send('GET', '${_repoPath(owner, name)}/issues/$number')).body,
        ),
      );

  /// `GET /repos/{owner}/{repo}/issues/{number}/comments`.
  Future<List<ThreadCommentDto>> listIssueComments(
    String owner,
    String name,
    int number, {
    int perPage = 100,
  }) async {
    final res = await _send(
      'GET',
      '${_repoPath(owner, name)}/issues/$number/comments?per_page=$perPage',
    );
    return [
      for (final c in jsonDecode(res.body) as List)
        ThreadCommentDto.fromIssueJson(c as Map<String, dynamic>),
    ];
  }

  /// `POST /repos/{owner}/{repo}/issues/{number}/comments`.
  Future<ThreadCommentDto> createIssueComment(
    String owner,
    String name,
    int number,
    String body,
  ) async {
    final res = await _send(
      'POST',
      '${_repoPath(owner, name)}/issues/$number/comments',
      body: {'body': body},
    );
    return ThreadCommentDto.fromIssueJson(_obj(res.body));
  }

  /// `POST /graphql`. Returns the `data` object.
  ///
  /// Discussions have no REST API, so they go through GraphQL (ADR-0012).
  /// GraphQL answers 200 even for query errors, so `errors` is checked here.
  Future<Map<String, dynamic>> graphql(
    String query, {
    Map<String, dynamic> variables = const {},
  }) async {
    final res = await _send(
      'POST',
      '/graphql',
      body: {'query': query, 'variables': variables},
    );
    final j = _obj(res.body);
    final errors = j['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      final message = first is Map && first['message'] is String
          ? first['message'] as String
          : 'GraphQL error';
      throw GitHubApiException(
        res.statusCode,
        message,
        errorCode: first is Map ? first['type'] as String? : null,
      );
    }
    final data = j['data'];
    if (data is! Map<String, dynamic>) {
      throw GitHubApiException(res.statusCode, 'Empty GraphQL response');
    }
    return data;
  }

  /// `reactors` takes pagination arguments, so a page size is always given
  /// even though only the total is read.
  static const _reactionFields =
      'reactionGroups{content viewerHasReacted reactors(first:1){totalCount}}';

  static const _discussionFields =
      'id number title url updatedAt author { login } '
      'category { name }';

  /// Lists discussions, newest activity first.
  ///
  /// Returns null when the repository has discussions turned off.
  Future<List<DiscussionDto>?> listDiscussions(
    String owner,
    String name, {
    int first = 30,
  }) async {
    final data = await graphql(
      'query(\$owner:String!,\$name:String!,\$first:Int!){'
      'repository(owner:\$owner,name:\$name){'
      'hasDiscussionsEnabled '
      'discussions(first:\$first,orderBy:{field:UPDATED_AT,direction:DESC})'
      '{nodes{$_discussionFields comments{totalCount}}}}}',
      variables: {'owner': owner, 'name': name, 'first': first},
    );
    final repo = data['repository'] as Map<String, dynamic>?;
    if (repo == null) {
      throw const GitHubApiException(404, 'Repository not found');
    }
    if (repo['hasDiscussionsEnabled'] == false) return null;
    final nodes =
        (repo['discussions'] as Map<String, dynamic>?)?['nodes'] as List?;
    return [
      for (final d in nodes ?? const <Object?>[])
        DiscussionDto.fromGraphQl(d as Map<String, dynamic>),
    ];
  }

  /// Reads one discussion with its comments.
  Future<DiscussionDto> getDiscussion(
    String owner,
    String name,
    int number, {
    int firstComments = 100,
  }) async {
    final data = await graphql(
      'query(\$owner:String!,\$name:String!,\$number:Int!,\$first:Int!){'
      'repository(owner:\$owner,name:\$name){'
      'discussion(number:\$number){$_discussionFields body '
      '$_reactionFields '
      'comments(first:\$first){totalCount nodes{id body createdAt '
      'author{login} $_reactionFields}}}}}',
      variables: {
        'owner': owner,
        'name': name,
        'number': number,
        'first': firstComments,
      },
    );
    final d =
        (data['repository'] as Map<String, dynamic>?)?['discussion']
            as Map<String, dynamic>?;
    if (d == null) throw const GitHubApiException(404, 'Discussion not found');
    return DiscussionDto.fromGraphQl(d);
  }

  /// Adds a comment to a discussion. [discussionId] is the GraphQL node id.
  Future<ThreadCommentDto> createDiscussionComment(
    String discussionId,
    String body,
  ) async {
    final data = await graphql(
      'mutation(\$id:ID!,\$body:String!){'
      'addDiscussionComment(input:{discussionId:\$id,body:\$body})'
      '{comment{id body createdAt author{login}}}}',
      variables: {'id': discussionId, 'body': body},
    );
    final c =
        (data['addDiscussionComment'] as Map<String, dynamic>?)?['comment']
            as Map<String, dynamic>?;
    if (c == null) {
      throw const GitHubApiException(422, 'Comment was not created');
    }
    return ThreadCommentDto.fromGraphQl(c);
  }

  /// Reads the reactions of any reactable nodes (issues, discussions and
  /// their comments), keyed by node id.
  Future<Map<String, List<ReactionGroupDto>>> reactionsFor(
    List<String> nodeIds,
  ) async {
    final ids = [
      for (final id in nodeIds)
        if (id.isNotEmpty) id,
    ];
    if (ids.isEmpty) return const {};
    final data = await graphql(
      'query(\$ids:[ID!]!){nodes(ids:\$ids){id ... on Reactable{'
      '$_reactionFields}}}',
      variables: {'ids': ids},
    );
    final out = <String, List<ReactionGroupDto>>{};
    for (final n in (data['nodes'] ?? const <Object?>[]) as List) {
      if (n is! Map<String, dynamic>) continue;
      out['${n['id']}'] = ReactionGroupDto.listFrom(n['reactionGroups']);
    }
    return out;
  }

  /// Adds or removes the signed-in user's reaction and returns the subject's
  /// reactions afterwards. [content] is a `ReactionContent` value.
  Future<List<ReactionGroupDto>> react(
    String subjectId,
    String content, {
    required bool add,
  }) async {
    final name = add ? 'addReaction' : 'removeReaction';
    final data = await graphql(
      'mutation(\$id:ID!,\$content:ReactionContent!){'
      '$name(input:{subjectId:\$id,content:\$content})'
      '{reactionGroups{content viewerHasReacted '
      'reactors(first:1){totalCount}}}}',
      variables: {'id': subjectId, 'content': content},
    );
    final payload = data[name] as Map<String, dynamic>?;
    return ReactionGroupDto.listFrom(payload?['reactionGroups']);
  }

  // ----------------------------------------------------------- Git LFS

  /// Base of the Git LFS endpoints. LFS lives on github.com, not on the API
  /// host.
  final String lfsBaseUrl = 'https://github.com';

  /// Downloads the real content behind an LFS [pointer].
  ///
  /// Files stored with Git LFS come back from the Git Data API as a small
  /// pointer file; the bytes have to be fetched separately (docs/04 §2.4).
  /// The content is checked against the pointer's size and sha256 so a stale
  /// or truncated response is not cached as if it were the document.
  Future<Uint8List> downloadLfsObject(
    String owner,
    String name,
    LfsPointer pointer,
  ) async {
    final batch = await _lfsBatch(owner, name, pointer);
    final objects = batch['objects'];
    if (objects is! List || objects.isEmpty) {
      throw const GitHubApiException(0, 'LFS batch returned no object');
    }
    final object = objects.first as Map<String, dynamic>;
    final error = object['error'];
    if (error is Map) {
      throw GitHubApiException(
        (error['code'] as num?)?.toInt() ?? 0,
        '${error['message'] ?? 'LFS object unavailable'}',
      );
    }
    final download =
        (object['actions'] as Map<String, dynamic>?)?['download']
            as Map<String, dynamic>?;
    final href = download?['href'];
    if (href is! String || href.isEmpty) {
      throw const GitHubApiException(0, 'LFS object has no download link');
    }
    final headerMap = download?['header'];
    final headers = <String, String>{
      if (headerMap is Map)
        for (final e in headerMap.entries) '${e.key}': '${e.value}',
    };
    final http.Response res;
    try {
      res = await _http.get(Uri.parse(href), headers: headers);
    } on http.ClientException catch (e) {
      throw GitHubApiException(0, e.message);
    }
    if (res.statusCode >= 400) {
      throw GitHubApiException(res.statusCode, 'LFS download failed');
    }
    final bytes = res.bodyBytes;
    if (bytes.length != pointer.size) {
      throw GitHubApiException(
        0,
        'LFS size mismatch: got ${bytes.length}, expected ${pointer.size}',
      );
    }
    if (pointer.hashAlgo == 'sha256' &&
        '${sha256.convert(bytes)}' != pointer.oid) {
      throw const GitHubApiException(0, 'LFS content does not match its oid');
    }
    return bytes;
  }

  /// Asks the LFS server where the object lives.
  ///
  /// GitHub accepts the token as HTTP Basic credentials; some setups want a
  /// bearer token instead, so both are tried before giving up.
  Future<Map<String, dynamic>> _lfsBatch(
    String owner,
    String name,
    LfsPointer pointer,
  ) async {
    final uri = Uri.parse(
      '$lfsBaseUrl/${_enc(owner)}/${_enc(name)}.git/info/lfs/objects/batch',
    );
    final body = jsonEncode({
      'operation': 'download',
      'transfers': ['basic'],
      // ポインタの `sha256:` は付けない。付けるとサーバは
      // 「Object does not exist on the server」を返す。
      'objects': [
        {'oid': pointer.oid, 'size': pointer.size},
      ],
      if (pointer.hashAlgo != 'sha256') 'hash_algo': pointer.hashAlgo,
    });
    final basic = base64Encode(utf8.encode('x-access-token:$token'));
    for (final authorization in ['Basic $basic', 'Bearer $token']) {
      final http.Response res;
      try {
        res = await _http.post(
          uri,
          headers: {
            'Accept': 'application/vnd.git-lfs+json',
            'Content-Type': 'application/vnd.git-lfs+json',
            'Authorization': authorization,
          },
          body: body,
        );
      } on http.ClientException catch (e) {
        throw GitHubApiException(0, e.message);
      }
      if (res.statusCode == 401 && authorization.startsWith('Basic')) {
        continue; // Bearer で再試行する
      }
      if (res.statusCode >= 400) {
        throw GitHubApiException(res.statusCode, 'LFS batch failed');
      }
      return _obj(res.body);
    }
    throw const GitHubApiException(401, 'LFS authentication failed');
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
