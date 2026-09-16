# 10. テスト・品質

## 1. テストの層

| 層 | 対象 | ツール | 場所 |
|---|---|---|---|
| 純Dartユニット | `packages/*`（パーサ、diff、APIクライアント、SSE、エージェントループ） | `package:test`, `http.MockClient` | `packages/<name>/test/` |
| アプリユニット | Domain services、Application ユースケース、Infrastructure（drift はインメモリ `NativeDatabase.memory()`） | `flutter_test`, `mocktail` | `test/` (lib と同じ階層) |
| ウィジェット | 各ビューア、AgentPane、ChangesScreen、CommitSheet | `flutter_test`, `ProviderScope(overrides)` | `test/presentation/` |
| ゴールデン | Notebook/Markdown の描画（主要fixture） | `flutter_test` の `matchesGoldenFile` | `test/goldens/` |
| 手動のみ | PDF ビューア（pdfrx） | ネイティブの pdfium と `path_provider` が必要で、`flutter_test` では `MissingPluginException` になる。実機・シミュレータで確認する | `docs/manual_test_checklist.md` |
| 統合 | UC-1〜UC-3 の主要経路（GitHub / Anthropic はローカルのフェイクHTTPサーバー） | `integration_test` | `integration_test/` |
| 手動 | 実機での性能（NFR-1x）、オフライン（NFR-20）、アクセシビリティ | チェックリスト | `docs/manual_test_checklist.md`（Phase 1 末に作成） |

## 2. フェイクとフィクスチャ

- `test/fakes/fake_github.dart`: `GitHubRepository` を実装したインメモリの Git（blobs / trees / commits / refs）。Git Data API と Contents API の意味論（fast-forward 検査、sha 不一致の競合）を再現する（ADR-0009）。HTTP の形は `packages/github_api/test` で検証する。
- `test/fakes/fake_anthropic.dart`: 台本（scripted）方式。「このリクエストが来たらこのSSEイベント列を返す」を定義できる。`tool_use` を返して次のリクエストで `tool_result` を検証する。
- `test/fixtures/`: `.ipynb`（05 §6）、`.md`（GFM要素、数式、相対リンク）、小さい `.pdf`（テキスト抽出可能なもの、2ページ）、Git ツリーJSON。

## 3. CI（`.github/workflows/ci.yml`）

```yaml
on: [push, pull_request]
jobs:
  analyze-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2   # .fvmrc のバージョン
      - run: flutter pub get
      - run: dart run build_runner build --delete-conflicting-outputs
      - run: flutter gen-l10n
      - run: dart format --set-exit-if-changed lib test packages
      - run: flutter analyze
      - run: flutter test --coverage
      - run: for p in packages/*; do (cd "$p" && dart pub get && dart test --coverage=coverage); done
      # カバレッジ閾値（packages 80%）は lcov を集計するスクリプト tool/check_coverage.dart で判定
  build-android:
    needs: analyze-test
    runs-on: ubuntu-latest
    steps: [checkout, flutter-action, flutter build apk --debug]
  build-ios:
    needs: analyze-test
    runs-on: macos-latest
    steps: [checkout, flutter-action, flutter build ios --no-codesign --debug]
```

## 4. コーディング規約

- `analysis_options.yaml`: `flutter_lints` + 追加ルール `prefer_final_locals`, `avoid_dynamic_calls`, `unawaited_futures`, `require_trailing_commas`, `always_declare_return_types`, `public_member_api_docs`（`packages/*` のみ）。
- ファイル名 snake_case、クラス PascalCase、Provider は `xxxProvider`（生成）。
- 1ファイル 400 行を目安。超えたら分割。
- コメントは「なぜ」を書く。設計書の該当節を `// See docs/06_editing_diff_commit.md §4` の形で参照する。
- `print` 禁止（`AppLogger` を使う）。
- `// ignore:` は理由を同じ行に書く。
- `TODO(T-xxx):` の形式でチケット番号を付ける。

## 5. Definition of Done（チケット完了条件）

1. チケットの受け入れ基準をすべて満たす。
2. 該当するユニット/ウィジェットテストを追加し、CIが緑。
3. `flutter analyze` 警告ゼロ、`dart format` 済み。
4. 設計書との乖離がない。乖離させた場合は設計書を更新しPRに理由を書く。
5. UIに文字列を追加した場合は `app_ja.arb` と `app_en.arb` の両方に追加。
6. 秘密情報がログ・DB・ファイルに出ていない。
7. PR説明に: チケットID、変更概要、テスト方法、スクリーンショット（UI変更時）。

## 6. PR・コミット

- ブランチ: `feat/T-012-short-name`, `fix/T-034-...`, `docs/...`。
- コミットメッセージ: `T-012: ipynb パーサを追加`（1行目 72 文字以内、必要なら本文）。
- 1PR = 1チケット。大きいチケットはサブチケット（`T-012a`, `T-012b`）に割る。
