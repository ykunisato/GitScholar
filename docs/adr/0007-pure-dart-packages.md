# ADR-0007: UI非依存ロジックは純Dartパッケージに分離する

## 状況
AIコーディングエージェントが実装・検証しやすいように、テストが速く、失敗が局所化される構造が欲しい。

## 決定
`.ipynb` パーサ（nbformat）、行diff（text_diff）、GitHub APIクライアント（github_api）、Claude API クライアントとエージェントループ（scholar_agent）を `packages/` 配下の純Dartパッケージにし、Flutter に依存させない。

## 理由
- `dart test` だけで数秒で検証でき、エミュレータ不要。
- 責務が明確でカバレッジ目標（80%）を課しやすい。
- 将来、CLI やサーバー側で同じロジックを再利用できる。

## 結果
- アプリ側に薄いアダプタ（mappers、failure_mapper）が必要。
- パッケージ間の依存は `github_api` → なし、`scholar_agent` → なし、`nbformat` → なし、`text_diff` → なし とし、相互依存させない。
