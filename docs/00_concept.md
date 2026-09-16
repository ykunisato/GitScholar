# 00. GitScholar 構想（原典）

> 本文書はプロダクトオーナーが作成した構想文書をそのまま収録したものである。要件の正本は [01_requirements.md](01_requirements.md) であり、本文書と食い違う場合は 01 を優先する。

## 概要

**GitScholar**は、GitHubリポジトリ上の研究資料をiPad・Android端末から閲覧、編集、管理し、AIエージェントに作業を依頼できるクロスプラットフォーム型の研究ワークスペースである。単なるGitクライアントやPDFリーダーではなく、PDF、Markdown、Jupyter Notebook、R・Pythonコード、Quarto文書などを、ひとつの研究プロジェクトとして扱うことを目指す。

> **GitScholar = GitHub + Research Viewer + AI Research Agent**

## 背景と課題

GitHubでPDFや研究ノートを管理し、iPadから閲覧する方法としてWorking Copyは有力だが、研究用途では次の課題が残る。

- 一部の編集・書き込み機能が有料
- `.ipynb`の閲覧体験が十分ではない
- PDF、Notebook、Markdown、コードを横断して扱いにくい
- AIにファイルの説明や修正を依頼する機能がない
- iPad中心で、Androidとの共通運用が難しい

## 想定ユーザー

- GitHubで論文、分析コード、Notebook、研究ノートを管理する研究者
- iPadやAndroidタブレットで研究資料を読みたい人
- PDFと分析コードを同じプロジェクト内で扱いたい人
- 移動中や学会先からAIに研究作業を依頼したい人
- 学生との共同研究やゼミ資料をGitHubで管理する教員

## 基本コンセプト

```text
GitHub repository
        │
        ▼
┌─────────────────────────────────────┐
│ GitScholar (iPad / Android)         │
├─────────────────────────────────────┤
│ File Browser                        │
│ PDF / Markdown / Notebook / Code    │
│ Search / Metadata / Annotation      │
│ GitHub Sync / Diff / Commit         │
│ AI Agent                            │
└─────────────────────────────────────┘
        │
        ▼
Remote execution environment
JupyterHub / Python / R / Quarto
```

GitHubを意識せず資料を読める簡潔さと、必要なときにはdiffやcommitを確認できる透明性を両立させる。

## 対応する主要ファイル

| 種類 | 主な機能 |
|---|---|
| PDF | 表示、検索、ハイライト、注釈、AIへの質問 |
| Markdown | レンダリング、編集、リンク表示 |
| `.ipynb` | セル単位の表示、出力表示、編集 |
| `.py` / `.R` | シンタックスハイライト、編集、AI修正 |
| `.qmd` / `.Rmd` | 表示、編集、リモートレンダリング |
| BibTeX / YAML | 文献・メタデータの表示と編集 |
| 画像・表 | プレビュー、Notebook出力内での表示 |

## AIエージェント機能

AIは、単なるチャットや要約機能ではなく、リポジトリを読み、編集し、検証できる研究エージェントとする。

利用例:
- 「この論文を500字で要約して」
- 「選択した数式をActive Inferenceの観点から説明して」
- 「このNotebookのエラーを修正して」
- 「この解析を階層ベイズモデルに変更して」
- 「このリポジトリ内でprecisionとpersonalityを扱う資料を探して」
- 「分析を実行し、結果を確認してから変更案を示して」

AIに提供するツール: `read_file`, `write_file`, `search_repo`, `show_diff`, `git_commit`, `run_python`, `run_R`, `render_quarto`

安全な作業フロー: 依頼 → 関連ファイル調査 → 変更案作成 → リモート環境で実行・検証 → diff提示 → ユーザー承認 → commit / push。AIによる書き換えは、原則としてdiff確認と承認を経て反映する。

## Git・GitHub連携方針

MVPでは完全なGitクライアントを端末内に実装せず、GitHub APIを利用する。GitHub OAuth → Repository選択 → Tree・ファイル取得 → 閲覧・編集 → Diff確認 → Commit。将来的に branch、pull request、conflict解決、ローカルclone、GitHub以外のホスティングへ拡張する。

## UI設計

タブレット横画面は3ペイン（Repository / Viewer・Editor / AI）。スマートフォンではFiles、Viewer、AIをタブまたはボトムシートで切り替える。

設計原則:
- 閲覧中の資料を閉じずにAIへ質問できる
- AIが参照しているファイルや選択範囲が分かる
- 変更前後のdiffを明確に確認できる
- Gitに詳しくない利用者でも基本操作ができる
- タブレットの大画面とペン入力を活かす

## MVP

1. GitHubログイン 2. Repository選択 3. ファイルツリー表示 4. PDF表示 5. Markdown表示 6. `.ipynb`表示 7. テキスト・コード編集 8. 変更diff表示 9. commit / push 10. 開いているファイルについてAIに質問

## 開発ロードマップ

- Phase 1：閲覧中心のMVP（OAuth、ブラウザ、各ビューア、キャッシュ、単一ファイルAI質問）
- Phase 2：編集とGitHubへの反映（編集、diff、commit/push、AI編集、承認フロー）
- Phase 3：研究実行環境との接続（JupyterHub、Python/R実行、Notebook出力更新、Quarto render）
- Phase 4：研究ライブラリ化（PDF注釈、全文検索、RAG、BibTeX/Zotero、メタデータ）
- Phase 5：共同研究機能（branch/PR、レビュー、権限、共有ワークスペース）

## 推奨リポジトリ構成例

```text
research-project/
├── papers/Safron2021/{paper.pdf, metadata.yaml}
├── notes/Safron2021.md
├── notebooks/analysis.ipynb
├── analysis/{model.R, simulation.py}
├── manuscript/paper.qmd
├── references.bib
└── README.md
```

```yaml
title: Integrating Cybernetic Big Five Theory with the free energy principle
authors: [Adam Safron, Colin G. DeYoung]
year: 2021
tags: [active-inference, personality, CB5T]
status: read
rating: 5
```

## 重要な設計判断（検討課題）

- GitHub API方式から完全なGit実装へ、どの段階で移行するか
- PDF注釈をPDF本体へ保存するか、別ファイルとして管理するか
- AI処理を端末、独自サーバー、外部APIのどこで行うか
- private repositoryのデータをAIへ渡す際のプライバシー設計
- JupyterHubへの認証と実行環境の分離
- 大容量PDFや巨大リポジトリのキャッシュ戦略
- NotebookのHTML・JavaScript出力をどこまで安全に表示するか
- AIが変更・実行・commitできる権限の境界
- App Store・Google Playの課金モデル

## プロダクトの短い説明

> GitScholarは、GitHub上の論文、Notebook、研究ノート、分析コードをiPad・Androidで閲覧・編集し、AIに分析や修正を依頼できる研究者向けワークスペースです。

> GitScholar is a GitHub-based research workspace for reading, editing, and working with papers, notebooks, notes, and code on iPad and Android—with an AI agent that can understand and act on your repository.
