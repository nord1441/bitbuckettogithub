# bitbuckettogithub

Bitbucket Cloud (Free) のワークスペースに含まれる全リポジトリを
GitHub (Free) に一括移行する **shell スクリプト** です。
**プライベートリポジトリはプライベートのまま**、Git LFS にも対応します。

## できること

- ワークスペース配下の全リポジトリの **Git 履歴 / 全ブランチ / 全タグ** を移送
- リポジトリの **`is_private` (公開/非公開)** をそのまま引き継ぎ
- Git **LFS オブジェクト** の同期 (`git-lfs` がインストール済みの場合)
- 既に存在するリポジトリへの追加 push (デフォルト) または スキップ (`SKIP_EXISTING=1`)
- 計画のみ表示 (`DRY_RUN=1`)

移行対象外: Pull Request / Issue / Pipelines / Wiki / Webhook など。

## 必要なもの

- **bash** (4 以上)、**curl**、**jq**、**git**
- **git-lfs** (LFS リポジトリを扱う場合のみ)
- **Bitbucket の認証** — 以下の **どちらか** を用意:
  - **(A) SSH 鍵 (推奨)** — Bitbucket に公開鍵を登録してあれば一番楽です。
    `BB_GIT_SSH=1` を設定するとgitの clone/push は ssh で行います。
    REST API 用には別途 token が必要 (種類は不問: Atlassian API token でも可)。
  - **(B) Bitbucket Workspace Access Token** — `https://bitbucket.org/<workspace>/workspace/settings/access-tokens`
    から発行。権限: **Repositories: Read** (必須) / **Account: Read** (推奨)。
    HTTPS で clone/push するならこちらを使ってください。
  - 注: Atlassian アカウントの API token (id.atlassian.com) は **REST API
    専用** で、git over HTTPS では使えません ([詳細](#atlassian-api-token-では-clone-できない))。
- **GitHub Personal Access Token (Classic 推奨)**
  - スコープ: `repo` (フル)。Org に作成する場合は `admin:org` も推奨

## 使い方

### SSH で git 転送する場合 (推奨)

```bash
# 0. SSH 鍵を Bitbucket に登録済みであること
ssh -T git@bitbucket.org    # → "logged in as ..." が出れば OK

# 1. 環境変数
export BB_WORKSPACE="my-bb-team"
export BITBUCKET_API_TOKEN="ATATT3xFf..."   # API token (REST 用なら何でも可)
export BITBUCKET_EMAIL="alice@example.com"  # Atlassian API token を使うなら必要
export GITHUB_TOKEN="ghp_xxxxxxxx"
export BB_GIT_SSH=1                         # ← これで git は ssh 経由

./migrate.sh
```

### HTTPS だけで完結させる場合

```bash
export BB_WORKSPACE="my-bb-team"
export BITBUCKET_API_TOKEN="<Workspace Access Token>"
export GITHUB_TOKEN="ghp_xxxxxxxx"

./migrate.sh
```

### オプション

```bash
# export GH_ORG="my-gh-org"          # 指定すると Org 直下に作成
# export WORK_DIR="/var/tmp/bb2gh"   # 一時 mirror clone の置き場
# export DRY_RUN=1                   # 実行せず計画のみ
# export SKIP_EXISTING=1             # 既存 GitHub repo はスキップ
# export OVERWRITE_EXISTING=1        # 既存 GitHub repo を削除→再作成→push
```

`SKIP_EXISTING` と `OVERWRITE_EXISTING` は排他です(両方 1 にすると起動時に拒否)。

### `OVERWRITE_EXISTING=1` を使う場合の注意

破壊的操作なので、以下を必ず確認してください。

- **GITHUB_TOKEN に `delete_repo` スコープが必要** です。
  Classic PAT を再発行する際にチェックを入れるか、
  Fine-grained では "Administration: Read and write" 相当を付与してください。
- 既存リポジトリの **Issue / PR / Star / Watcher / Release / Webhook** などは
  削除と同時に **すべて失われます**。
- 削除されたリポジトリは GitHub の UI 経由でのみ
  90 日以内に Restore 可能ですが、本ツールでは復元しません。

スクリプトは起動時に Bitbucket の認証方式 (Bearer / Basic / x-token-auth) を
自動判別します。`BITBUCKET_API_TOKEN` だけ渡せば最初は Bearer で叩き、
401 が返れば順に Basic, x-token-auth と試行します。

## 動作の流れ (リポジトリ毎)

1. `GET /repos/<owner>/<slug>` で GitHub 側の存在確認
2. 無ければ `POST /user/repos` または `POST /orgs/<org>/repos` で作成
   (`private` は Bitbucket 側の `is_private` をそのまま設定)
3. `git clone --mirror` で Bitbucket からベアミラーを取得
4. `git lfs fetch --all` で LFS オブジェクトを取得 (LFS 不使用なら no-op)
5. `git push --mirror` で GitHub へ全 ref / branch / tag を送出
6. `git lfs push --all` で LFS オブジェクトを送出

URL には `https://USER:TOKEN@host/...` 形式で資格情報を埋め込みます。
ディスク上には資格情報を保存しません (`WORK_DIR` 内のミラーは bare repo のみ)。

## ログの読み方

```
[info]  通常の進捗・状態
[step]  実際に実行する HTTP / git コマンド
[warn]  続行はするが注意が必要な事象
[error] リポジトリ単位の失敗 (他リポジトリは続行)
```

終了コード 0 = 全成功 / 1 = 1件以上失敗。

## トラブルシューティング

### Atlassian API token では clone できない

REST API には通るのに、各リポジトリの clone で
`fatal: Authentication failed for 'https://bitbucket.org/.../...git/'`
が出るパターンです。

**原因:** Atlassian アカウント側の API token (id.atlassian.com で作るもの) は
`api.bitbucket.org` の REST API には使えますが、`bitbucket.org` の
**git smart protocol では認証情報として受け付けてもらえません**。

**対処:** Bitbucket UI で **Workspace Access Token** を発行して使ってください。

```
https://bitbucket.org/<workspace>/workspace/settings/access-tokens
  → Create access token
  → Repositories: Read (必須) / Account: Read (推奨)
```

このトークンを `BITBUCKET_API_TOKEN` に設定し、`BITBUCKET_EMAIL` は
**unset / 空** にして再実行すれば通ります。

スクリプトは起動時に git 転送のプリフライト
(`git ls-remote` を最初の1リポジトリに対して実行) を行い、ここで失敗した
場合は同じ案内を出して全体を中断します。

### `could not authenticate to Bitbucket`

- Atlassian API token を使っているなら、**スコープ付き API token** が必要
  - <https://id.atlassian.com/manage-profile/security/api-tokens>
  - **"Create API token with scopes"** を選び、`read:account` と
    `read:repository:bitbucket` を含める
- Bitbucket 側で Workspace Access Token を発行する場合は
  `Account: Read` + `Repositories: Read` を付与
- `BITBUCKET_EMAIL` を設定しても効果が無いときは、Bearer 認証のみで通る token です
  (スクリプトは自動的に切替えます)

### `Bitbucket workspace 'xxx' is not accessible (HTTP 404)`

`BB_WORKSPACE` の slug が間違っている可能性が高いです:

```bash
# 自分がアクセスできる workspace 一覧を確認
curl -s -H "Authorization: Bearer $BITBUCKET_API_TOKEN" \
  https://api.bitbucket.org/2.0/workspaces \
  | jq -r '.values[].slug'
```

### `git: 'lfs' is not a git command`

`git-lfs` をインストールしてください:

```bash
# Debian/Ubuntu
sudo apt-get install git-lfs && git lfs install
# macOS
brew install git-lfs && git lfs install
```

未インストールでも LFS 以外の移行は通常通り完走します (LFS は警告のみ)。

## 注意

- `BITBUCKET_API_TOKEN` / `GITHUB_TOKEN` はシェル履歴に直接書かないでください
  (`direnv` などの利用を推奨)
- GitHub Free の **LFS 帯域 / 容量上限** に注意 (1 GB / 1 GB 帯域・月)
- `WORK_DIR` には全リポジトリ容量分の空きを確保
