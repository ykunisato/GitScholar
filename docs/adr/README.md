# Architecture Decision Records

形式: 状況 / 決定 / 理由 / 結果（トレードオフ）/ 再検討の条件。新しい判断は連番で追加し、`docs/README.md` の前提一覧も更新する。

| # | タイトル | 状態 |
|---|---|---|
| 0001 | Flutter で iOS / Android を単一コードベースにする | 採用 |
| 0002 | 端末内Gitを実装せず GitHub REST API を使う | 採用 |
| 0003 | GitHub認証は OAuth Device Flow | 採用 |
| 0004 | AI呼び出しはユーザー自身のAPIキー（BYOK）でアプリから直接行う | 採用 |
| 0005 | エージェントループはアプリ内で回し、書き込みは「提案」として承認を経る | 採用 |
| 0006 | コード実行は Jupyter Server / JupyterHub に委ねる | 採用 |
| 0007 | UI非依存ロジックは純Dartパッケージに分離する | 採用 |
| 0008 | PDF注釈はサイドカーJSONで保存する | 採用（Phase 4） |
