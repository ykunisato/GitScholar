# 11. 実装計画（チケット一覧）

作業はチケット単位で行う。各チケットは「目的 / 依存 / 主な成果物 / 手順 / 受け入れ基準」を持つ。受け入れ基準はテストで確認できる形で書いてある。**チケットの順序は依存関係を満たす限り入れ替えてよい**が、同じフェーズ内で並列に進めるときは依存を確認すること。

工数の目安: S = 半日以内、M = 1〜2日、L = 3日以上（AIエージェントが実装する場合の目安。人間のレビュー時間は含まない）。

## 実装状況（2026-09-15 時点）

| 範囲 | 状態 | 主な実装場所 | 備考 |
|---|---|---|---|
| T-001〜T-005 基盤 | 実装済み | `pubspec.yaml`, `lib/domain`, `lib/infrastructure/local`, `lib/infrastructure/logging` | freezed/riverpod_generator は不採用（ADR-0009） |
| T-010, T-011 github_api | 実装済み | `packages/github_api` | 単体テスト 21件 |
| T-012〜T-016 サインイン〜Markdown | 実装済み | `lib/presentation/{auth,repositories,workspace,viewers}` | |
| T-017, T-018 Notebook | 実装済み | `packages/nbformat`, `lib/presentation/viewers/notebook` | |
| T-019 PDF | 実装済み | `lib/presentation/viewers/pdf`, `lib/infrastructure/ai/pdf_text.dart` | 実機でのみ検証可能（pdfium） |
| T-020, T-021 scholar_agent | 実装済み | `packages/scholar_agent` | 自動キャッシュ・コンテキスト編集を追加（ADR-0009） |
| T-022〜T-025 設定・AIパネル・i18n | 実装済み | `lib/presentation/{settings,agent}`, `lib/l10n` | `docs/manual_test_checklist.md` と実機計測は未実施 |
| T-030〜T-043 編集・diff・commit・AI提案 | 実装済み | `packages/text_diff`, `lib/application/editing`, `lib/presentation/editing`, `lib/infrastructure/ai/research_tools.dart` | 3ペイン比較の競合レビュー画面は簡易版（リモート基準で再編集） |
| T-050〜T-055 実行環境 | 実装済み | `lib/infrastructure/execution`, `lib/application/execution` | 実 Jupyter Server との結合テストは未実施 |
| FR-16 ピン留め | 実装済み | `lib/presentation/repositories`, `app_database`（schema v2） | 最大10件 |
| FR-27〜FR-30b オフライン保存 | 実装済み | `lib/application/offline`, `lib/presentation/offline` | 一括ダウンロード、差分更新、削除 |
| Phase 4〜5 | 未着手 | | |

---

## Phase 0: プロジェクト基盤

### T-001 プロジェクト初期化（M）
- **依存**: なし
- **成果物**: `pubspec.yaml`（02 §6 の依存。Phase 3 用の `web_socket_channel` は当面コメントアウト）、`.fvmrc`、`analysis_options.yaml`（10 §4）、`l10n.yaml`、`lib/main.dart`, `lib/app.dart`, `lib/router.dart`（`/signin` と `/repos` のプレースホルダ画面）、02 §5 のディレクトリ（`.gitkeep`）、`packages/{nbformat,text_diff,github_api,scholar_agent}` の空パッケージ（`pubspec.yaml`, `lib/<name>.dart`, `test/smoke_test.dart`）、`.github/workflows/ci.yml`（10 §3）、`README.md`（ビルド手順）。
- **手順**: `flutter create --org jp.gitscholar --platforms ios,android .` 相当で生成し、不要なテンプレートを削除。iOS `Info.plist` に `NSFileProtection`、Android に `allowBackup=false`（09 §1）。
- **受け入れ基準**: `flutter analyze` 警告ゼロ。`flutter test` と各 `dart test` が通る。CIが緑。iOS/Android のデバッグビルドが成功する。

