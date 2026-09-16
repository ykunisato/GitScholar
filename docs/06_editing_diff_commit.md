# 06. 編集・diff・commit

対象: `lib/application/editing/`, `lib/presentation/editing/`, `packages/text_diff`。

## 1. 編集モデル

- 編集は **常にファイル単位の「保留中の変更（PendingChange）」** として表現する。ビューアは `LoadFile` を通じて pending の内容を透過的に見る（03 §1.4）。
- 編集モードのエディタは内容をメモリに持ち、変更があれば **1秒のデバウンス**で `SavePendingChange` を呼ぶ（FR-41）。アプリがバックグラウンドに入る時（`AppLifecycleState.paused`）にも即時保存する。
- 内容が `baseBlob` と一致した（元に戻した）場合、その PendingChange は自動的に削除する。
- 同じパスの PendingChange は1件だけ（upsert）。

### 1.1 テキスト・コード・Markdown

- `re_editor` の `CodeEditor`（`readOnly: false`）。表示ビューアと同じウィジェットを編集可能にする。
- 改行コードは元ファイルのものを保持する（`\r\n` を検出したら保存時に戻す）。末尾改行の有無も保持する。
- エンコーディングはUTF-8のみ。デコード失敗ファイルは編集不可（`FileKind.binary`）。
- Markdown（タブレット）: 「編集」「プレビュー」「分割」の3モード（FR-36）。分割はエディタ左・プレビュー右、スクロール同期はしない（SHOULD で後回し）。

### 1.2 Notebook（FR-42）

- セル単位の編集: セルをタップ → そのセルが `re_editor` に切り替わる（Markdownセルはレンダリング→ソース）。フォーカスを外すとレンダリングに戻る。
- ツールバー: セル追加（上/下）、削除、上へ/下へ移動、種別変更（code ⇄ markdown）、出力クリア。
- 保存はNotebook全体を `serializeNotebook` してPendingChangeにする。**出力・metadata・execution_countは変更しない**（ソース編集のみ。出力を消すのは明示操作）。
- 未対応の編集（raw セルの作成、attachments）は行わない。

### 1.3 ファイル操作（FR-47）

- 新規作成: ファイルツリーの「+」→ パス入力 → `ChangeKind.create` の空ファイル。
- 削除: `ChangeKind.delete`。ツリーでは取り消し線表示。
- リネーム: `ChangeKind.rename`（`oldPath` → `path`）。内容変更を伴う場合も1つのPendingChangeで表す。

PDFのマーカー（`<pdf名>.annotations.json`）とメモ（`<pdf名>.md`）も専用の保存先を持たず、通常のファイル編集として扱う。保存すると `PendingChange` になり、変更一覧に並び、コミットは他の編集と同じ操作で行う（ADR-0008, ADR-0011）。

## 2. diff（`packages/text_diff`）

行単位の Myers 差分（O(ND)）を実装する。

```dart
enum DiffOp { equal, insert, delete }
class DiffLine { DiffOp op; String text; int? oldLineNo; int? newLineNo; }
class Hunk { int oldStart, oldCount, newStart, newCount; List<DiffLine> lines; }

List<DiffLine> diffLines(String a, String b);                 // 全行
List<Hunk> toHunks(List<DiffLine> lines, {int context = 3});
String toUnified(List<Hunk> hunks, {required String oldPath, required String newPath});
DiffStats stats(List<DiffLine> lines);                          // added, deleted
```

- 行分割は `\n` 基準、`\r\n` は `\n` に正規化してから比較（表示用。保存内容は 1.1 の通り保持）。
- 入力が 20,000 行を超える場合は差分計算を打ち切り、「大きすぎるため差分を省略」を返す（`DiffTooLarge` 例外）。UI側は全文表示にフォールバック。
- バイナリ（デコード不可）は「バイナリファイルが変更されました（サイズ a → b）」のみ。
- Notebook の diff は **シリアライズ後のJSONの行diff** ではなく、セル単位の意味的diffを表示する: パースした両Notebookをセル `id`（無ければ順序）で対応付け、追加/削除/変更セルを列挙し、変更セルの `source` を行diffする。出力の変更は「出力が更新されました」とだけ表示する。実装は `lib/application/editing/notebook_diff.dart`。

