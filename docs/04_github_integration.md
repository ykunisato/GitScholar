# 04. GitHub連携

対象: `packages/github_api`（純Dart）と `lib/infrastructure/github/`。

## 1. 認証: OAuth Device Flow

GitHub の OAuth App を作成し、Device Flow を有効化する（Settings → Developer settings → OAuth Apps → "Enable Device Flow"）。アプリには **Client ID のみ** を埋め込む（`lib/config.dart`、`--dart-define=GITHUB_CLIENT_ID=...` で上書き可）。クライアントシークレットは使わない。

スコープ: `repo read:user`（privateリポジトリの読み書きに `repo` が必要）。

### 1.1 手順

```text
1. POST https://github.com/login/device/code
   Headers: Accept: application/json
   Body (form): client_id=<id>&scope=repo%20read:user
   → { device_code, user_code, verification_uri, expires_in, interval }

2. UIに user_code と verification_uri を表示し、「ブラウザで開く」ボタン（url_launcher）を出す。
   user_code はワンタップでコピーできるようにする。

3. interval 秒ごとに
   POST https://github.com/login/oauth/access_token
   Headers: Accept: application/json
   Body (form): client_id=<id>&device_code=<device_code>&grant_type=urn:ietf:params:oauth:grant-type:device_code
   → 成功: { access_token, token_type, scope }
   → error = "authorization_pending": 継続
   → error = "slow_down": interval += 5 して継続
   → error = "expired_token": AuthFailure("期限切れ。もう一度お試しください")
   → error = "access_denied": AuthFailure("ユーザーが拒否")

4. access_token を SecureStore に保存（key: "github_access_token"）。
5. GET https://api.github.com/user で GitHubUser を取得し、AuthState.signedIn にする。
```

### 1.2 パッケージAPI

```dart
class GitHubDeviceFlow {
  GitHubDeviceFlow({required String clientId, http.Client? client});
  Future<DeviceCodeResponse> requestCode({List<String> scopes = const ['repo', 'read:user']});
  /// interval に従いポーリングし、トークンを返す。cancel で中断可能。
  Future<String> pollForToken(DeviceCodeResponse code, {Future<void>? cancel});
}
```

- 401 が返った場合（トークン失効・取り消し）は `AuthFailure` を投げ、Presentation は認証画面へ遷移する。トークンは削除する。

### 1.3 ブラウザ往復をまたぐサインインの継続（実機で判明した要件）

Device Flow はユーザーがブラウザで認可する間、アプリが背面に回る。Android 実機（Pixel 7a / Android 17）での確認から、次の2点を満たす必要がある。

1. **待ち受けをメモリに保持する。** 端末のセキュアストレージは、アプリが背面にある間に内容が空になることがある（保存直後の読み戻しは成功していた）。保存から読めないことを理由に、進行中のサインインを打ち切ってはならない。復帰時はメモリ上の device_code を優先して使い、保存はアプリが終了した場合の予備とする。
2. **復帰時にただちに1回問い合わせる。** `interval` の待機を挟まず `pollOnce` を呼ぶ。ユーザーが戻った直後に完了する。

3. **バックグラウンドで進む処理は、書き戻す前にプロバイダの生存を確認する。** 復帰やポーリングは画面より長く動くため、`await` のたびに `ref.mounted` を確認してから `state` を更新する。破棄後に書き込むと `Cannot use the Ref ... after it has been disposed` で落ちる。

セキュアストレージは `AndroidOptions(resetOnError: false)` で使う。既定値は復号に失敗した際に保存内容を全消去するため、サインイン状態が黙って失われる。読み書きの例外は握りつぶし、保存できない端末でもセッション内のサインインは成立させる。

## 2. REST API クライアント

```dart
class GitHubClient {
  GitHubClient({required String token, http.Client? client, String baseUrl = 'https://api.github.com'});
  // 共通ヘッダ: Authorization: Bearer <token>, Accept: application/vnd.github+json, X-GitHub-Api-Version: 2022-11-28
}
```

### 2.1 使用するエンドポイント

