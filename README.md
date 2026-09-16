# GitScholar

GitHub 上の論文・研究ノート・Jupyter Notebook・分析コードを iPad / Android で閲覧・編集し、AI に調査や修正を依頼できる研究者向けワークスペースです。

設計書は [docs/](docs/README.md)、AI コーディングエージェント向けの作業ルールは [CLAUDE.md](CLAUDE.md) にあります。

## 主な機能

- GitHub サインイン（OAuth Device Flow）とリポジトリ選択
- ファイルツリー、PDF・Markdown（数式・相対リンク）・Notebook・コード・画像の表示
- テキスト・Markdown・Notebook の編集、差分表示、コミットとプッシュ（競合検出つき）
- AI パネル（Claude）: 開いているファイルへの質問、リポジトリ検索、変更提案と承認、コミット依頼
- Jupyter Server / JupyterHub でのセル実行、Quarto render（任意）

## 必要なもの

| 項目 | 内容 |
|---|---|
| Flutter | 3.47.4（`.fvmrc`） |
| iOS | Xcode 26 以上、iOS 16 以上 |
| Android | Android SDK、JDK 17、Android 9（API 28）以上 |
| GitHub | Device Flow を有効にした OAuth App の Client ID |
| AI | 各ユーザーの Anthropic API キー（アプリの設定画面で入力） |

## セットアップ

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter gen-l10n
```

GitHub OAuth App を作成し（Settings → Developer settings → OAuth Apps）、"Enable Device Flow" をオンにして Client ID を取得します。

```bash
flutter run --dart-define=GITHUB_CLIENT_ID=<your client id>
```

毎回打つ代わりに、`env.json`（gitignore 済み）に書いて渡すこともできます。

```json
{ "GITHUB_CLIENT_ID": "Ov23li..." }
```

```bash
flutter run --dart-define-from-file=env.json
flutter build ipa --dart-define-from-file=env.json
```

Client ID は秘密情報ではありません（クライアントシークレットはアプリに持たせません）。未設定のままでもアプリは起動しますが、サインイン時に「クライアントIDが設定されていません」と表示されます。

## テスト

```bash
flutter analyze
flutter test
for p in packages/*; do (cd "$p" && dart pub get && dart test); done
```

## ディレクトリ

```text
lib/domain          エンティティ、失敗型、純ロジック（パス、ignore、ツリー）
lib/application     サービス（ワークスペース、編集、コミット、AI、実行）
lib/infrastructure  GitHub、drift DB、BlobStore、秘密情報、AI ツール、Jupyter
lib/presentation    画面とウィジェット（Riverpod）
packages/           純 Dart パッケージ（nbformat, text_diff, github_api, scholar_agent）
docs/               設計書と ADR
```