### T-002 ドメインモデル（M）
- **依存**: T-001
- **成果物**: 03 §1 の freezed エンティティ、`AppFailure`（02 §7）、`FileKindDetector`（03 §1.2）、`normalizePath`（`..`、絶対パス、`//` の拒否・正規化）、`IgnoreRules`（07 §5.2 の gitignore 構文サブセット）。
- **受け入れ基準**: `FileKindDetector` の全拡張子表のテスト。`normalizePath` が `../x`, `/x`, `a//b`, `a/./b` を正しく扱う。`IgnoreRules` が `*.pem`, `**/secrets/**`, `notes/`, `!notes/keep.md` を gitignore と同じ意味で判定する（各ケースのテスト）。

### T-003 ローカルDB（M）
- **依存**: T-002
- **成果物**: 03 §2 の drift テーブル、DAO（`RepositoryDao`, `WorkspaceDao`, `PendingChangeDao`, `ConversationDao`, `KeyValueDao`）、`schemaVersion = 1`。
- **受け入れ基準**: インメモリDBで各DAOのCRUDテスト。`tree_entries` の全置換がトランザクションで行われること。`pending_changes` の同一 path upsert。マイグレーションテストの雛形（`schemaVersion` を上げたときに壊れない）。

### T-004 BlobStore / SecureStore（S）
- **依存**: T-003
- **成果物**: 03 §3 の `BlobStore` 実装（`FileBlobStore`）、`SecureStore`（`flutter_secure_storage` ラッパ、テスト用 `InMemorySecureStore`）。
- **受け入れ基準**: 書込→読出→存在確認→削除。`evict` が LRU で削除し、`pending_changes` が参照する sha を残す。合計サイズが正しい。

### T-005 ロガー・HTTP基盤・設定（S）
- **依存**: T-003
- **成果物**: `AppLogger`（02 §8 マスク処理）、`Settings` の読み書き（`SettingsRepository` → `key_value`）、`settingsProvider`、`lib/config.dart`（`GITHUB_CLIENT_ID` の `dart-define`）。
- **受け入れ基準**: `AppLogger` が `Authorization: Bearer abc` や `"api_key":"x"` を `***` にマスクする。`Settings` の既定値（モデル `claude-opus-5`、effort `high`）とラウンドトリップ。

---

## Phase 1: 閲覧中心のMVP

### T-010 github_api: RESTクライアント（M）
- **依存**: T-001
- **成果物**: 04 §5 の `GitHubClient`（Device Flow を除く）、DTO、`GitHubApiException`、`gitBlobSha`、ページネーション、ETag 対応、レート制限ヘッダの読み取り。
- **受け入れ基準**: 04 §6 のテスト（各エンドポイントのURL/ヘッダ/ボディ、`gitBlobSha` の既知値、304 の扱い、`Link` ヘッダで全ページ取得）。カバレッジ 80% 以上。

### T-011 github_api: Device Flow（S）
- **依存**: T-010
- **成果物**: `GitHubDeviceFlow`（04 §1.2）。
- **受け入れ基準**: `authorization_pending` → `slow_down`（interval +5）→ 成功のモックで通る。`expired_token`, `access_denied` が例外になる。`cancel` で中断できる。

### T-012 サインイン（M）
- **依存**: T-004, T-005, T-011
- **成果物**: `SignInWithGitHub` / `SignOut` ユースケース、`authStateProvider`、`SignInScreen`（08 §3.1）、ルーターの認証ガード、`infrastructure/github/failure_mapper.dart`、`GitHubRepository` インターフェース実装（`GitHubClient` をトークン付きで生成する Provider）。
- **受け入れ基準**: ウィジェットテストでコード表示→成功→`/repos` へ遷移。トークンが `SecureStore` に保存され、再起動（Providerの再生成）後に `signedIn` になる。401 でトークン削除→`/signin`。

### T-013 リポジトリ一覧（S）
- **依存**: T-012
- **成果物**: `ListRepositories` ユースケース（drift にキャッシュ）、`RepositoryListScreen`（08 §3.2）。
- **受け入れ基準**: 1000件のフェイクデータで検索・並び替えが動く。オフライン時はキャッシュ済み一覧を表示する。

