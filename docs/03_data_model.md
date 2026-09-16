# 03. データモデル

## 1. ドメインエンティティ（`lib/domain/entities/`）

すべて `freezed` で不変クラスとして定義する。JSON変換が必要なものは `json_serializable` を併用する。

### 1.1 認証・ユーザー

```dart
@freezed class GitHubUser { String login; int id; String avatarUrl; String? name; }

@freezed sealed class AuthState {
  const factory AuthState.signedOut() = SignedOut;
  const factory AuthState.pendingDeviceCode({
    required String userCode, required Uri verificationUri, required DateTime expiresAt}) = PendingDeviceCode;
  const factory AuthState.signedIn(GitHubUser user) = SignedIn;
}
```

### 1.2 リポジトリ・ワークスペース

```dart
@freezed class RepositoryRef { String owner; String name; String fullName; bool isPrivate;
  String defaultBranch; String? description; DateTime updatedAt;
  DateTime? pinnedAt;            // FR-16
  List<String>? offlinePaths;    // FR-27: null=無効、[]=全体、それ以外は対象プレフィックス
  String? offlineCommitSha; DateTime? offlineUpdatedAt; }

@freezed class Workspace {
  RepositoryRef repo;
  String branch;
  String baseCommitSha;      // ツリー取得時点のブランチ先頭
  String treeSha;
  List<TreeEntry> entries;   // 平坦なリスト。UIで階層化する
  bool truncated;            // GitHubの上限で切り詰められたか
  DateTime fetchedAt;
  AiAccessPolicy aiAccess;   // allowed / denied / ask
}

@freezed class TreeEntry { String path; TreeEntryType type /*blob|tree*/; String sha; int? size; String mode; }

enum FileKind { pdf, markdown, notebook, code, image, text, binary, unknown }
```

`FileKind` は拡張子で判定する（`domain/services/file_kind_detector.dart`）:

| FileKind | 拡張子 |
|---|---|
| pdf | `.pdf` |
| markdown | `.md`, `.markdown`, `.qmd`, `.Rmd`（qmd/Rmdは表示はMarkdown、編集はコードエディタ） |
| notebook | `.ipynb` |
| code | `.py`, `.r`, `.R`, `.jl`, `.stan`, `.sh`, `.js`, `.ts`, `.dart`, `.c`, `.cpp`, `.java`, `.sql`, `.yaml`, `.yml`, `.json`, `.toml`, `.bib`, `.tex`, `.csv`, `.tsv` |
| image | `.png`, `.jpg`, `.jpeg`, `.gif`, `.svg`, `.webp`, `.bmp` |
| text | `.txt`, `.log`, `.cfg`, `.ini`, `.env.example`, 拡張子なしでUTF-8として読めるもの |
| binary | それ以外でUTF-8デコードに失敗するもの |

### 1.3 ファイル内容

```dart
@freezed class FileContent {
  String path;
  String blobSha;            // GitHub上のblob SHA（保留中の変更の場合は元のSHA。新規ファイルは null）
  Uint8List bytes;
  FileKind kind;
  ContentSource source;      // remote | cache | pending
}

@freezed class OpenFile { String path; FileKind kind; TextSelection? selection; int? pdfPage; int? notebookCellIndex; }
```

### 1.4 保留中の変更

```dart
enum ChangeKind { modify, create, delete, rename }
enum ChangeOrigin { user, ai }
enum ChangeStatus { pending, proposed /* AI提案・未承認 */, rejected }

@freezed class PendingChange {
  String id;                 // UUID
  String repoFullName;
  String branch;
  String path;
  String? oldPath;           // rename時
  ChangeKind kind;
  ChangeOrigin origin;
  ChangeStatus status;
  String? baseBlobSha;       // 変更の元になったblob（新規はnull）
  String baseCommitSha;      // 変更時のワークスペースのベースコミット
  Uint8List? newBytes;       // delete時はnull
  String? proposalId;        // AI提案の場合、Proposal への参照
  DateTime createdAt; DateTime updatedAt;
}
```

`LoadFile` の解決順序: `status == pending` の PendingChange → BlobStore（SHA一致）→ GitHub。`proposed` は通常のビューアには反映しない（提案カードのdiffでのみ表示）。

### 1.5 AI

```dart
@freezed class Conversation { String id; String repoFullName; String title; DateTime createdAt; DateTime updatedAt; }

@freezed class ChatMessage {
  String id; String conversationId; MessageRole role /* user | assistant */;
  List<ContentBlock> blocks;     // text / tool_use / tool_result / thinking_summary
  DateTime createdAt;
  Usage? usage;                  // input/output/cache tokens
}

@freezed class AttachedContext { String path; FileKind kind; String? selectionText; int? page; int? cellIndex; }

@freezed class Proposal {
  String id; String conversationId; String messageId;
  String path; ChangeKind kind; String? newContentText; String explanation;
  ProposalStatus status;         // pending | approved | rejected
  String pendingChangeId;        // 承認時に status を pending に変える PendingChange
}

@freezed class CommitRequest { String id; String conversationId; String message; List<String> paths; CommitRequestStatus status; }
```