テスト: 既知の入出力（空→空、追加のみ、削除のみ、置換、末尾改行の有無、共通部分なし）、ランダム生成した文字列に対して `apply(diff) == b` が成り立つプロパティテスト。

## 3. commit / push（FR-45）

### 3.1 UI フロー

```text
[変更] タブ
├─ 保留中の変更一覧（ファイルごとに +n/-m、origin=ai はバッジ、upstream_changed は警告アイコン）
├─ 各行タップ → diff 画面（unified / side-by-side（タブレットのみ）切替、破棄ボタン）
└─ [コミット] ボタン
     → CommitSheet
        ├─ 対象ファイルのチェックボックス（既定: すべて。status=proposed は含めない）
        ├─ コミットメッセージ（1行目 + 本文。AIに「メッセージを提案」ボタン：diffを渡して生成）
        ├─ ブランチ表示（Phase 2 SHOULD: 新規ブランチ名入力）
        └─ [コミットしてプッシュ]
```

### 3.2 `CommitChanges(changeIds, message, {newBranch?})`

```text
1. 対象 PendingChange を取得。status != pending があれば ValidationFailure
2. GET git/ref/heads/{branch} → remoteHead
3. remoteHead == workspace.baseCommitSha なら parent = remoteHead、baseTree = workspace.treeSha
   そうでなければ §4 の競合検査を実行して parent/baseTree を決める
4. 04 §4 に従い commit を作成し ref を更新
5. 成功後（トランザクション）:
   - 対象 PendingChange を削除
   - workspaces.base_commit_sha = newCommitSha, tree_sha = newTreeSha
   - tree_entries の該当 path を更新（create/modify: 新sha、delete: 削除、rename: 旧削除・新追加）
     ※ ツリー全体の再取得はしない。次回 RefreshWorkspace で整合する
   - BlobStore には既にローカルSHAで保存済み（03 §3）
6. 残った PendingChange（対象外）は baseCommitSha を newCommitSha に付け替える
7. UIに「コミットしました <short sha>」とGitHubで開くリンク
```

- オフライン時は `NetworkFailure` を表示し、変更は保持する（NFR-20）。
- 途中失敗（blob作成後にref更新で失敗など）はGitHub上にゴミオブジェクトが残るが害はない。ローカル状態は変更しない。

## 4. 競合処理（FR-46）

remoteHead ≠ baseCommitSha のとき:

```text
1. GET git/commits/{remoteHead} → remoteTreeSha
2. GET git/trees/{remoteTreeSha}?recursive=1 → remoteTree（このタイミングでワークスペースも更新する）
3. 各対象 PendingChange について remoteTree の同 path の sha を取得し、
   - modify: remoteSha == baseBlobSha なら安全。異なれば競合
   - create: remote に存在しなければ安全。存在すれば競合
   - delete: remoteSha == baseBlobSha なら安全。異なる or 既に無ければ競合（無ければ変更を捨てて成功扱い）
   - rename: 旧pathがmodify相当、新pathがcreate相当として判定
4. 競合ゼロ → parent = remoteHead, baseTree = remoteTreeSha で §3.2 手順4へ（自動リベース相当）
5. 競合あり → ConflictFailure(conflictingPaths) を投げ、UIで ConflictSheet:
   a. 「リモートの内容を確認」→ 3ペインdiff（ベース / 自分 / リモート）を表示。ユーザーはエディタで手動マージ後、再度コミット
   b. 「自分の変更で上書き」→ baseBlobSha を remoteSha に付け替え、parent = remoteHead で再実行
   c. 「自分の変更を破棄」→ PendingChange を削除
   競合していないファイルだけ先にコミットする選択肢も出す
```

`force: true` の ref 更新は **絶対に使わない**。

## 5. 新規ブランチへのコミット（FR-48）

CommitSheet で `newBranch` が指定された場合、`POST git/refs {ref: refs/heads/<newBranch>, sha: parent}` を先に実行し、以後そのブランチに対して §3.2 を行う。成功後 workspace.branch を切り替える。
