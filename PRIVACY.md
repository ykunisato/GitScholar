# Privacy Policy for GitScholar

Last updated: 2026-09-17

GitScholar ("the app") is a research workspace for reading and editing files
stored in your own GitHub repositories, with optional assistance from an AI
provider that you choose and pay for directly.

This policy describes what the app does with your information. In short: the
app has no server of its own, and the developer receives no data from it.

## 1. Information the developer collects

**None.** GitScholar does not operate any server, account system, analytics,
crash reporting, advertising, or tracking. The app contains no analytics or
crash reporting software. The developer cannot see who uses the app, which
repositories are opened, or what is typed into it.

## 2. Information stored on your device

The following are stored locally on the device and never sent to the
developer.

| Data | Where it is stored |
|---|---|
| GitHub access token | Operating system secure storage (iOS Keychain, Android EncryptedSharedPreferences) |
| API key for the AI provider you choose | Operating system secure storage |
| Jupyter server token, if you configure one | Operating system secure storage |
| Repository names, branches, file contents you open | Local database and file cache on the device |
| AI conversations, pending edits, app settings | Local database on the device |

Secrets are never written to the local database, to log output, or to files.

## 3. Services the app connects to

The app communicates only with the following, always over HTTPS.

- **GitHub** (`github.com`, `api.github.com`). You sign in with your own
  GitHub account using GitHub's device authorization flow. Sign-in happens in
  your browser, not inside the app. The app reads the repositories your
  account can access. It writes only when you act: creating a commit, posting
  a comment on an issue or discussion, or adding an emoji reaction. File
  changes are held on the device as pending changes and are sent to GitHub
  only when you explicitly commit them.
- **The AI provider you configure**, which may be Anthropic, OpenAI,
  OpenRouter, or any OpenAI-compatible endpoint whose address you enter
  yourself. Requests are sent directly from your device to that provider using
  your own API key. There is no intermediary server.
- **A Jupyter server, only if you configure one**, to run notebook cells.

## 4. What is sent to the AI provider

This is the only category of content that leaves your device to a party other
than GitHub, and it is sent only when you use the AI features.

What may be sent: your messages, the content of the file you have open when
you attach it, text you have selected, extracted text from PDFs you ask about,
the results of read operations the assistant performs inside the repository
you have open, the repository's file listing, and the history of the current
conversation.

What is not sent: the app never uploads an entire repository automatically,
never sends repositories you have not opened, and never sends your GitHub
token or any API key to the AI provider.

You control this in three ways. A `.gitscholarignore` file in the repository
excludes files from ever being sent. Each repository has an AI access setting
of allowed, ask, or denied. For private repositories the app asks for
confirmation before the first message. The AI panel always shows what will be
attached before you send it.

Conversations are stored only on your device. They are not synchronised to any
cloud service.

Your use of an AI provider is governed by that provider's own terms and
privacy policy, including whether they retain or train on the content you
send. Please read the policy of the provider you choose.

## 5. Retention and deletion

Everything the app stores is on your device. Signing out deletes the stored
GitHub token, the AI conversation history, and cached content from private
repositories, and asks you about pending changes. Deleting the app removes all
remaining local data.

To revoke the app's access to your GitHub account, visit
https://github.com/settings/applications and revoke the authorization.

## 6. Children

GitScholar is not directed at children under 13 and is not designed for use by
them.

## 7. Changes to this policy

Changes will be published in this file in the app's public repository, with
the date at the top updated.

## 8. Contact

Please open an issue at https://github.com/ykunisato/GitScholar/issues.

---

# GitScholar プライバシーポリシー

最終更新: 2026-09-17

GitScholar は、自分の GitHub リポジトリにある資料を読み書きするためのアプリです。AI の支援は任意で、利用者が選んだ提供元と直接契約して使います。

**開発者はいかなる情報も収集しません。** 独自のサーバーを持たず、アカウント登録もなく、利用状況の分析や不具合情報の自動送信も行いません。誰が使っているか、どのリポジトリを開いたか、何を入力したかを開発者が知る手段はありません。

端末内には次を保存します。GitHub のアクセストークン、AI 提供元の API キー、Jupyter のトークンは OS の安全な保管領域に入ります。リポジトリの情報、開いたファイルの内容、AI との会話、保留中の変更、設定は端末内のデータベースに保存します。秘密情報をデータベース、ログ、ファイルに書くことはありません。

通信先は、GitHub、利用者が設定した AI 提供元、そして設定した場合のみ Jupyter サーバーの3つだけで、すべて HTTPS です。GitHub への書き込みは利用者の操作によってのみ行われます。ファイルの変更は端末内に保留され、明示的にコミットするまで送信されません。コメントの投稿とリアクションは、押した時点で送信されます。

AI 提供元に送られる可能性があるのは、入力した質問、添付したファイルの内容、選択したテキスト、PDF から抽出した本文、開いているリポジトリ内で AI が読み取った結果、ファイル一覧、そして会話の履歴です。リポジトリ全体を自動で送ることはありません。GitHub のトークンや API キーを AI 提供元に送ることもありません。送信内容は `.gitscholarignore` で除外でき、リポジトリごとに許可、確認、禁止を設定できます。非公開リポジトリでは最初の送信前に確認します。送信される内容は画面に常時表示されます。

送信した内容が提供元でどう扱われるかは、その提供元の規約とプライバシーポリシーによります。利用前にご確認ください。

保存先はすべて端末内です。サインアウトするとトークン、会話履歴、非公開リポジトリのキャッシュが削除されます。アプリを削除すれば残りも消えます。GitHub 側での認可の取り消しは https://github.com/settings/applications から行えます。

13歳未満の利用を想定していません。問い合わせは https://github.com/ykunisato/GitScholar/issues へお願いします。
