# 02. アーキテクチャ

## 1. 全体像

```text
┌────────────────────────────────────────────────────────────────┐
│ Flutter App (lib/)                                             │
│                                                                │
│  Presentation  ─ 画面・ウィジェット・ViewModel (Riverpod)        │
│       │                                                        │
│  Application   ─ ユースケース（Repository同期、Commit、Agent実行） │
│       │                                                        │
│  Domain        ─ エンティティ・値オブジェクト・リポジトリIF        │
│       │                                                        │
│  Infrastructure─ GitHub API / ローカルDB / ファイルキャッシュ /   │
│                  Claude API / Jupyter / SecureStorage          │
└──────┬────────────────┬──────────────────┬─────────────────────┘
       │                │                  │
 packages/github_api  packages/nbformat  packages/scholar_agent
 packages/text_diff   (純Dart、Flutter非依存)
```

- 依存方向は **上から下のみ**。Presentation は Application と Domain に依存し、Infrastructure を直接参照しない。
- Domain は他のどの層にも依存しない（Dart標準ライブラリと `freezed` のみ）。
- Infrastructure は Domain のインターフェースを実装する。
- `packages/*` はFlutterに依存しない純Dartパッケージ。Infrastructure から利用する。

## 2. 技術スタック

| 領域 | 採用 | 備考 |
|---|---|---|
| フレームワーク | Flutter stable（プロジェクト初期化時の最新 3.x）、Dart 3.x | `.fvmrc` でバージョンを固定する（T-001） |
| 状態管理 / DI | `flutter_riverpod` 3.x | `Notifier` / `AsyncNotifier` を手書き（コード生成なし、ADR-0009） |
| ルーティング | `go_router` | 宣言的、ディープリンク対応 |
| 不変モデル | 手書きの不変クラス | `copyWith` と `fromJson` を必要な分だけ実装（ADR-0009） |
| HTTP | `http` | 再試行は Gateway / Client 内で実装（ADR-0009） |
| ローカルDB | `drift`（SQLite） | メタデータ、保留中の変更、会話履歴 |
| ファイルキャッシュ | `path_provider` + 自前の `BlobStore` | 内容アドレス（SHA）でファイルを保存 |
| 秘密情報 | `flutter_secure_storage` | GitHubトークン、Anthropicキー、Jupyterトークン |
| PDF | `pdfrx` | pdfium ベース、iOS/Android両対応、テキスト検索・選択 |
| Markdown | `markdown`（パーサ）+ `markdown_widget`（描画） | 数式は `flutter_math_fork` |
| コードエディタ / ハイライト | `re_editor` + `re_highlight` | 大きなファイルでも軽い |
| Notebook | `packages/nbformat`（自前） | パーサ・シリアライザ |
| diff | `packages/text_diff`（自前、Myers差分） | 行単位diff・unified形式出力 |
| GitHub API | `packages/github_api`（自前、`http` ベース） | Device Flow、REST、Git Data API |
| AI | `packages/scholar_agent`（自前、Raw HTTPでMessages API） | Dart用公式SDKが無いため |
| WebView | `webview_flutter` | Notebook HTML出力のサンドボックス表示 |
| ロギング | `logger` | 秘密情報を出力しないサニタイズを必ず通す |
| i18n | `flutter_localizations` + `intl`（ARB） | ja / en |
| テスト | `flutter_test`, `test`, `mocktail`, `integration_test` | |

## 3. 層の責務

### 3.1 Domain（`lib/domain/`）

- エンティティと値オブジェクト（`Repository`, `Workspace`, `TreeEntry`, `FileContent`, `PendingChange`, `Conversation` など。詳細は 03）。
- リポジトリインターフェース（抽象クラス）。例: `GitHubRepository`, `WorkspaceRepository`, `BlobStore`, `AgentGateway`, `ExecutionBackend`。
- ドメインロジック（ファイル種別判定、パスの正規化、`.gitscholarignore` の評価）。

### 3.2 Application（`lib/application/`）

ユースケース単位のクラス。1クラス1公開メソッド `call()` を原則とする。

