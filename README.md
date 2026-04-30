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
- **Bitbucket の API token** (Atlassian アカウントの API token、もしくは
  Bitbucket UI で発行する Workspace/Project/Repository Access Token のいずれか)
  - スコープ:
    - Atlassian API token: `read:account`, `read:repository:bitbucket`
    - Bitbucket Access Token: `Account: Read`, `Repositories: Read`
- **GitHub Personal Access Token (Classic 推奨)**
  - スコープ: `repo` (フル)。Org に作成する場合は `admin:org` も推奨

## 使い方

```bash
# 必須
export BB_WORKSPACE="my-bb-team"            # Bitbucket workspace slug
export BITBUCKET_API_TOKEN="ATATT3xFf..."   # Bitbucket / Atlassian token
export GITHUB_TOKEN="ghp_xxxxxxxx"          # GitHub PAT

# オプション
# export BITBUCKET_EMAIL="alice@example.com"  # Atlassian token を Basic 認証で
                                              # 使いたいときだけ設定
# export GH_ORG="my-gh-org"                   # 指定すると Org 直下に作成
# export WORK_DIR="/var/tmp/bb2gh"            # 一時 mirror clone の置き場
# export DRY_RUN=1                            # 実行せず計画のみ
# export SKIP_EXISTING=1                      # 既存 GitHub repo はスキップ

./migrate.sh
```

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