### T-014 ワークスペースとファイルツリー（L）
- **依存**: T-013
- **成果物**: `OpenWorkspace`, `RefreshWorkspace`（04 §3.1–3.2）、`currentWorkspaceProvider`、`WorkspaceShell`（08 §2 レスポンシブ、3ペイン/ボトムナビ）、`FilesPane`（08 §3.3、フィルタ、展開状態保存、truncated バナー）、FR-14 の直近ワークスペース復元。
- **受け入れ基準**: フェイクGitHubで tree 取得→表示。2回目はキャッシュから即描画し、裏で refresh。head 不変なら API 呼び出しが ref 取得1回だけ。10,000 エントリの合成ツリーで `ListView.builder` の可視行のみビルドされる（ウィジェットテストで `find.byType(TreeRow)` の数が画面分のみ）。幅 500dp でボトムナビ、900dp で3ペイン。

### T-015 ファイル読込と基本ビューア（M）
- **依存**: T-014
- **成果物**: `LoadFile`（04 §3.3、キャンセル対応）、`openFileProvider`、`ViewerDispatcher`、`CodeViewer`（05 §4、読み取り専用）、`ImageViewer`、`UnsupportedFileView`（サイズ上限、ブラウザで開く）、`ViewerPane` のタブ（08 §3.4）、`selectionProvider`。
- **受け入れ基準**: `.py`/`.R`/`.yaml` がハイライト表示される。5MB 超のテキストは `UnsupportedFileView`。ファイル切替時に前の取得がキャンセルされる（フェイクで遅延を入れて検証）。BlobStore にキャッシュされ2回目はネットワークを呼ばない。

### T-016 Markdownビューア（M）
- **依存**: T-015
- **成果物**: `MarkdownViewer`（05 §2）: GFM、コードハイライト、数式、相対リンク→ファイルを開く、相対画像→LoadFile、フロントマター折りたたみ、目次。
- **受け入れ基準**: フィクスチャ `gfm.md` のゴールデンテスト。`[x](../papers/a.pdf)` タップで `openFileProvider` が `papers/a.pdf` になる。`$E=mc^2$` が数式ウィジェットになる。不正な数式でクラッシュしない。

### T-017 nbformat パッケージ（M）
- **依存**: T-001
- **成果物**: 05 §6 / 03 §4 のパーサ・シリアライザ、`MimeBundle.preferred`。
- **受け入れ基準**: 05 §6 のフィクスチャすべてでラウンドトリップ等価。`nbformat: 3` は例外。`source` が文字列でもリストでも同じ結果。未知フィールドが保持される。カバレッジ 90% 以上。

### T-018 Notebookビューア（L）
- **依存**: T-016, T-017
- **成果物**: `NotebookViewer`（05 §3）: 遅延ビルド、各出力種別、ANSI除去、HTMLサンドボックスWebView（05 §3.2）、折りたたみメタデータ、200KB 超は Isolate でパース。
- **受け入れ基準**: 各フィクスチャのゴールデン（HTML出力は折りたたみ状態）。500セルのNotebookで可視セルのみビルド。WebView が `JavaScriptMode.disabled` で生成され、`NavigationDelegate` が外部遷移を拒否する（モック `WebViewPlatform` で検証）。`<script>` が除去される。

### T-019 PDFビューア（M）
- **依存**: T-015
- **成果物**: `PdfViewer`（05 §1）: 表示、ページ移動、検索、選択、目次、位置記憶、テキスト抽出 `PdfTextExtractor`（AI用）。
- **受け入れ基準**: 2ページのフィクスチャPDFで検索ヒット、ページ遷移、テキスト抽出の内容一致。位置記憶のラウンドトリップ。100MB 超は `UnsupportedFileView`（サイズだけで判定、実ファイル不要）。

