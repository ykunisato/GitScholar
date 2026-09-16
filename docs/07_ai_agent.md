# 07. AIエージェント層

対象: `packages/scholar_agent`（純Dart: Claude Messages API クライアント、SSEパーサ、エージェントループ）、`lib/infrastructure/ai/`（ツール実装、ゲートウェイ）、`lib/application/agent/`、`lib/presentation/agent/`。

## 1. 方針

- Dart には Anthropic 公式SDKが無いため、**Messages API を Raw HTTP** で叩く。エンドポイントは `POST https://api.anthropic.com/v1/messages`、ヘッダは `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`、必要時 `anthropic-beta`。
- APIキーはユーザー自身のもの（BYOK, ADR-0004）。`SecureStore` の `anthropic_api_key` に保存する。
- エージェントループ（tool_use → 実行 → tool_result → 再送）は **アプリ内**で回す（ADR-0005）。ツールはローカルのワークスペースに対して動くため、サーバーを介す必要がない。
- モデルは既定 `claude-opus-5`。設定で `claude-sonnet-5`、`claude-fable-5-1` を選べる（FR-68）。日付サフィックス付きIDは使わない。
- 応答は必ずストリーミング（`stream: true`）で受け取り、UIに逐次表示する。

## 2. リクエスト仕様

```jsonc
{
  "model": "claude-opus-5",
  "max_tokens": 32000,
  "stream": true,
  "thinking": { "type": "adaptive", "display": "summarized" },   // Settings.aiShowThinkingSummary=false なら display を省略
  "output_config": { "effort": "high" },                          // Settings.aiEffort
  "fallbacks": "default",                                         // Opus 5 / Fable 5.1 の refusal 時にサーバー側で代替モデルへ
  "cache_control": { "type": "ephemeral" },                       // 自動キャッシュ（最後のキャッシュ可能ブロックに配置）
  "context_management": { "edits": [ { "type": "clear_tool_uses_20250919" } ] },  // 古いツール結果をサーバー側で消去
  "system": [
    { "type": "text", "text": "<固定システムプロンプト>", "cache_control": { "type": "ephemeral" } }
  ],
  "tools": [ ... ],                                               // §4。順序を固定してキャッシュを効かせる
  "messages": [
    { "role": "user", "content": [
        { "type": "text", "text": "<添付コンテキスト（開いているファイル等）>" },
        { "type": "text", "text": "<ユーザーの発話>" }
    ]},
    ...
  ]
}
```

- `fallbacks: "default"` を使うため、ヘッダに `anthropic-beta: server-side-fallback-2026-07-01` を付ける。コンテキスト編集のため `context-management-2025-06-27` も付ける（カンマ区切り）。`claude-sonnet-5` 選択時はこのパラメータとヘッダを付けない。
- `claude-fable-5-1` 選択時は `thinking` を送らないか `{type: "adaptive"}` のみとし、`tool_choice` に `any`/`tool` を使わない（本設計では常に `auto` なので影響なし）。
- `temperature` 等のサンプリングパラメータは送らない。
- **プレフィックス安定化**: `system`・`tools` は会話中に変更しない。添付コンテキストは会話の **最初のユーザーメッセージ**に置き、以降のターンで同じファイルなら再送しない（差分があれば新しいユーザーメッセージに「更新されたファイル」として追加）。
- 会話履歴は `messages` に全量送る。**履歴は追記のみで、過去のメッセージをクライアント側で書き換えない**（thinking ブロックの再送検証のため）。古いツール結果の整理はサーバー側コンテキスト編集に任せ、入力トークンが 150K を超えたら新しい会話を促す（ADR-0009）。
- `stop_reason: refusal` の応答は履歴に追加しない。
- 応答の `content` は **そのまま**（thinking ブロック含む）次ターンの `assistant` メッセージとして送り返す。同一モデルで続ける限り thinking ブロックを削除・改変しない。

### 2.1 SSE パース