| ユースケース | 概要 |
|---|---|
| `SignInWithGitHub` | Device Flow を開始し、ポーリングし、トークンを保存 |
| `OpenWorkspace` | リポジトリを選択し、ブランチ先頭SHAとツリーを取得（キャッシュ優先） |
| `RefreshWorkspace` | 先頭SHAを再取得し、ツリー差分を反映 |
| `LoadFile` | パスのファイル内容を返す（保留中の変更 > BlobStore > GitHub） |
| `SavePendingChange` | エディタの内容を保留中の変更として保存 |
| `DiscardPendingChange` | 保留中の変更を破棄 |
| `CommitChanges` | 選択した変更を1コミットにしてpush（06 参照） |
| `RunAgentTurn` | ユーザー発話を受け、エージェントループを回し、イベントをストリームで返す |
| `ApplyProposal` / `RejectProposal` | AI提案の承認・却下 |
| `ExecuteCells` | Notebookセルを実行バックエンドで実行し出力を反映（Phase 3） |

### 3.3 Infrastructure（`lib/infrastructure/`）

- `github/`: `packages/github_api` を使った `GitHubRepository` 実装、トークン管理。
- `local/`: drift データベース定義、`BlobStore` 実装、`SecureStore` 実装。
- `ai/`: `packages/scholar_agent` を使った `AgentGateway` 実装、ツール実装（`read_file` 等のアプリ側関数）。
- `execution/`: Jupyter Server クライアント（Phase 3）。

### 3.4 Presentation（`lib/presentation/`）

feature-first でディレクトリを切る。各 feature は `screens/`, `widgets/`, `providers/`（ViewModel）を持つ。

## 4. 状態管理の規約

- 画面状態は `Notifier` / `AsyncNotifier` で持つ。`StatefulWidget` の `setState` はウィジェット内部の一時的UI状態（展開/折りたたみ等）に限る。
- 非同期データは `AsyncValue` で扱い、`loading / error / data` を必ずUIで分岐する。
- サービスは Provider 経由で注入する（`ref.read(commitServiceProvider)`）。テストでは `ProviderContainer(overrides: [...])` で差し替える。
- グローバル状態（現在のワークスペース、認証状態、設定）は `lib/presentation/core/providers/` に置く。

主要 Provider:

| Provider | 型 | 内容 |
|---|---|---|
| `authStateProvider` | `AsyncNotifier<AuthState>` | 未認証 / 認証済み(user) / Device Flow進行中(code, url) |
| `currentWorkspaceProvider` | `AsyncNotifier<Workspace?>` | 開いているリポジトリ・ブランチ・ベースコミット・ツリー |
| `openFileProvider` | `Notifier<OpenFile?>` | 現在ビューアで開いているファイル（パス、種別、選択範囲） |
| `pendingChangesProvider` | `AsyncNotifier<List<PendingChange>>` | 保留中の変更 |
| `agentSessionProvider` | `Notifier<AgentSession>` | 会話、ストリーミング中のメッセージ、承認待ち提案 |
| `settingsProvider` | `AsyncNotifier<Settings>` | モデル、effort、テーマ、言語、Jupyter設定 |

## 5. ディレクトリ構成

```text
GitScholar/
├── CLAUDE.md
├── docs/
├── pubspec.yaml
├── analysis_options.yaml
├── .fvmrc
├── l10n.yaml
├── lib/
│   ├── main.dart                      # アプリ起動、ProviderScope
│   ├── app.dart                       # MaterialApp.router、テーマ、l10n
│   ├── router.dart                    # go_router 定義
│   ├── domain/
│   │   ├── entities/                  # 手書きエンティティ（freezed は不採用。ADR-0009）
│   │   ├── repositories/              # 抽象インターフェース
│   │   └── services/                  # 純ロジック（FileKindDetector, IgnoreRules）
│   ├── application/
│   │   ├── auth/
│   │   ├── workspace/
│   │   ├── editing/
│   │   ├── agent/
│   │   ├── threads/                   # Discussion / Issues
│   │   ├── offline/                   # オフライン保存
│   │   └── execution/
│   ├── infrastructure/
│   │   ├── github/
│   │   ├── local/
│   │   │   ├── database/              # drift テーブル・DAO
│   │   │   ├── blob_store.dart
│   │   │   └── secure_store.dart
│   │   ├── ai/
│   │   │   ├── agent_gateway_impl.dart
│   │   │   └── tools/                 # read_file 等の実装
│   │   └── execution/
│   ├── presentation/
│   │   ├── core/                      # 共通ウィジェット、テーマ、providers
│   │   ├── auth/
│   │   ├── repositories/              # リポジトリ一覧
│   │   ├── workspace/                 # 3ペインシェル、ファイルツリー
│   │   ├── viewers/
│   │   │   ├── pdf/
│   │   │   ├── markdown/
│   │   │   ├── notebook/
│   │   │   ├── code/
│   │   │   └── image/
│   │   ├── editing/                   # 変更一覧、diff、commitダイアログ
│   │   ├── agent/                     # AIパネル、提案カード
│   │   ├── threads/                   # Discussion / Issues、コメント、リアクション
│   │   ├── offline/                   # オフライン保存シート
│   │   └── settings/
│   └── l10n/                          # app_ja.arb, app_en.arb
├── assets/
│   └── icon/                           # アイコン原本（SVG）と 1024px PNG。PNG一式は各プラットフォームの所定の場所に書き出す
├── packages/
│   ├── nbformat/                      # .ipynb パーサ・シリアライザ
│   ├── text_diff/                     # Myers diff
│   ├── github_api/                    # GitHub REST / Device Flow クライアント
│   └── scholar_agent/                 # Claude Messages API クライアント + エージェントループ
├── test/                              # lib/ に対応するテスト（同じ階層構造）
├── integration_test/                   # 未導入（10 §1）
└── .github/workflows/ci.yml
```