### T-020 scholar_agent: Anthropic クライアントとSSE（M）
- **依存**: T-001
- **成果物**: `AnthropicClient.streamMessage`, `MessageRequest`（07 §2 のJSON化）, SSEパーサ, `StreamEvent` 型、HTTPエラー→例外（07 §2.3）。
- **受け入れ基準**: 07 §7 のテスト（SSE分割、`input_json_delta` 連結、`ping`、`error`）。モデル別に `fallbacks`/ベータヘッダ/`thinking` の有無が正しい。`cache_control` が system 末尾と最初のユーザーメッセージのコンテキストブロックに付く。

### T-021 scholar_agent: エージェントループ（M）
- **依存**: T-020
- **成果物**: `AgentLoop.runTurn`, `ToolDefinition`, `ToolHandler`, `PermissionGate`, `AgentEvent`（07 §5, §7）。
- **受け入れ基準**: 台本モックで `tool_use`→`tool_result`→`end_turn`。並列 `tool_use` が1つの user メッセージにまとめて返る。`is_error`。上限25回で停止イベント。`PermissionGate` 拒否で `is_error` の結果が返る。`max_tokens`/`refusal`/`pause_turn` の各 stop_reason がイベントに反映される。

### T-022 設定画面（S）
- **依存**: T-005, T-012
- **成果物**: `SettingsScreen`（08 §3.7 のアカウント・AI・表示セクション）、APIキーの `SecureStore` 保存、接続テスト（`max_tokens: 1` の最小リクエスト）。
- **受け入れ基準**: キー保存→マスク表示。モデル・effort の変更が `settingsProvider` に反映。接続テストの成功/401 が表示される。

### T-023 AIパネル（単一ファイル質問）（L）
- **依存**: T-016, T-018, T-019, T-021, T-022
- **成果物**: `AgentGateway` 実装（ツールは空）、`ContextBuilder`（07 §3: markdown/code/ipynb/pdf の整形、200KB 上限、選択範囲）、`RunAgentTurn`（保存なし・メモリ上の会話）、`AgentPane`（08 §3.5: ストリーミング、停止、思考要約の折りたたみ、文脈表示、パスのリンク化、usage表示）、`AiAccessPolicy` の確認ダイアログ、`.gitscholarignore` の適用、`ai_access == denied` の無効化。
- **受け入れ基準**: 統合テスト UC-1 相当（フェイクAnthropicで固定応答）。送信JSONにファイル本文と選択範囲が含まれる。ignore対象ファイルを開いて質問すると本文が送信されない。private リポジトリで初回にダイアログが出る。ストリーミング中の停止で受信分が残る。

### T-024 キャッシュ管理とログアウト（S）
- **依存**: T-015, T-022
- **成果物**: 設定のキャッシュセクション（使用量、上限、リポジトリ別削除、全削除）、`SignOut` の完全実装（09 §1）。
- **受け入れ基準**: 上限超過で `evict` が動く。ログアウトでトークン・会話・private のblobが消える。

### T-025 i18n・テーマ・仕上げ（M）
- **依存**: Phase 1 の他すべて
- **成果物**: すべてのUI文字列を ARB 化（ja/en）、ダークテーマ、`AppColors`、`FailureView` の統一、`docs/manual_test_checklist.md`、NFR-10/12 の実機計測結果を `docs/perf_log.md` に記録。
- **受け入れ基準**: ハードコードされた日本語/英語UI文字列が `lib/presentation` に無い（grep）。ライト/ダーク両方のゴールデン（主要3画面）。

---

## Phase 2: 編集とGitHubへの反映

### T-030 text_diff パッケージ（M）
- **依存**: T-001
- **成果物**: 06 §2 の API。
- **受け入れ基準**: 06 §2 のテスト（既知ケース、プロパティテスト、`DiffTooLarge`）。カバレッジ 90% 以上。