| 用途 | メソッド / パス | 備考 |
|---|---|---|
| ユーザー | `GET /user` | |
| リポジトリ一覧 | `GET /user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member` | `Link` ヘッダで次ページ。全ページ取得（上限 1000件） |
| Issues一覧 | `GET /repos/{o}/{r}/issues?state=open&sort=updated&per_page=30` | プルリクエストも返るため `pull_request` を持つ要素を除外する |
| Issue詳細・コメント | `GET /repos/{o}/{r}/issues/{n}`, `GET .../comments` | |
| コメント投稿 | `POST /repos/{o}/{r}/issues/{n}/comments` | body は Markdown |
| Discussion | `POST /graphql` | DiscussionにRESTは無くGraphQLのみ（ADR-0012）。`repository.hasDiscussionsEnabled` が false なら未設定として扱う。投稿は `addDiscussionComment`（`discussionId` はノードID） |
| リアクション | `POST /graphql` | Issues・Discussion とも `addReaction` / `removeReaction`（`subjectId` はノードID、`content` は `ReactionContent`）。表示は `reactionGroups { content viewerHasReacted reactors(first:1){ totalCount } }`。RESTは削除に reaction id が要るためGraphQLに統一（ADR-0012） |
| リポジトリ詳細 | `GET /repos/{owner}/{repo}` | `default_branch` |
| ブランチ一覧 | `GET /repos/{owner}/{repo}/branches?per_page=100` | Phase 2 |
| ブランチ先頭 | `GET /repos/{owner}/{repo}/git/ref/heads/{branch}` | `object.sha` = コミットSHA |
| コミット | `GET /repos/{owner}/{repo}/git/commits/{sha}` | `tree.sha` |
| ツリー | `GET /repos/{owner}/{repo}/git/trees/{tree_sha}?recursive=1` | `truncated` が true なら Workspace.truncated。上限 100,000 エントリ / 7MB |
| blob（生） | `GET /repos/{owner}/{repo}/git/blobs/{sha}` with `Accept: application/vnd.github.raw+json` | 100MB まで。バイナリもそのまま返る |
| blob作成 | `POST /repos/{owner}/{repo}/git/blobs` `{content: base64, encoding: "base64"}` | → `sha` |
| ツリー作成 | `POST /repos/{owner}/{repo}/git/trees` `{base_tree, tree: [{path, mode, type, sha}]}` | 削除は `sha: null` |
| コミット作成 | `POST /repos/{owner}/{repo}/git/commits` `{message, tree, parents: [sha]}` | |
| ref更新 | `PATCH /repos/{owner}/{repo}/git/refs/heads/{branch}` `{sha, force: false}` | fast-forward でなければ 422 |
| ref作成 | `POST /repos/{owner}/{repo}/git/refs` `{ref: "refs/heads/x", sha}` | ブランチ作成（Phase 2 SHOULD） |
| 単一ファイル更新 | `PUT /repos/{owner}/{repo}/contents/{path}` `{message, content: base64, sha?, branch}` | 1ファイルのみのcommit時に使う近道。レスポンスの `content.sha`, `commit.sha` を使う |
| レート制限 | `GET /rate_limit` | 設定画面の診断用 |

### 2.2 条件付きリクエスト

- ツリー・ref・リポジトリ一覧は `ETag` を保存し、`If-None-Match` を付けて送る。`304` はレート制限に数えられない。
- `ETag` は drift の `key_value` テーブル（key: `etag:<url>`）に保存する。

### 2.3 レート制限とエラー

| レスポンス | 変換 |
|---|---|
| 401 | `AuthFailure`（トークン削除→再ログイン） |
| 403 / 429 かつ `x-ratelimit-remaining: 0` または `retry-after` | `RateLimitFailure(resetAt)`。`x-ratelimit-reset`（epoch秒）または `retry-after` から算出 |
| 404 | `NotFoundFailure` |
| 409 / 422（ref更新） | `ConflictFailure` |
| 5xx / ソケットエラー | `NetworkFailure`（GETは再試行） |

- 残り回数は `x-ratelimit-remaining` を毎レスポンスで読み、`rateLimitStatusProvider` に反映する。100 未満でツールバーに警告を出す。

## 3. ワークスペースの取得と更新

### 3.1 `OpenWorkspace(repo, branch?)`

```text
1. branch ?? repo.defaultBranch
2. drift の workspaces に (repo, branch) があればそれを返し、UIを先に描く（キャッシュ優先）
3. 裏で RefreshWorkspace を実行
```

### 3.2 `RefreshWorkspace`

