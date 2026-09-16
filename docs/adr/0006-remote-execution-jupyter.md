# ADR-0006: コード実行は Jupyter Server / JupyterHub に委ねる

## 状況
Python / R / Quarto を端末内で実行するのは、iOS の制約とパッケージ環境の再現性の両面で非現実的。研究者は既に JupyterHub や自前サーバーを持っていることが多い。

## 決定
`ExecutionBackend` インターフェースを定義し、最初の実装として Jupyter Server REST API + WebSocket（カーネルプロトコル 5.3）を使う。JupyterHub はユーザーサーバーの base URL を指定することで同じ実装で扱う。ファイルは Contents API で実行前に同期する。Quarto はカーネル経由で `quarto render` を呼ぶ。

依存パッケージとして `web_socket_channel` を Phase 3 で追加する（02 §6 に記載）。

## 理由
- 標準APIであり、JupyterHub / 単体 Jupyter Server / 各種クラウドのJupyterで共通に使える。
- ユーザーが環境（パッケージ、R バージョン）を管理でき、アプリは環境の再現性に責任を負わない。
- Notebook の出力更新がカーネルプロトコルの出力そのままで得られる。

## 結果
- 実行にはネットワークとユーザーのサーバーが必要。
- サーバー側の作業ディレクトリと GitHub リポジトリの同期はアプリが片方向（アップロード）で行う。サーバー側で生成された成果物のリポジトリへの取り込みは明示操作（Phase 3 の SHOULD）。
- 専用リモートワーカー（コンテナを都度起動）は、需要があれば `ExecutionBackend` の別実装として追加する。

## 再検討の条件
Jupyter を持たないユーザーが多数で、ホスト型実行環境の提供が事業上必要になった場合。