### T-031 保留中の変更の基盤（M）
- **依存**: T-004, T-015, T-030
- **成果物**: `PendingChangeRepository`、`SavePendingChange`（upsert、元に戻したら削除、`gitBlobSha` で content を BlobStore に保存）、`DiscardPendingChange`、`pendingChangesProvider`、`LoadFile` の pending 優先、FilesPane のマーク表示、`RefreshWorkspace` の `upstream_changed` 検出（04 §3.2 手順6）。
- **受け入れ基準**: 保存→再起動相当→`LoadFile` が pending 内容を返す。元に戻すと消える。upstream 変更でフラグが立つ。

### T-032 テキスト・Markdownエディタ（M）
- **依存**: T-031
- **成果物**: `CodeViewer` の編集モード、1秒デバウンス自動保存、`paused` 時保存、EOL・末尾改行の保持、Markdown の編集/プレビュー/分割モード、`Cmd/Ctrl+S`。
- **受け入れ基準**: 入力後1秒で `SavePendingChange` が1回だけ呼ばれる（連続入力でまとめられる）。`\r\n` ファイルを編集しても `\r\n` のまま保存される。分割モードでプレビューが追従する。

### T-033 Notebook編集（L）
- **依存**: T-018, T-031
- **成果物**: 06 §1.2 のセル編集・追加・削除・移動・種別変更・出力クリア、`serializeNotebook` による保存。
- **受け入れ基準**: セルソース編集後の保存で出力と metadata が変わらない（フィクスチャ比較）。追加・削除・移動が `Notebook.cells` に反映される。nbformat 4.5 で新規セルに `id` が付く。

### T-034 ファイル作成・削除・リネーム（S）
- **依存**: T-031
- **成果物**: 06 §1.3。FilesPane の長押しメニュー、パス入力ダイアログ（`normalizePath`、重複チェック）。
- **受け入れ基準**: create/delete/rename の各 PendingChange が作られ、ツリー表示（取り消し線、新規マーク）が正しい。

### T-035 変更一覧とdiff表示（M）
- **依存**: T-031, T-033
- **成果物**: `ChangesScreen`, `DiffScreen`（unified / side-by-side）、`notebook_diff.dart`（セル単位diff）、バイナリ表示、破棄。
- **受け入れ基準**: テキストdiffのゴールデン。Notebookの変更セルだけが列挙される。`DiffTooLarge` で全文フォールバック。

### T-036 commit / push（L）
- **依存**: T-010, T-035
- **成果物**: `CommitChanges`（06 §3.2、単一ファイルは Contents API、それ以外は Git Data API）、`CommitSheet`、成功後のローカル状態更新、オフライン時の扱い。
- **受け入れ基準**: フェイクGitHub（Git Data API の意味論あり）で、modify×2 + delete×1 + rename×1 が1コミットになり、ref が進み、`tree_entries` と `workspaces` が更新され、PendingChange が消える。ローカル `gitBlobSha` とサーバーが返す sha が一致する。単一 modify では `PUT contents` が使われる。ネットワーク失敗時に変更が残る。

### T-037 競合処理（M）
- **依存**: T-036
- **成果物**: 06 §4 の判定と `ConflictSheet`（3ペイン表示、上書き、破棄、非競合のみコミット）。
- **受け入れ基準**: リモートが進んでいるが別ファイル → 自動的に新 head を親にしてコミット成功。同一ファイルが変わっている → `ConflictFailure` → 「上書き」で成功。`force` が一度も呼ばれない（フェイクで検証）。

### T-038 AIツール: 読み取り系（M）
- **依存**: T-021, T-023, T-031
- **成果物**: `list_files`, `read_file`, `search_repo` のハンドラ（07 §4）、ignore 適用、AgentPane のツール呼び出し表示。
- **受け入れ基準**: `read_file` が pending 内容を返す。範囲指定。200KB 超のメッセージ。`search_repo` が未キャッシュの小さいテキストを取得して検索し、上限 200 ファイルで止まる。ignore 対象は「アクセス制限」と返る。パストラバーサルが拒否される。

