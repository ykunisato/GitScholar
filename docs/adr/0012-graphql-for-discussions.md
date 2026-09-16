# ADR-0012: Discussion のために GraphQL を併用する

## 状況
リポジトリの Discussion を読み書きしたいが、GitHub の REST API には Discussion のエンドポイントが無く、GraphQL API だけが対応している。ADR-0002 では「GitHub REST API を使う」と決めていた。

## 決定
Discussion に限り `POST /graphql` を使う。Issues は従来どおり REST を使う。GraphQL クライアントのパッケージは追加せず、既存の `http` で `packages/github_api` の `GitHubClient.graphql()` として実装する。クエリは同パッケージ内に文字列として置く。

リアクション（FR-99）も Issues / Discussion の区別なく GraphQL の `addReaction` / `removeReaction` を使う。REST では取り消しに reaction id が必要で、自分のリアクションを探すための一覧取得が余計に要るため。

## 理由
- Discussion を諦めると、研究室での議論をアプリから読めない。ゼミ利用では Issues と同じくらい使われる。
- GraphQL クライアントのパッケージを入れるとコード生成や依存が増える。問い合わせは数種類しかないため、素の HTTP で十分。
- 認証は同じトークンで、`repo` スコープのまま読める。再サインインは不要。

## 結果
- GraphQL はエラーでも HTTP 200 を返すため、`errors` を見て例外に変換する処理が必要（`GitHubClient.graphql`）。
- Discussion が無効なリポジトリでは `hasDiscussionsEnabled` が false になる。エラーではなく「未設定」として扱う。
- ETag による条件付きリクエストは GraphQL では使えない。一覧は毎回取得する。
- 将来 Discussion 以外でも GraphQL が必要になったら、クエリの置き場所を見直す。
