# GitScholar

GitHub 上の論文・研究ノート・Jupyter Notebook・分析コードを iPad / Android で閲覧・編集し、AI に調査や修正を依頼できる研究者向けワークスペースです。

設計書は [docs/](docs/README.md)、AI コーディングエージェント向けの作業ルールは [CLAUDE.md](CLAUDE.md) にあります。

## 主な機能

- GitHub サインイン（OAuth Device Flow）とリポジトリ選択
- ファイルツリー、PDF・Markdown（数式・相対リンク）・Notebook・コード・画像の表示
- テキスト・Markdown・Notebook の編集、差分表示、コミットとプッシュ（競合検出つき）
- AI パネル: 開いているファイルへの質問、リポジトリ検索、変更提案と承認、コミット依頼
- AI の提供元は Anthropic、OpenAI、OpenRouter、OpenAI互換の自前サーバから選択（設定画面、鍵は提供元ごとに保存）
- GitHub Discussion / Issues の閲覧、コメント投稿、絵文字リアクション
- PDF のマーカーと、PDFと同名の Markdown へのメモ追記
- リポジトリのピン留め（最大10件）とオフライン保存
- Jupyter Server / JupyterHub でのセル実行、Quarto render（任意）

## 必要なもの

| 項目 | 内容 |
|---|---|
| Flutter | 3.47.4（`.fvmrc`） |
| iOS | Xcode 26 以上、iOS 16 以上 |
| Android | Android SDK、JDK 17、Android 9（API 28）以上 |
| GitHub | Device Flow を有効にした OAuth App の Client ID |
| AI | 利用する提供元の API キー（アプリの設定画面で入力。Anthropic / OpenAI / OpenRouter など） |

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

## iPad / iPhone の実機で動かす

Android と違う点が3つあります。どれも初回だけの作業です。

### 1. 端末側でデベロッパモードを有効にする

iOS 16 以降は端末側の許可がないとアプリを入れられません。有効にしていないと `The application failed to launch` や `no DDI` になります。

1. Mac に USB で接続し、一度 `flutter install` を試す。この時点では失敗します
2. iPad の 設定 → プライバシーとセキュリティ → デベロッパモード をオンにする。この項目は上の操作をするまで表示されません
3. 再起動を求められるので再起動し、ロック解除後のダイアログで オンにする を選ぶ

### 2. Xcode で署名を設定する

初回だけ必要です。無料の Apple ID で構いません。

1. Xcode → Settings → Accounts で Apple ID を登録する
2. `open ios/Runner.xcworkspace`
3. 左のファイル一覧のいちばん上、青いアイコンの Runner を選ぶ
4. 中央の列で **TARGETS の下**の Runner を選ぶ。PROJECT の下ではありません
5. Signing & Capabilities タブで Automatically manage signing にチェックを入れ、Team を選ぶ

Bundle Identifier が使用済みというエラーが出たら、`jp.gitscholar.gitscholar.<自分の識別子>` のように変更します。

### 3. ビルドとインストールを2段階に分ける

`flutter install` は `--dart-define-from-file` を受け付けません。先にビルドで Client ID を埋め込み、その成果物をインストールします。

```bash
flutter devices                                          # 端末IDを確認
flutter build ios --release --dart-define-from-file=env.json
flutter install --release -d <端末ID>
```

インストール後、初回起動時に信頼を求められます。iPad の 設定 → 一般 → VPNとデバイス管理 を開き、デベロッパApp の下にある自分の Apple ID を選んで 信頼 をタップします。これを行うまでアプリは起動できません。

`--release` を使うのは、iOS 14 以降、デバッグビルドが Flutter のツールからしか起動できないためです。ホーム画面のアイコンから使いたい場合は release で入れます。ホットリロードを使いたいときは、接続したまま次を実行します。

```bash
flutter run -d <端末ID> --dart-define-from-file=env.json
```

無料の Apple ID で署名した場合、プロビジョニングの有効期限は約1週間です。期限が切れて起動しなくなったら、上のビルドとインストールを流し直せば復帰します。有料の Apple Developer Program に加入すると1年になり、TestFlight でも配布できます。

なお `flutter` コマンドは `pubspec.yaml` のあるディレクトリで実行します。別の場所で実行すると `No pubspec.yaml file found` になります。

## 組織のリポジトリを使う場合

GitHub の Organization には、サードパーティ製 OAuth App のアクセスを制限する設定があります。制限が有効な組織では、承認するまでその組織のリポジトリが一覧に出ません。エラーは表示されず、単に存在しないように見えます。

承認は組織単位です。オーナーが一度行えばメンバー全員に適用され、利用者ごとの操作は不要です。

1. 組織のページ → Settings
2. Third-party Access → OAuth app policy
3. 一覧から対象のアプリを選び Review
4. Grant access

最初はメンバー1人で試し、承認を求められずにリポジトリが見えることを確認してから全員に案内すると確実です。

制限自体を無効にすることもできますが、その場合はメンバーが認可した任意の OAuth App が組織の非公開データにアクセスできるようになります。制限は残したまま、このアプリだけを承認するほうが安全です。

### 利用者への案内

配布時に伝えるのは次の2点で足ります。

- アプリを開き、GitHub にサインインする。各自のアカウントで、表示されたコードをブラウザに入力する
- 組織のリポジトリが見えない場合は管理者に連絡する。オーナー側で承認する

AI 機能を使う場合は、利用者ごとに提供元の API キーを設定画面で登録します。キーは端末内にのみ保存され、他の利用者とは共有されません。

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
