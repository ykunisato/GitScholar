# ADR-0010: OpenAI互換の提供元に対応する

## 状況
初期実装では AI 呼び出しを Anthropic の Messages API に直接結びつけていた（ADR-0004）。利用者から、ChatGPT や OpenRouter でも使いたいという要望があった。

## 決定
`packages/scholar_agent` に提供元の抽象 `LlmClient` を置き、実装を2つ持つ。

| 実装 | 対象 |
|---|---|
| `AnthropicClient` | Anthropic Messages API（既存。思考の要約、プロンプトキャッシュ、サーバ側フォールバック、コンテキスト編集を利用） |
| `OpenAiClient` | OpenAI 互換の Chat Completions（OpenAI、OpenRouter、および同じ形式を話す自前サーバ） |

OpenAI 互換を1つ作れば OpenRouter も同時に満たせる。OpenRouter 経由なら Claude や Gemini も同じ入口から使えるため、提供元ごとに実装を増やす必要がない。

### 正本の会話形式
保存と再送の正本は Anthropic 形式のコンテンツブロック（`text` / `thinking` / `tool_use` / `tool_result`）のままとする。`OpenAiClient` が送信時に Chat Completions 形式へ変換し、受信時に元の形式へ戻す。理由は、既存の保存データ、AI パネル、ツール層をそのまま使えるため。

変換の要点:
- `system` ブロックは先頭の `system` メッセージへ結合する。
- `tool_result` は `role: tool` の独立したメッセージにし、対応する assistant の直後に置く。
- `tool_use` は `tool_calls` の関数呼び出しへ写す。引数は JSON 文字列。
- **`thinking` ブロックは送信しない。** 提供元固有であり、他モデルへ渡してはならない。
- 受信側の `reasoning` / `reasoning_content` は画面表示のみに使い、保存も再送もしない。

### 提供元ごとの差異
- 出力上限は OpenAI が `max_completion_tokens`、それ以外は `max_tokens`。接続先で切り替える。
- 思考の要約、プロンプトキャッシュ、`effort`、サーバ側フォールバック、コンテキスト編集は Anthropic 専用。他提供元では送らない。
- 終了理由は `stop`/`tool_calls`/`length`/`content_filter` を、正本の `end_turn`/`tool_use`/`max_tokens`/`refusal` へ対応付ける。

### 鍵の保存
提供元ごとに別のキーで保存する（`anthropic_api_key`, `openai_api_key`, `openrouter_api_key`, `custom_llm_api_key`）。切り替えても入力し直しにならない。

## 結果
- エージェントループ、ツール、承認フロー、文脈の組み立て、会話の保存は提供元に依存しない。
- Anthropic 以外ではプロンプトキャッシュが効かないため、長い文脈を繰り返す使い方では入力費用が増える。
- ツール利用に対応しないモデルでは変更提案が機能しない。設定画面で注意を示す。
- ADR-0004 の「Anthropic へ直接」は、BYOK の方針は維持したうえで提供元を選べる形に改める。