各 `packages/<name>/` は `pubspec.yaml`, `lib/<name>.dart`, `lib/src/`, `test/`, `README.md` を持つ。アプリからは `path: packages/<name>` で依存する。

## 6. 依存パッケージ一覧（これ以外を追加するときはADRを書く）

正本はリポジトリ直下の `pubspec.yaml`。採用理由とバージョンの経緯は ADR-0009。

| 用途 | パッケージ |
|---|---|
| 状態管理・ルーティング | `flutter_riverpod`, `go_router` |
| HTTP・WebSocket | `http`, `web_socket_channel` |
| ローカル保存 | `drift`, `drift_flutter`, `path_provider`, `path`, `flutter_secure_storage` |
| ビューア | `pdfrx`, `markdown`, `markdown_widget`, `flutter_math_fork`, `re_editor`, `re_highlight`, `webview_flutter` |
| その他 | `url_launcher`, `logger`, `crypto`, `collection`, `uuid`, `intl`, `flutter_localizations` |
| 自前パッケージ | `nbformat`, `text_diff`, `github_api`, `scholar_agent`（`path:` 依存） |
| 開発 | `build_runner`, `drift_dev`, `mocktail`, `flutter_lints`, `integration_test` |

`packages/*` の依存は `http`, `crypto` のみ（dev: `test`, `lints`）。Flutter に依存してはならない。

## 7. エラー処理方針

- Domain に `AppFailure`（sealed class）を定義する。

```dart
sealed class AppFailure {
  const AppFailure(this.message, {this.cause});
  final String message; final Object? cause;
}
class NetworkFailure extends AppFailure { ... }          // 接続不可、タイムアウト
class AuthFailure extends AppFailure { ... }             // 401、トークン失効
class RateLimitFailure extends AppFailure { final DateTime resetAt; ... }
class NotFoundFailure extends AppFailure { ... }
class ConflictFailure extends AppFailure { final List<String> conflictingPaths; ... }
class ValidationFailure extends AppFailure { ... }       // 不正な入力、パースエラー
class AiFailure extends AppFailure { final String? stopReason; ... }
class UnknownFailure extends AppFailure { ... }
```

- Infrastructure は例外を `AppFailure` に変換して投げる。生の `DioException` や `HttpException` を上位に漏らさない。
- Application は `Result<T>` ではなく例外（`AppFailure`）をそのまま伝播する。Presentation は `AsyncValue.error` で受け、`FailureView` ウィジェットで表示する。
- `RateLimitFailure` は `resetAt` までの残り時間を表示し、自動再試行はしない。
- ネットワーク系（`NetworkFailure`, 5xx）は `dio` の再試行インターセプタで最大3回、指数バックオフ（1s, 2s, 4s）で再試行する。GET のみ。

## 8. ロギング

- `logger` を `AppLogger` でラップし、`Authorization` ヘッダ、`token`, `api_key`, `access_token` を含む文字列は `***` にマスクしてから出力する。
- リリースビルドでは `Level.warning` 以上のみ出力する。
- AIとのやりとりの本文はデバッグビルドでも既定ではログに出さない（設定で有効化）。

## 9. 並行性とキャンセル

- 長い処理（ツリー取得、ファイル取得、AI応答、実行）は `CancelToken` / `StreamSubscription` でキャンセル可能にする。ユーザーがファイルを切り替えたら前のファイル取得はキャンセルする。
- 重い純処理（`.ipynb` パース、diff計算、Markdownパース）は `compute()` / `Isolate.run()` で別Isolateで行う。閾値: 入力 200KB 以上。
