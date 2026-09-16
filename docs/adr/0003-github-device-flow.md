# ADR-0003: GitHub認証は OAuth Device Flow

## 状況
モバイルアプリに OAuth のクライアントシークレットを埋め込めない。トークン交換用のバックエンドも MVP では持ちたくない。

## 決定
GitHub OAuth App の Device Flow を使う。アプリは Client ID のみを持ち、ユーザーはブラウザで `github.com/login/device` にコードを入力する。

## 理由
- クライアントシークレット不要で、アプリ単体で完結する。
- WebView 内ログインを避けられる（ストア審査・セキュリティ上望ましい）。
- 実装が単純（POST 2種類とポーリング）。

## 結果
- 初回ログインにブラウザとコード入力の手間がある（1回だけ）。
- トークンは長寿命（OAuth App は期限なし）。失効時は 401 で検出して再ログイン。
- GitHub App（fine-grained 権限、期限付きトークン）への移行は、Device Flow が GitHub App でもサポートされているため容易。

## 再検討の条件
バックエンド（ADR-0004 の将来形）を持つようになった時点で、Web Flow + PKCE + バックエンド交換に切り替えるか検討する。
