# GitScholar — AIコーディングエージェント向けガイド

このリポジトリは **GitScholar**（GitHub上の研究資料をiPad/Androidで閲覧・編集し、AIに作業を依頼できるFlutterアプリ）の開発リポジトリです。
設計書は `docs/` にあり、**実装はすべて設計書に従って行う**こと。判断に迷ったら `docs/README.md` の読む順序に沿って該当文書を確認する。

## 最初に読むもの

1. `docs/README.md` — 文書の索引と読む順序
2. `docs/11_implementation_plan.md` — 実装チケット一覧。**作業は必ずチケット単位で進める**
3. 着手するチケットが参照している設計文書

## 作業ルール（要約）

- 1チケット = 1ブランチ = 1PR。チケット番号をブランチ名とコミットメッセージに含める（例: `feat/T-012-ipynb-parser`）。
- チケットの「受け入れ基準」を満たすテストを書き、`flutter analyze` と `flutter test`（および `packages/*` の `dart test`）を通してから完了とする。
- `docs/02_architecture.md` の層構造とディレクトリ規約を守る。層をまたぐ依存（UI→データソース直呼びなど）は禁止。
- 依存パッケージの追加は `docs/02_architecture.md` §6 の一覧にあるものだけ（コード生成は drift と l10n のみ。ADR-0009）。それ以外を追加したい場合は `docs/adr/` にADRを1件追加してから行う。
- 設計書と実装が食い違ったら、実装を直すか、設計書を直してPRに理由を書く。黙って乖離させない。
- 秘密情報（GitHubトークン、Anthropic APIキー）は `flutter_secure_storage` のみに保存し、ログ・DB・ファイルに書かない。
- AIによるファイル変更は必ず「保留中の変更（PendingChange）」を経由し、ユーザー承認なしにGitHubへcommit/pushしない（`docs/07_ai_agent.md` §5）。

## コマンド

```bash
# 初回
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # drift のコード生成
flutter gen-l10n                                            # lib/l10n/*.arb から AppLocalizations を生成

# 検証（PR前に必須）
flutter analyze
flutter test
for p in packages/*; do (cd "$p" && dart pub get && dart test); done
dart format --set-exit-if-changed lib test packages
```

## ディレクトリ

```
lib/            Flutterアプリ本体（feature-first。docs/02_architecture.md §5）
packages/       純Dartパッケージ（nbformat, text_diff, github_api, scholar_agent）
docs/           設計書
docs/adr/       アーキテクチャ決定記録
test/           アプリのテスト
```

## 実装状況（2026-09）

- Phase 0〜3 のチケットは実装済み。Phase 4〜5 は一部のみ実装済み（PDFのマーカーとメモ、Discussion / Issues とリアクション）。正確な状況は `docs/11_implementation_plan.md` の実装状況表を見る。
- UI 文字列を追加したら `lib/l10n/app_ja.arb`（テンプレート、placeholder 定義はこちら）と `app_en.arb` の両方に追加し、`flutter gen-l10n`。