`packages/scholar_agent/lib/src/sse.dart` で `event:` / `data:` 行を解析し、以下のイベントを `Stream<StreamEvent>` として流す: `message_start`, `content_block_start`, `content_block_delta`（`text_delta`, `input_json_delta`, `thinking_delta`）, `content_block_stop`, `message_delta`（`stop_reason`, `usage`）, `message_stop`, `error`, `ping`。

`input_json_delta` は `partial_json` を連結し、`content_block_stop` で `jsonDecode` する（文字列一致での判定はしない）。

### 2.2 応答の終端処理

| `stop_reason` | 処理 |
|---|---|
| `end_turn` | ターン終了。メッセージを保存 |
| `tool_use` | §5 のループへ |
| `max_tokens` | 「出力が長すぎて途中で切れました。続けますか？」を表示。「続ける」で `"続けて"` を送る |
| `refusal` | `stop_details.category` と `explanation` があれば表示。`fallbacks` で代替モデルが答えた場合は `usage`/`fallback` ブロックからモデル名を読み「別のモデルが応答しました」と注記 |
| `pause_turn` | 同じ `messages` で再送（最大3回） |

### 2.3 エラー

| HTTP | 処理 |
|---|---|
| 401 | `AiFailure("APIキーが無効です")` → 設定画面へ誘導 |
| 429 | `RateLimitFailure`。`retry-after` を表示、自動再試行なし |
| 400 | `AiFailure(message)`。本文の `error.message` をそのまま表示 |
| 529 / 5xx | 指数バックオフで最大2回再試行後 `AiFailure` |
| ストリーム途中の切断 | 受信済みテキストは保持し「接続が切れました（再送）」ボタン |

## 3. システムプロンプト（固定部）

`lib/infrastructure/ai/system_prompt.dart` に定数として置く。要旨:

```text
あなたは GitScholar の研究アシスタントです。ユーザーはGitHubリポジトリで論文・ノート・分析コードを管理する研究者です。
- ツールでリポジトリ内のファイルを読み、探し、変更を提案できます。ファイルへの書き込みは propose_change による「提案」であり、ユーザーが承認するまで反映されません。
- commit は request_commit で依頼するだけで、実行はユーザーが行います。
- 添付されたファイル内容と選択範囲を最優先の文脈として使ってください。不足があれば read_file / search_repo で調べてから答えてください。
- 回答は日本語（ユーザーが英語で話しかけたら英語）。数式は $...$ / $$...$$。ファイルに言及するときはリポジトリ内パスをそのまま書いてください（UIがリンクにします）。
- 変更を提案するときは、なぜその変更か、何を確認したかを短く説明してください。既存のコードスタイルとノートの書き方に合わせてください。
- 提案は必要最小限の差分にし、ファイル全体を書き直さないでください（propose_change の edits を使う）。
```

添付コンテキストのフォーマット（最初のユーザーメッセージの先頭ブロック）:

```text
<context>
<repository name="owner/name" branch="main" />
<open_file path="notes/Safron2021.md" kind="markdown" selection_lines="12-18">
<content>
...ファイル全文（上限: 200KB。超える場合は選択範囲の前後 2,000 行）...
</content>
<selection>
...選択テキスト...
</selection>
</open_file>
<tree_summary>
...ディレクトリの一覧（深さ2まで、最大200行）...
</tree_summary>
</context>
```

PDFの場合、`<content>` にはPDFから抽出したテキストを入れる（05 §1）。Notebook の場合は `serializeNotebook` 結果ではなく、セルを `[cell 3, code]` 見出し付きで整形したテキストにし、画像出力は `[image/png output]` と置換する。

## 4. ツール定義

`packages/scholar_agent` は `ToolDefinition {name, description, inputSchema, strict}` と `ToolHandler = Future<ToolResult> Function(Map<String,dynamic> input)` を持つ。アプリ側（`lib/infrastructure/ai/tools/`）がハンドラを実装する。すべて `strict: true`、`additionalProperties: false`、`required` を明示する。

