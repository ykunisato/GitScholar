# 05. ビューア仕様

共通: すべてのビューアは `ViewerWidget(file: FileContent, openFile: OpenFile)` として `lib/presentation/viewers/viewer_dispatcher.dart` から `FileKind` により選択される。ビューアは以下を提供する。

- `selectionProvider` への選択テキスト通知（AIコンテキスト用、FR-62）
- 「AIに聞く」コンテキストメニュー（選択範囲があればそれを添付）
- 読み込み中・エラー・巨大ファイルの共通表示（`FileKind.binary` や上限超過は `UnsupportedFileView`）

サイズ上限（超過時は `UnsupportedFileView` で「ブラウザで開く」）: PDF 100MB、Notebook 50MB、Markdown/コード/テキスト 5MB、画像 20MB。

## 1. PDF（`presentation/viewers/pdf/`）

`pdfrx` の `PdfViewer.data()` を使う（バイト列から。ファイルパス経由にしない）。

| 機能 | 仕様 |
|---|---|
| 表示 | 縦連続スクロール、ピンチズーム、ダブルタップでフィット切替 |
| ページ移動 | ページ番号入力、スライダー。現在ページを `OpenFile.pdfPage` に反映 |
| 検索 | `PdfTextSearcher` でインクリメンタル検索、ヒット件数と前後移動、ハイライト |
| テキスト選択 | `pdfrx` の選択機能。選択テキストを `selectionProvider` に流す。選択メニューは `buildContextMenu` で自前のものに差し替え、「コピー」「AIに聞く」「マーカー4色」を出す。pdfrx 既定の `AdaptiveTextSelectionToolbar` はビューア内部のStackで `MaterialLocalizations` を解決できず例外になるため使わない |
| マーカー | 選択範囲に4色のハイライトを付ける（FR-90）。行ごとの矩形をページ座標で `<pdf名>.annotations.json` に保存し、`pagePaintCallbacks` で描画。一覧から該当ページへ移動・削除 |
| メモ | ビューア下部の入力バーに書いた内容を `<pdf名>.md` の末尾に追記する（FR-96）。ファイルが無ければ見出しとPDFへのリンクを付けて新規作成。選択範囲があれば引用として添える |
| 目次 | アウトラインがあればドロワーで表示 |
| 位置の記憶 | ファイル（sha）ごとに最後のページを `key_value` に保存 |
| AIコンテキスト | 全文テキスト（`PdfDocument.pages[i].loadText()` を全ページ）を抽出して渡す。50ページを超える場合は選択範囲 or 現在ページ±5ページ + 目次、と「全文を添付」トグル |

注釈は `Stack` の上に重ねる構造で実装する。ハイライトはページ描画コールバックで塗り、手書き注釈（ink）は今後この層に追加する。

注釈ファイルとメモファイルは通常のリポジトリファイルなので、保存は保留中の変更になり、コミットは通常どおりユーザーの操作で行う。

## 2. Markdown（`presentation/viewers/markdown/`）

`markdown` パッケージで `ExtensionSet.gitHubWeb` を使いパース、`markdown_widget` で描画する。

| 要素 | 仕様 |
|---|---|
| 見出し | `#`〜`######`。目次ボタンで見出し一覧を表示しジャンプ |
| コードブロック | `re_highlight` で言語別ハイライト。コピー用ボタン |
| 数式 | `$...$`（インライン）、`$$...$$`（ブロック）を `flutter_math_fork` で描画。パース失敗時はソースをモノスペース表示 |
| 表 | 横スクロール可能 |
| リンク | 相対パス（`./notes/x.md`, `../paper.pdf`）はリポジトリ内ファイルとして解決し、タップでそのファイルを開く。`http(s)` は `url_launcher`。 |
| 画像 | 相対パスはワークスペース経由で `LoadFile` して表示。`http(s)` はネットワーク画像 |
| フロントマター | 先頭の `---` YAML はそのまま折りたたみ可能なブロックとして表示（Quarto/Rmd対応） |
| チェックボックス | 表示のみ（編集はエディタで） |

`.qmd` / `.Rmd`: 表示はMarkdownビューアで行うが、` ```{r} ` / ` ```{python} ` のチャンクは通常のコードブロックとして言語ハイライトする。

## 3. Notebook（`presentation/viewers/notebook/`）

`packages/nbformat` でパースし、セルごとに `ListView.builder` で遅延ビルドする（NFR-13）。