### 1.6 設定

```dart
@freezed class Settings {
  String aiProvider;             // "anthropic" | "openai" | "openrouter" | "custom"（ADR-0010）
  String? aiBaseUrl;             // OpenAI互換の接続先。未設定なら提供元の既定
  String aiModel;                // 既定 "claude-opus-5"
  String aiEffort;               // "low"|"medium"|"high"|"xhigh"|"max"、既定 "high"
  bool aiShowThinkingSummary;    // 既定 true
  ThemeMode themeMode; String? locale;
  JupyterSettings? jupyter;      // baseUrl, （トークンはSecureStoreに）
  int cacheLimitMb;              // 既定 2048
}
```

### 1.7 スレッド（Discussion / Issues）

```dart
enum ThreadKind { discussion, issue }

class RepoThread {
  ThreadKind kind; int number; String title; String author;
  DateTime updatedAt; int commentCount; String url;
  String? category;              // Discussion のカテゴリ
  bool isOpen;                   // Issues のみ
}

class ThreadComment { String id; String nodeId; String author; String body; DateTime createdAt; List<Reaction> reactions; }
class ThreadDetail { RepoThread thread; String body; List<ThreadComment> comments; String? nodeId; List<Reaction> reactions; }

enum ReactionKind { thumbsUp, thumbsDown, laugh, hooray, confused, heart, rocket, eyes }
class Reaction { ReactionKind kind; int count; bool mine; }
```

スレッドはDBに保存せず、開くたびにGitHubから取得する。`nodeId` はGraphQLのノードIDで、Discussionへのコメントと、Issues / Discussion 双方のリアクションに使う（ADR-0012）。`ReactionKind` はGraphQLの `ReactionContent`（`THUMBS_UP` 等）とRESTの `content`（`+1` 等）の両方の名前を持つ。

### 1.8 PDF注釈とメモ

```dart
enum HighlightColor { yellow, green, blue, pink }
class HighlightRect { double left, top, right, bottom; }  // PDFページ座標。原点は左下、yは上向きなので top > bottom
class PdfHighlight { String id; int page; List<HighlightRect> rects; HighlightColor color; String text; DateTime createdAt; }
class PdfAnnotations { List<PdfHighlight> highlights; }
```

ハイライトは `<pdf名>.annotations.json`（ADR-0008）、メモは `<pdf名>.md`（ADR-0011）に保存する。どちらも通常のリポジトリファイルなので、保存は `PendingChange` になり、コミットは他の編集と同じ操作で行う。DBには持たない。

## 2. ローカルDB（drift）

DBファイル: `<app support dir>/gitscholar.sqlite`。スキーマバージョンは `schemaVersion` で管理し（現在 2）、変更時は必ずマイグレーションを書く（`test/infrastructure/local/migration_test.dart`）。

```sql
-- 開いたことのあるリポジトリ
CREATE TABLE repositories (
  full_name TEXT PRIMARY KEY, owner TEXT NOT NULL, name TEXT NOT NULL,
  is_private INTEGER NOT NULL, default_branch TEXT NOT NULL, description TEXT,
  ai_access TEXT NOT NULL DEFAULT 'ask',          -- allowed | denied | ask
  last_opened_at INTEGER, updated_at INTEGER NOT NULL,
  -- schema v2 (FR-16, FR-27)
  pinned_at INTEGER,                              -- NULL = ピン留めなし
  offline_paths_json TEXT,                        -- NULL = オフライン無効、[] = リポジトリ全体
  offline_commit_sha TEXT, offline_updated_at INTEGER
);

-- ワークスペース（repo × branch）
CREATE TABLE workspaces (
  repo_full_name TEXT NOT NULL, branch TEXT NOT NULL,
  base_commit_sha TEXT NOT NULL, tree_sha TEXT NOT NULL, truncated INTEGER NOT NULL,
  fetched_at INTEGER NOT NULL,
  PRIMARY KEY (repo_full_name, branch)
);

-- ツリーエントリ（ワークスペースごとに全置換）
CREATE TABLE tree_entries (
  repo_full_name TEXT NOT NULL, branch TEXT NOT NULL,
  path TEXT NOT NULL, type TEXT NOT NULL, sha TEXT NOT NULL, size INTEGER, mode TEXT NOT NULL,
  PRIMARY KEY (repo_full_name, branch, path)
);
CREATE INDEX idx_tree_entries_sha ON tree_entries(sha);

-- BlobStore のメタデータ（実体はファイル）
CREATE TABLE blobs (
  sha TEXT PRIMARY KEY, size INTEGER NOT NULL, cached_at INTEGER NOT NULL, last_access_at INTEGER NOT NULL
);

CREATE TABLE pending_changes (
  id TEXT PRIMARY KEY, repo_full_name TEXT NOT NULL, branch TEXT NOT NULL,
  path TEXT NOT NULL, old_path TEXT, kind TEXT NOT NULL, origin TEXT NOT NULL, status TEXT NOT NULL,
  base_blob_sha TEXT, base_commit_sha TEXT NOT NULL,
  content_blob_sha TEXT,                          -- newBytes は BlobStore に保存し、そのSHAを持つ
  proposal_id TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX idx_pending_repo ON pending_changes(repo_full_name, branch, status);

CREATE TABLE conversations (
  id TEXT PRIMARY KEY, repo_full_name TEXT NOT NULL, title TEXT NOT NULL,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE TABLE messages (
  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role TEXT NOT NULL, blocks_json TEXT NOT NULL, usage_json TEXT, created_at INTEGER NOT NULL
);
CREATE TABLE proposals (
  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, message_id TEXT NOT NULL,
  path TEXT NOT NULL, kind TEXT NOT NULL, explanation TEXT NOT NULL, status TEXT NOT NULL,
  pending_change_id TEXT NOT NULL REFERENCES pending_changes(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL
);
CREATE TABLE commit_requests (
  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, message TEXT NOT NULL,
  paths_json TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL
);

-- Phase 4 で追加予定: paper_metadata, search_index
-- PDF注釈はDBではなくリポジトリ内のサイドカーファイルに置く（ADR-0008）
```