### T-039 AIツール: 変更提案と承認（L）
- **依存**: T-038, T-035
- **成果物**: `propose_change`（edits の「ちょうど1回」検証、create/delete）、`Proposal` 保存、提案カード（承認/却下/開く/すべて承認）、却下の `system_note`、`origin: ai` の表示。
- **受け入れ基準**: 統合テスト UC-3 相当。`old_text` が0回/2回のとき `is_error` で理由が返る。承認前はビューアに反映されず、承認後に反映され変更一覧に載る。却下で `rejected` になり次ターンに通知が付く。

### T-040 AIツール: get_diff / request_commit / メッセージ提案（S）
- **依存**: T-039, T-036
- **成果物**: `get_diff`, `request_commit`（コミット依頼カード → CommitSheet を依頼内容で開く）、CommitSheet の「メッセージを提案」（diffを渡した1回のAPI呼び出し、ツールなし）。
- **受け入れ基準**: `request_commit` が commit を実行しない（フェイクGitHubの ref が動かない）。カードから CommitSheet が開き、対象パスとメッセージが埋まっている。

### T-041 会話の永続化（S）
- **依存**: T-023, T-003
- **成果物**: `conversations`/`messages` への保存、`ConversationListScreen`、新規会話、削除、`blocks_json` の復元と再送。
- **受け入れ基準**: 再起動相当で会話が復元され、続きのターンで履歴（thinking ブロック含む）が送信される。

### T-042 ブランチ選択・作成（M, SHOULD）
- **依存**: T-036
- **成果物**: ブランチ一覧（AppBar のドロップダウン）、切替（ワークスペースは repo×branch）、CommitSheet の新規ブランチ（06 §5）。
- **受け入れ基準**: 切替で別ツリーが表示され、保留中の変更はブランチごとに分離される。新規ブランチへのコミットで ref が作られる。

### T-043 キーボードショートカット（S, SHOULD）
- **依存**: T-032, T-039
- **成果物**: 08 §6。
- **受け入れ基準**: 各ショートカットのウィジェットテスト。

---

## Phase 3: 研究実行環境との接続

Jupyter Server REST / WebSocket API を使う。依存に `web_socket_channel` を追加する（ADR-0006 に記載済みなので追加ADR不要）。

### T-050 ExecutionBackend と Jupyter クライアント（L）
- **依存**: T-001
- **成果物**: `domain/repositories/execution_backend.dart`（`connect`, `uploadFile(path, bytes)`, `startKernel(name)`, `execute(kernelId, code) → Stream<ExecOutput>`, `interrupt`, `shutdown`）、`infrastructure/execution/jupyter_client.dart`（`GET /api/status`, `GET /api/kernelspecs`, `POST /api/kernels`, `WS /api/kernels/{id}/channels`, `PUT /api/contents/{path}`, `DELETE /api/kernels/{id}`。認証は `Authorization: token <t>`。JupyterHub は base URL を `https://hub/user/<name>/` にすることで同じAPIが使える）、Jupyter メッセージプロトコル 5.3 の `execute_request` と iopub（`stream`, `display_data`, `execute_result`, `error`, `status`）のパース。
- **受け入れ基準**: フェイクWebSocketで `execute_request` の形（header/parent_header/content）が正しく、iopub の各出力が `ExecOutput` に変換され、`status: idle` で完了する。タイムアウトと `interrupt`。

### T-051 実行環境の設定（S）
- **依存**: T-050, T-022
- **成果物**: 設定画面の実行環境セクション、トークンの `SecureStore` 保存、接続テスト、既定カーネル選択、`https` 以外の拒否（09 §2）。
- **受け入れ基準**: 接続テストの成功/失敗表示。`http://` がリリースビルドで拒否される。

### T-052 ワークスペース同期（M）
- **依存**: T-050, T-031
- **成果物**: `SyncWorkspaceToBackend`: 対象ファイル（実行するNotebook/スクリプトと、同ディレクトリ配下・`data/` など設定可能なパターン）を pending 内容込みで `PUT /api/contents` へアップロード。sha で差分同期（アップロード済み sha を `key_value` に記録）。
- **受け入れ基準**: 2回目の同期で変更ファイルのみアップロードされる。pending の内容が送られる。