```text
1. GET git/ref/heads/{branch} → headSha
2. headSha == workspace.baseCommitSha なら何もしない（"最新です" を短く表示）
3. GET git/commits/{headSha} → treeSha
4. GET git/trees/{treeSha}?recursive=1
5. トランザクションで tree_entries を全置換、workspaces を更新
6. 保留中の変更がある場合: 各 PendingChange の path について新ツリーの blob sha を baseBlobSha と比較。
   異なれば PendingChange に "upstream_changed" フラグ（UIで警告表示）。commit時に 06 §4 の競合処理に入る。
7. currentWorkspaceProvider を更新。開いているファイルのSHAが変わっていれば、ビューアに「更新があります（再読込）」バナーを出す（自動では差し替えない）
```

### 3.3 `LoadFile(path)`

```text
1. pending_changes に status=pending の該当pathがあれば、その content_blob_sha を BlobStore から読む
2. tree_entries から sha を引き、BlobStore.read(sha) があれば返す（last_access_at 更新）
3. GET git/blobs/{sha}（raw）→ BlobStore.write → 返す
   size > 100MB なら NotFoundFailure ではなく ValidationFailure("too large")
```

## 4. commit / push

詳細な手順・競合処理は [06_editing_diff_commit.md](06_editing_diff_commit.md) §3–4。ここではAPI呼び出しの組み合わせを規定する。

**単一ファイル・modify/create**: Contents API `PUT` を1回。`sha` には `baseBlobSha`（createはnull）。422（sha不一致）は `ConflictFailure`。

**それ以外（複数ファイル、delete、rename）**: Git Data API。

```text
1. 各変更について POST git/blobs（delete以外）→ blobSha（ローカル計算のSHAと一致することをassert）
2. POST git/trees {base_tree: <親コミットのtreeSha>, tree: [
     {path, mode: "100644", type: "blob", sha: blobSha},      // modify/create/renameの新パス
     {path, mode: "100644", type: "blob", sha: null},         // delete / renameの旧パス
   ]}
3. POST git/commits {message, tree: newTreeSha, parents: [parentSha]}
4. PATCH git/refs/heads/{branch} {sha: newCommitSha}
   → 422 なら ConflictFailure（親が古い）。06 §4 へ
```

コミットの author/committer はトークンのユーザーになる（GitHubが設定）。アプリ側で `author` を指定しない。

## 5. `packages/github_api` 公開API

```dart
class GitHubClient {
  Future<UserDto> getUser();
  Future<List<RepoDto>> listUserRepos({void Function(int fetched)? onProgress});
  Future<RepoDto> getRepo(String owner, String name);
  Future<List<BranchDto>> listBranches(String owner, String name);
  Future<String> getBranchHeadSha(String owner, String name, String branch, {String? etag});
  Future<CommitDto> getCommit(String owner, String name, String sha);
  Future<TreeDto> getTree(String owner, String name, String treeSha, {bool recursive = true});
  Future<Uint8List> getBlobRaw(String owner, String name, String sha);
  Future<String> createBlob(String owner, String name, Uint8List bytes);
  Future<String> createTree(String owner, String name, {required String baseTree, required List<TreeItem> items});
  Future<String> createCommit(String owner, String name, {required String message, required String tree, required List<String> parents});
  Future<void> updateRef(String owner, String name, String branch, String sha, {bool force = false});
  Future<void> createRef(String owner, String name, String branch, String sha);
  Future<ContentsPutResult> putContents(String owner, String name, String path, {required String message, required Uint8List content, String? sha, required String branch});
  Future<RateLimitDto> getRateLimit();
}

String gitBlobSha(Uint8List bytes);   // sha1("blob <len>\0" + bytes) の16進
```

すべてのメソッドは `GitHubApiException(statusCode, message, headers)` を投げる。アプリ側 `infrastructure/github/failure_mapper.dart` で `AppFailure` に変換する。

## 6. テスト

- `packages/github_api/test/` で `http.MockClient` を使い、各エンドポイントのリクエスト形（URL、ヘッダ、ボディ）とレスポンスのパースを検証する。
- Device Flow: `authorization_pending` → `slow_down` → 成功の順で返すモックで、interval が増えることを検証。
- `gitBlobSha`: 既知のGit blob SHAと一致すること（例: 空文字列 → `e69de29bb2d1d6434b8b29ae775ad8c2e48c5391`、`"hello\n"` → `ce013625030ba8dba906f756967f9e9ca394464a`）。
- レート制限ヘッダの変換、ETag/304 の扱い。
