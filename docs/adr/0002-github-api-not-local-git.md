# ADR-0002: 端末内Gitを実装せず GitHub REST API を使う

## 状況
MVPの中核は「閲覧 → 編集 → diff → commit」。branch / merge / rebase / オフラインcommit は当面不要。端末内Git（libgit2 バインディング等）は Flutter でのビルド・保守コストが高い。

## 決定
Phase 1〜4 は GitHub REST API（Contents API と Git Data API）のみでリポジトリを操作する。ローカルには「ベースコミット + 内容アドレスのblobキャッシュ + 保留中の変更」だけを持つ。

## 理由
- 実装量が小さく、テストがHTTPモックで完結する。
- Git Data API で複数ファイルの1コミットが作れ、fast-forward 検査（ref更新の422）で安全性を担保できる。
- キャッシュキーを Git の blob SHA にすることで、将来ローカルGitに移行してもオブジェクトを再利用できる。

## 結果
- オフラインでの commit はできない（変更は保持され、オンライン復帰後にcommit）。
- リポジトリ全体のcloneをしないため、`search_repo` は取得済みファイルに限られる（Phase 4 で索引化）。
- GitHub 以外のホスティングには対応しない。
- レート制限（5000/h）に注意が要る。ETag と blob キャッシュで軽減する。

## 再検討の条件
Phase 5 で conflict 解決や branch 操作が API では煩雑になった時点。または GitLab 対応の要望が強い場合。