### T-053 Notebookセル実行と出力更新（L）
- **依存**: T-052, T-033
- **成果物**: NotebookToolbar の [セル実行] [すべて実行] [中断] [カーネル再起動]、実行結果を `outputs`/`execution_count` に反映して PendingChange 化、実行中インジケータ、実行ログ画面（FR-74）。
- **受け入れ基準**: フェイクバックエンドで実行→出力（stream/画像/error）がセルに反映され、保存で `outputs` が更新される。中断が `interrupt` を呼ぶ。

### T-054 AIツール: run_code / run_notebook_cell（M）
- **依存**: T-053, T-039
- **成果物**: 07 §4 のハンドラ、実行前確認カード（07 §5.1）、「この会話では自動実行」設定、未設定時の `is_error`。
- **受け入れ基準**: 確認で拒否→`is_error`。許可→出力がツール結果になる。画像出力は `[image output: 1]` と要約される。

### T-055 Quarto render（M, SHOULD）
- **依存**: T-054
- **成果物**: `render_quarto` ツールとツールバーの [Render]。実装は Python カーネルで `subprocess.run(["quarto","render",path,"--to",fmt])` を実行し、生成物を `GET /api/contents/<out>?format=base64` で取得して表示（HTMLはサンドボックスWebView、PDFはPDFビューア）。
- **受け入れ基準**: フェイクで render コマンドが送られ、生成物が表示される。失敗時のログ表示。

---

## Phase 4: 研究ライブラリ化（概要）

詳細設計は Phase 3 完了時に `docs/12_library.md` として追加する。想定チケット:

- T-060 PDF注釈オーバーレイ（ハイライト、手書き、`<name>.annotations.json` サイドカー。ADR-0008）
- T-061 端末内全文検索（テキスト系 + PDF抽出テキスト、drift FTS5）
- T-062 `metadata.yaml` の論文一覧ビューと編集フォーム
- T-063 BibTeX パーサ・文献一覧・引用挿入
- T-064 `search_repo` のPDF対応と関連資料検索

## Phase 5: 共同研究（概要）

- T-070 branch/PR の一覧・作成・diff（`GET/POST /repos/{o}/{r}/pulls`）
- T-071 PRレビューコメント
- T-072 アプリ内競合解決の拡張
- T-073 ADR: 端末内Git実装への移行判断

---

## 依存関係図（Phase 0–2）

```text
T-001 ─┬─ T-002 ─ T-003 ─┬─ T-004 ─┐
       │                 └─ T-005 ─┤
       ├─ T-010 ─ T-011 ───────────┴─ T-012 ─ T-013 ─ T-014 ─ T-015 ─┬─ T-016 ─┐
       ├─ T-017 ────────────────────────────────────────────────────┤         ├─ T-018 ─┐
       ├─ T-020 ─ T-021 ────────────────────────────────────────────┤         │         ├─ T-023 ─ T-024 ─ T-025
       └─ T-030 ─┐                                        T-022 ────┤─ T-019 ─┘         │
                 │                                                  │                   │
                 └───────────────────────────────── T-031 ─┬─ T-032 ─ T-043             │
                                                           ├─ T-033 ─┬─ T-035 ─ T-036 ─┬─ T-037
                                                           ├─ T-034  │                 ├─ T-040
                                                           └─ T-038 ─┴─ T-039 ─────────┘
                                                                     T-041 (T-023, T-003)   T-042 (T-036)
```

## 進め方の推奨

1. T-001〜T-005 を順に。
2. `packages/*` のチケット（T-010, T-011, T-017, T-020, T-021, T-030）はアプリ側と独立なので並行して進めやすい。
3. Phase 1 の縦串（T-012 → T-013 → T-014 → T-015）を先に通し、動くアプリを早く作る。
4. 各Phase の最後に手動テストチェックリストを実施し、NFR を計測する。
