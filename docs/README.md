# GitScholar 設計書 索引

本ディレクトリは、GitScholar をAIコーディングエージェント（Claude Opus / Sonnet 等）が実装できるように書かれた設計書群である。
文書は「何を作るか（要件）→ どう作るか（アーキテクチャ・各機能仕様）→ どの順に作るか（実装計画）」の順に並んでいる。

## 読む順序

| # | 文書 | 内容 | いつ読むか |
|---|---|---|---|
| 00 | [00_concept.md](00_concept.md) | 構想・背景・差別化（原典） | 最初に一度 |
| 01 | [01_requirements.md](01_requirements.md) | 機能要件・非機能要件・MVPスコープ・用語 | 最初に一度、チケット着手時に該当IDを参照 |
| 02 | [02_architecture.md](02_architecture.md) | 技術スタック、層構造、ディレクトリ規約、依存パッケージ、状態管理、エラー方針 | 実装前に必ず |
| 03 | [03_data_model.md](03_data_model.md) | ドメインモデル、ローカルDBスキーマ、キャッシュ設計 | データ層を触るとき |
| 04 | [04_github_integration.md](04_github_integration.md) | GitHub認証（Device Flow）、REST API利用仕様、commit戦略、レート制限 | GitHub連携を触るとき |
| 05 | [05_viewers.md](05_viewers.md) | PDF / Markdown / Notebook / コードの表示仕様、`.ipynb` パーサ仕様 | ビューアを触るとき |
| 06 | [06_editing_diff_commit.md](06_editing_diff_commit.md) | 編集、保留中の変更、diff、commit/push、競合処理 | 編集・commitを触るとき |
| 07 | [07_ai_agent.md](07_ai_agent.md) | AIエージェント層：Claude API利用、ツール定義、承認フロー、コンテキスト構築、プライバシー | AI機能を触るとき |
| 08 | [08_ui_spec.md](08_ui_spec.md) | 画面一覧、ナビゲーション、レスポンシブ、各画面の仕様 | UIを触るとき |
| 09 | [09_security_privacy.md](09_security_privacy.md) | 秘密情報の扱い、HTML出力のサンドボックス、AIへのデータ送信境界 | 常に意識、レビュー時 |
| 10 | [10_testing_quality.md](10_testing_quality.md) | テスト戦略、CI、Definition of Done、コーディング規約 | PR作成前 |
| 11 | [11_implementation_plan.md](11_implementation_plan.md) | フェーズ別の実装チケット（依存関係・受け入れ基準付き） | 作業の起点 |
| ADR | [adr/](adr/) | 主要な技術判断とその理由 | 判断の背景を知りたいとき |

## 文書内の記法

- **要件ID**: `FR-xx`（機能要件）、`NFR-xx`（非機能要件）。チケットと実装のコメントから参照する。
- **チケットID**: `T-xxx`。ブランチ名・コミットメッセージに含める。
- **MUST / SHOULD / MAY**: RFC 2119 に準じる。MUSTを満たさない実装は完了としない。
- コード識別子（クラス名、ファイル名、API名）は英語、説明は日本語で書く。

## 設計の前提（変えるならADRを追加する）

1. アプリは **Flutter** で iOS / Android を単一コードベースで実装する（ADR-0001）。
2. Git操作は端末内にGitを実装せず **GitHub REST API** で行う（ADR-0002）。
3. GitHub認証は **OAuth Device Flow** で行い、アプリにクライアントシークレットを持たせない（ADR-0003）。
4. AI呼び出しは当面 **ユーザー自身のAnthropic APIキー（BYOK）** でアプリから直接行い、エージェントループもアプリ内で回す（ADR-0004, ADR-0005）。
5. Python / R / Quarto の実行は端末内で行わず、**Jupyter Server / JupyterHub** に委ねる（ADR-0006）。
6. ビジネスロジックのうちUIに依存しない部分は **純Dartパッケージ**（`packages/`）に切り出し、Flutter無しでテストできるようにする（ADR-0007）。
7. コード生成は drift と l10n のみ。HTTP は `http`、キャッシュはシステム+自動、古いツール結果はサーバー側コンテキスト編集（ADR-0009）。