| name | Phase | 入力 | 出力 | 実装要点 |
|---|---|---|---|---|
| `list_files` | 2 | `{path?: string, depth?: int}` | ディレクトリ配下の一覧（`type path size`） | tree_entries から。`.gitscholarignore` 適用 |
| `read_file` | 2 | `{path: string, start_line?: int, end_line?: int}` | 行番号付きテキスト。PDFはテキスト抽出、ipynbはセル整形（§3） | `LoadFile` 経由（pending を反映）。200KB上限、超過時は範囲指定を促すメッセージ |
| `search_repo` | 2 | `{query: string, regex?: bool, paths?: string[], max_results?: int}` | `path:line: text` の一覧（既定50件） | キャッシュ済みテキストファイルを走査。未キャッシュのテキストファイルは 1MB 以下なら取得して検索（合計 200 ファイルまで）。PDFは Phase 4 の索引まで対象外 |
| `propose_change` | 2 | `{path: string, kind: "modify"\|"create"\|"delete", edits?: [{old_text: string, new_text: string}], content?: string, explanation: string}` | `{proposal_id, diff_summary}` または `{error}` | modify は `edits` 必須。各 `old_text` は現在の内容に **ちょうど1回**出現しなければならず、違反時は `is_error` 付き結果で理由を返す。create は `content` 必須。結果を `Proposal` + `PendingChange(status: proposed)` として保存し、UIに提案カードを出す |
| `get_diff` | 2 | `{path?: string}` | 保留中の変更（pending と proposed）の unified diff | `text_diff` |
| `request_commit` | 2 | `{message: string, paths: string[]}` | `{request_id, status: "awaiting_user"}` | `CommitRequest` を保存し、UIに「コミットの依頼」カード。**実際のcommitはしない** |
| `run_code` | 3 | `{language: "python"\|"r", code: string, timeout_sec?: int}` | stdout / stderr / 画像出力の有無 / 実行時間 | `ExecutionBackend`。未設定なら `is_error` で「実行環境が未設定」 |
| `run_notebook_cell` | 3 | `{path: string, cell_index: int}` | 出力テキスト | 実行後の出力は Notebook の PendingChange に反映（出力更新も「変更」） |
| `render_quarto` | 3 | `{path: string, format?: "html"\|"pdf"}` | ログと生成物の参照 | |

ツール結果は `tool_result` の `content` に文字列で返す。エラーは `is_error: true`。1つの assistant メッセージに複数 `tool_use` があれば **並列に実行し、すべての `tool_result` を1つの user メッセージにまとめて**返す。

## 5. エージェントループと承認

```text
RunAgentTurn(conversationId, userText, attachedContext)
  1. messages を組み立て（§2）、Messages API をストリーム呼び出し
  2. content_block を逐次 UI に流す（text は逐次描画、thinking summary は折りたたみ、tool_use は「🔧 read_file notes/x.md」）
  3. stop_reason == tool_use:
     a. 各 tool_use について、ツール種別ごとの権限を確認（§5.1）
     b. ハンドラを並列実行（Future.wait）。1つのツールは最大 60 秒でタイムアウトし is_error
     c. tool_result を user メッセージとして追加し、1へ戻る
     d. ループ上限: 1ターンあたりツール呼び出し 25 回。超えたら「作業が長くなっています。続けますか？」で停止
  4. stop_reason == end_turn: メッセージを保存、usage を集計してフッタに表示
```

### 5.1 権限境界（FR-64, FR-65）

| 種別 | 実行 | ユーザー確認 |
|---|---|---|
| 読み取り（list/read/search/get_diff） | 自動 | 不要（ただし AiAccessPolicy が deny のリポジトリでは会話自体を開始できない） |
| 提案（propose_change） | 自動（保存は proposed 状態） | 反映には **承認** が必要。承認で `status: pending` になり、ビューアに反映される |
| commit（request_commit） | 依頼を保存するだけ | ユーザーが CommitSheet で明示的に実行 |
| 実行（run_code 等） | 既定は **実行前に確認**（コードを表示して「実行」ボタン）。設定で「この会話では自動実行」に切替可 | |