```text
NotebookView
├─ NotebookToolbar    (カーネル情報、セル数、[実行]系ボタンはPhase 3)
└─ ListView.builder
   └─ CellView (index)
      ├─ CellGutter    (実行番号 [n] / In [ ] / 種別バッジ)
      ├─ CellSource
      │    ├─ MarkdownCell → MarkdownBody（§2と同じレンダラ）
      │    ├─ CodeCell     → CodeBlock（言語は metadata.kernelspec.language or language_info.name）
      │    └─ RawCell      → モノスペース
      └─ OutputList (CodeCellのみ)
           └─ OutputView × n
```

### 3.1 出力の描画

MIME優先順位: `image/png` > `image/jpeg` > `image/svg+xml` > `text/html` > `text/markdown` > `text/latex` > `application/json` > `text/plain`。

| 出力 | 描画 |
|---|---|
| `stream` | モノスペース。`stderr` は赤系背景。10,000行超は先頭/末尾各500行と「すべて表示」 |
| `error` | `ename: evalue` を赤で。`traceback` はANSIエスケープを除去して表示（`ansi_stripper.dart`）。折りたたみ可 |
| `image/png`, `image/jpeg` | base64デコード→`Image.memory`。タップで拡大 |
| `image/svg+xml` | `flutter_svg` は依存一覧外なので、WebView（JS無効）で表示。Phase 1 では「SVG（WebViewで表示）」ボタン |
| `text/html` | §3.2 のサンドボックスWebView。既定は折りたたみ状態で「HTMLを表示」ボタン |
| `text/markdown` | Markdownレンダラ |
| `text/latex` | `flutter_math_fork`。失敗時はソース表示 |
| `application/json` | 整形してモノスペース |
| `text/plain` | モノスペース。pandas の `text/plain` 表は等幅で崩れないよう横スクロール |

### 3.2 HTML出力のサンドボックス（FR-37, NFR-32）

- `webview_flutter` を `javaScriptMode: JavaScriptMode.disabled` で生成し、`loadHtmlString` で表示する。`baseUrl` は設定しない。
- `NavigationDelegate.onNavigationRequest` で **すべての外部ナビゲーションを拒否**する。
- 表示前に `<script>` タグと `on*=` 属性を除去する（`html_sanitizer.dart`、正規表現ベースの簡易処理。厳密な安全性はJS無効化が担保する）。
- ユーザーが出力ごとに「JavaScriptを有効にして表示」を選んだ場合のみ、確認ダイアログの後 `JavaScriptMode.unrestricted` で再表示する。外部ナビゲーションの拒否は維持する。
- WebViewの高さは内容に合わせる（`window.document.body.scrollHeight` はJS無効では取れないため、既定 300dp、ドラッグハンドルで変更可）。

### 3.3 表示メタデータ

- `metadata.collapsed` / `jupyter.source_hidden` / `jupyter.outputs_hidden` を尊重し、折りたたんで表示する。
- セルの `metadata.tags` をバッジ表示。

## 4. コード・テキスト（`presentation/viewers/code/`）

`re_editor` の `CodeEditor` を `readOnly: true` で使う。言語は拡張子から `re_highlight` の言語定義を選ぶ（`language_map.dart`）。行番号表示、折り返しトグル、フォントサイズ設定、検索（Cmd/Ctrl+F）。編集モードは 06 参照。

## 5. 画像（`presentation/viewers/image/`）

`InteractiveViewer` + `Image.memory`。SVGは §3.1 と同じくWebView（JS無効）。

## 6. `packages/nbformat` パーサ仕様

```dart
Notebook parseNotebook(String json);          // ValidationFailure相当の NbformatException を投げる
String serializeNotebook(Notebook nb, {String indent = ' '});   // Jupyter互換の整形（1スペースインデント、キー順を維持）
```

- 受理: `nbformat == 4`。`nbformat_minor` は 0〜5 を受理し、それ以上も警告なしで受理する。
- `cells[].source`、`outputs[].text`、`data[mime]` は `String | List<String>` を受理し、結合して保持。
- `outputs[].data[mime]` で `application/json` 系（`application/vnd.*+json` を含む）はJSON値のため、`jsonEncode` した文字列として保持する。
- `cell.id` が無い場合は生成しない（nbformat 4.5 未満のまま保存する）。4.5 以上で無ければ8文字の英数字を生成する。
- ラウンドトリップテスト: `test/fixtures/*.ipynb` を parse → serialize → parse して等価であること。`jsonDecode` レベルでの等価（キー順は問わない）。
- fixtures には最低限: 空Notebook、Markdownのみ、画像出力あり、error出力あり、HTML出力あり（pandas DataFrame）、stream 大量、`source` が文字列形式のもの、nbformat 4.4（id無し）と 4.5（id有り）。