設定（`Settings`）は `shared_preferences` ではなく drift の `key_value` テーブル（`key TEXT PRIMARY KEY, value_json TEXT`）に保存する。パッケージを増やさないため。

`key_value` には設定のほか、次を保存する。

| キー | 内容 |
|---|---|
| `last_workspace` | 最後に開いたリポジトリとブランチ（起動時に復元） |
| `pane_widths` | タブレットのペイン幅 |
| `thread_kind` | スレッドの表示種別 `discussion` / `issue`（FR-97） |
| `pdfpage:<blobSha>` | PDFごとの最後に開いたページ |
| `etag:<url>` | 条件付きリクエスト用のETagと応答本文（04 §2.2） |

## 3. BlobStore（ファイルキャッシュ）

- 保存先: `<app support dir>/blobs/<sha[0..2]>/<sha>`。
- キーは **GitのblobSHA**（`sha1("blob " + size + "\0" + content)`）。GitHubから取得したものはAPIが返すSHAをそのまま使い、ローカルで生成した内容（保留中の変更）は同じ計算式でSHAを算出する（`packages/github_api` に `gitBlobSha(Uint8List)` を置く）。これにより、commit後にGitHubが返すSHAとローカルのSHAが一致し、再取得が不要になる。
- インターフェース:

```dart
abstract class BlobStore {
  Future<Uint8List?> read(String sha);
  Future<void> write(String sha, Uint8List bytes);
  Future<bool> exists(String sha);
  Future<void> delete(String sha);
  Future<int> totalSize();
  Future<void> evict({required int targetBytes});   // LRU（last_access_at 昇順）で削除。pending_changes が参照するSHAと、オフライン有効なリポジトリのblobは削除しない
}
```

- 上限は `Settings.cacheLimitMb`。書き込み後に超過していれば `evict` を非同期に実行する。
- 1ファイルの取得上限は 100MB（GitHub blob APIの上限）。超えるものは FR-35 に従う。

## 4. Notebook モデル（`packages/nbformat`）

nbformat 4.x に準拠する。

```dart
class Notebook { int nbformat; int nbformatMinor; Map<String, dynamic> metadata; List<Cell> cells; }

sealed class Cell { String? id; Map<String, dynamic> metadata; String source; }   // source は結合済み文字列で保持
class MarkdownCell extends Cell {}
class RawCell extends Cell {}
class CodeCell extends Cell { int? executionCount; List<Output> outputs; }

sealed class Output {}
class StreamOutput extends Output { String name /* stdout|stderr */; String text; }
class DisplayDataOutput extends Output { MimeBundle data; Map<String, dynamic> metadata; }
class ExecuteResultOutput extends Output { int? executionCount; MimeBundle data; Map<String, dynamic> metadata; }
class ErrorOutput extends Output { String ename; String evalue; List<String> traceback; }

class MimeBundle { Map<String, String> entries; /* mime → 結合済み文字列（画像はbase64） */ String? preferred(List<String> priority); }
```

- パース時、`source` と MIME値が `List<String>` の場合は結合する。シリアライズ時は元の形式（リスト/文字列）を `metadata` に記録せず、**常に行ごとのリスト**で出力する（Jupyterと同じ規約: 各要素は末尾に `\n` を含む、最終行を除く）。
- 未知のフィールドは `extra` として保持し、シリアライズ時に復元する（ラウンドトリップでデータを失わない）。
- `nbformat < 4` はサポートしない（`ValidationFailure`）。

## 5. GitHub API DTO（`packages/github_api`）

APIレスポンスは `json_serializable` のDTOクラスとしてパッケージ内に閉じ、アプリ側の Domain エンティティへは `infrastructure/github/mappers.dart` で変換する。DTOをPresentationで使わない。
