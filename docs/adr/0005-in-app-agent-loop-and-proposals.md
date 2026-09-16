# ADR-0005: エージェントループはアプリ内で回し、書き込みは「提案」として承認を経る

## 状況
AI に read / write / commit / run のツールを与えるが、ユーザーの知らないうちにファイルが書き換わったり commit されたりしてはならない（01 FR-64, FR-65）。

## 決定
- Messages API の tool_use ループを `packages/scholar_agent` の `AgentLoop` でアプリ内に実装する。
- 書き込みツール `propose_change` は `PendingChange(status: proposed)` を作るだけで、承認（`pending` へ遷移）までビューアや変更一覧に反映しない。
- commit は `request_commit` で「依頼」を作るだけ。実行は必ずユーザーの CommitSheet 操作。
- 実行系ツールは既定で実行前確認。

## 理由
- 承認境界を「PendingChange の status」という単一の状態で表現でき、ユーザー編集とAI編集が同じ commit フローに乗る。
- `edits: [{old_text, new_text}]` の「ちょうど1回一致」制約で、AI の書き換え範囲を局所化できる。
- ループをアプリ内で回すことで、ツールがローカルキャッシュ・pending をそのまま参照でき、サーバー往復が不要。

## 結果
- 端末がスリープするとループが止まる（長時間の自律作業には向かない）。Phase 3 の実行待ちはタイムアウト60秒で区切る。
- 会話履歴の再送量が増えるため、prompt caching（system / tools / 初回コンテキスト）を必須とする。

## 再検討の条件
数十分単位の自律作業（大規模リファクタ、長時間の解析）の要望が出た場合、サーバー側で回す構成（Managed Agents 等）を検討する。