- 提案カード: パス、説明、diff（折りたたみ）、[承認] [却下] [エディタで開く]。承認前は通常のビューアに反映されない。却下すると `status: rejected` にし、その旨をツール結果としてAIに伝える（次のターンのユーザーメッセージ先頭に `<system_note>提案 X は却下されました</system_note>` を付加）。
- 複数提案は「すべて承認」も可能。
- 承認済みの提案は通常の PendingChange（origin: ai）として変更一覧に載り、通常のcommitフローに乗る。

### 5.2 `.gitscholarignore` と送信境界（FR-69）

- リポジトリ直下の `.gitscholarignore`（gitignore と同じ構文。`domain/services/ignore_rules.dart` で実装。`**`, `*`, `?`, 否定 `!`, ディレクトリ末尾 `/` をサポート）に一致するパスは、添付コンテキスト・`read_file`・`search_repo`・`list_files` のすべてから除外し、AIには「アクセス制限されたファイル」とだけ返す。
- 既定で除外: `.env`, `*.pem`, `*.key`, `**/secrets/**`。
- 会話開始時、リポジトリが private かつ `ai_access == ask` なら「このリポジトリの内容をAnthropic APIに送信します」の確認ダイアログ（「このリポジトリでは今後確認しない」チェック付き）。
- AIパネル上部に「送信中の文脈: notes/x.md（選択 12–18行）, ツリー概要」を常時表示（NFR-31）。

## 6. 会話の保存

- `conversations` / `messages` に保存。`blocks_json` は API の content ブロックをそのまま保存（thinking ブロック含む。再送に必要）。
- 会話タイトルは最初のユーザー発話の先頭 40 文字。「タイトルを生成」はしない（コスト節約）。
- 会話一覧はリポジトリ単位。削除可能。

## 7. `packages/scholar_agent` 公開API

```dart
class AnthropicClient {
  AnthropicClient({required String apiKey, http.Client? client, String baseUrl = 'https://api.anthropic.com'});
  Stream<StreamEvent> streamMessage(MessageRequest request);   // SSE
}

class MessageRequest { String model; int maxTokens; List<SystemBlock> system; List<ToolDefinition> tools;
  List<Message> messages; ThinkingConfig? thinking; OutputConfig? outputConfig; String? fallbacks; List<String> betas; }

class AgentLoop {
  AgentLoop({required AnthropicClient client, required Map<String, ToolHandler> handlers,
             required PermissionGate gate, int maxToolCalls = 25});
  /// 1ターン分。AgentEvent（TextDelta / ThinkingDelta / ToolCallStarted / ToolCallFinished / TurnFinished / Failure）を流す
  Stream<AgentEvent> runTurn(List<Message> history, MessageRequest Function(List<Message>) buildRequest);
}

abstract class PermissionGate { Future<bool> allow(ToolUse call); }   // アプリ側で確認UIに接続
```

テスト（`packages/scholar_agent/test/`）:
- SSE パーサ: 分割された `data:` 行、`input_json_delta` の連結、`ping`、`error` イベント。
- `AgentLoop`: モッククライアントで `tool_use` → `tool_result` → `end_turn` の往復、並列ツール、`is_error`、ループ上限、`PermissionGate` 拒否時の挙動。
- リクエスト組み立て: `cache_control` の位置、`fallbacks` とベータヘッダの有無がモデル選択に応じて切り替わること。

## 8. コスト表示

各アシスタントメッセージの `usage`（`input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`）を保存し、メッセージのフッタに「入力 12.3K（キャッシュ 10.1K）/ 出力 1.2K」と表示する。金額換算はしない（価格改定に追従できないため）。

## 9. 将来（バックエンド導入時、ADR-0004 参照）

BYOK から自前バックエンド経由に切り替える場合、`AnthropicClient` の `baseUrl` と認証ヘッダを差し替えるだけで済むよう、`packages/scholar_agent` はキー付与を `HeaderProvider` インターフェースで抽象化しておく。
