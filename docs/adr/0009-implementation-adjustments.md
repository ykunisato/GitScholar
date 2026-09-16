# ADR-0009: 実装時に確定した技術判断（2026-09 初期実装）

## 状況
設計書（02, 07, 10）作成後、実装開始時点の最新パッケージと Claude API の仕様を確認したところ、設計書の一部と食い違う点があった。

## 決定

### 1. 依存パッケージのバージョン
`flutter pub add` 時点（Flutter 3.47.4 / Dart 3.13）の最新安定版を採用する。設計書記載からメジャーが上がったもの:

| パッケージ | 設計書 | 採用 |
|---|---|---|
| flutter_riverpod | ^3.0.0 | ^3.4.3 |
| go_router | ^15.0.0 | ^18.0.1 |
| flutter_secure_storage | ^9.2.0 | ^11.1.1 |
| pdfrx | ^1.1.0 | ^2.6.1 |
| re_editor | ^0.7.0 | ^0.10.0 |
| drift_flutter | ^0.2.0 | ^0.3.1 |
| flutter_lints | ^5.0.0 | ^6.0.0 |

追加: `http`（GitHub/Anthropic/Jupyter の HTTP。`dio` は使わない）、`uuid`（ID生成）、`web_socket_channel`（Phase 3）。

### 2. コード生成は drift のみ
`freezed` / `json_serializable` / `riverpod_generator` は使わない。エンティティは手書きの不変クラス（必要なものに `copyWith`）、Provider は `Notifier` / `AsyncNotifier` を手書きする。

理由: エンティティ数が少なく、生成コードの互換性問題（analyzer バージョン衝突）とビルド時間を避けられる。AIエージェントが読むときも生成物を追わずに済む。

### 3. HTTP クライアントは `http`
`dio` のインターセプタ前提だった再試行は、`GitHubGateway` と `AnthropicClient` 内で明示的に実装する（GET のみ指数バックオフ）。テストは `package:http/testing.dart` の `MockClient` で行う。

### 4. プロンプトキャッシュ
07 §2 の「最初のユーザーメッセージの文脈ブロックに `cache_control`」はやめ、**システムプロンプトの明示ブレークポイント + リクエスト最上位の自動キャッシュ（`cache_control: {type: ephemeral}`）**にする。会話中に文脈更新メッセージが増えるとブレークポイント上限（4）を超えるため。

### 5. 古いツール結果の省略
07 §2 の「クライアント側で古い `tool_result` を `[省略]` に置換」はやめ、**サーバー側のコンテキスト編集**（`context_management.edits: [{type: clear_tool_uses_20250919}]`, beta `context-management-2025-06-27`）を使う。クライアントで過去のターンを書き換えると、thinking ブロックの再送検証（preserved thinking）に反し、Claude Fable 5.1 等で 400 になりうるため。会話履歴は**追記のみ**とする。

### 6. refusal の扱い
`stop_reason: refusal` の応答は途中までの出力を履歴に追加せず破棄する（ユーザーには通知）。Opus 5 / Fable 5.1 では `fallbacks: "default"`（beta `server-side-fallback-2026-07-01`）を常に付ける。

### 7. テスト用フェイク GitHub
10 §2 の「`http.MockClient` ベースのフェイクサーバー」は、**`GitHubRepository` インターフェースを実装したインメモリ実装**（`test/fakes/fake_github.dart`）にする。HTTP 形状は `packages/github_api` の単体テストで検証済みのため、アプリ側は Git の意味論（blob/tree/commit/ref、fast-forward 検査）に集中する。

### 8. Riverpod の構成
`currentWorkspaceProvider`（AsyncNotifier）、`pendingChangesProvider`（drift の watch を StreamProvider）、`fileContentProvider`（family）、`agentControllerProvider`（Notifier）を中心にする。詳細は `lib/presentation/core/providers.dart`。

## 結果
- 02 §2, §6、07 §2, 10 §2 を本 ADR に合わせて更新した。
- 生成が必要なのは `lib/infrastructure/local/app_database.g.dart` と `lib/l10n/app_localizations*.dart` のみ。
