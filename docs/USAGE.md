# 使い方ガイド (b2g)

`b2g` は Bitbucket Cloud のワークスペースに含まれるリポジトリを
GitHub に一括移行するための CLI です。本書では準備から実行、
トラブルシューティングまでを順を追って説明します。

---

## 目次

1. [できること / できないこと](#できること--できないこと)
2. [事前準備](#事前準備)
3. [認証情報の取得](#認証情報の取得)
4. [インストール](#インストール)
5. [コマンドラインリファレンス](#コマンドラインリファレンス)
6. [典型的な使用例](#典型的な使用例)
7. [動作の流れ (内部処理)](#動作の流れ-内部処理)
8. [Git LFS について](#git-lfs-について)
9. [失敗時のリトライ・部分再実行](#失敗時のリトライ部分再実行)
10. [トラブルシューティング](#トラブルシューティング)
11. [FAQ](#faq)

---

## できること / できないこと

### できること

- Bitbucket ワークスペース配下の全リポジトリの **Git 履歴 / 全ブランチ /
  全タグ** を GitHub に移送
- リポジトリの **`is_private` (公開/非公開)** をそのまま引き継ぎ
- Git **LFS オブジェクト** の同期
- リポジトリ名の個別変更 (`--rename`)
- 既に存在するリポジトリへの追加 push (デフォルト) または スキップ
  (`--skip-existing`)

### できないこと (移行対象外)

- Pull Request / Issue / コメント
- Bitbucket Pipelines の設定や実行履歴
- リポジトリ単位のアクセス権設定 / Webhook
- Snippets / Wiki

これらは Bitbucket 側の API モデルが GitHub と大きく異なるため
本ツールでは扱いません。

---

## 事前準備

### 1. 必要なソフトウェア

| ツール | バージョン | 備考 |
|--------|------------|------|
| Python | 3.10 以上 | 標準ライブラリのみ使用 |
| git    | 1.8 以上 | `clone --mirror` / `push --mirror` を使用 |
| git-lfs | 2.x 以上 | LFS リポジトリがある場合のみ必須 |

### 2. ディスク容量

`--work-dir` (既定 `/tmp/b2g`) に **全リポジトリの bare clone + LFS
オブジェクト** が一時的に展開されます。最大リポジトリの容量 × 並列度
ぶんの空きを確保してください。本ツールは現状逐次実行ですが、
LFS は容量を消費しがちなので余裕を持って割り当ててください。

### 3. ネットワーク

- `api.bitbucket.org` (HTTPS)
- `bitbucket.org` (HTTPS clone)
- `api.github.com` (HTTPS)
- `github.com` (HTTPS push)

への到達性が必要です。プロキシ環境では `HTTPS_PROXY` 環境変数を
設定してください (Python 標準の `urllib` と `git` 双方が参照します)。

---

## 認証情報の取得

### Bitbucket App Password

1. Bitbucket にログインし、右上アバター → **Personal settings**
2. 左メニュー **App passwords** → **Create app password**
3. 名前: `b2g-migration` など
4. 権限: **Repositories: Read** (必須) ・ **Account: Read** (推奨)
5. 表示されたパスワードを **その場で控える**
   (再表示できません)

### GitHub Personal Access Token (PAT)

Classic PAT を推奨します。

1. <https://github.com/settings/tokens> → **Generate new token (classic)**
2. 期限と名前を設定
3. スコープ:
   - `repo` (フル) — プライベートリポジトリ作成 / push に必須
   - `workflow` — `.github/workflows/` を含むリポジトリを移行する場合
   - `admin:org` — Organization に作成する場合
4. トークンを控える

### 環境変数として設定

```bash
export BITBUCKET_USERNAME="alice"
export BITBUCKET_APP_PASSWORD="xxxxxxxxxxxxxxxxxxxx"
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

`direnv` などを使い、シェル履歴に直書きしないことを強く推奨します。

---

## インストール

### A. パッケージとしてインストール

```bash
pip install .
b2g --help
```

### B. インストールせずに実行

```bash
python -m b2g --help
```

(以後の例は `python -m b2g ...` 形式で表記)

---

## コマンドラインリファレンス

```
python -m b2g [-h] -w WORKSPACE
              [--github-org GITHUB_ORG]
              [--work-dir WORK_DIR]
              [--dry-run]
              [--skip-existing]
              [--rename SRC=DST]
```

| オプション | 必須 | 説明 |
|------------|------|------|
| `-w, --workspace` | ✓ | Bitbucket ワークスペース (チーム) のスラッグ |
| `--github-org` | | 指定すると Org 直下に作成。省略時は認証ユーザー直下 |
| `--work-dir` | | 一時クローン先。既定 `/tmp/b2g` |
| `--dry-run` | | API 呼び出しを伴うが書き込みは行わない計画表示モード |
| `--skip-existing` | | 既に GitHub に同名リポジトリがある場合はスキップ |
| `--rename SRC=DST` | | 個別にリポジトリ名を変更 (複数指定可) |

| 終了コード | 意味 |
|------------|------|
| 0 | 全リポジトリ成功 |
| 1 | 1件以上失敗 (詳細は `[error]` ログ参照) |

### ログの読み方

| プレフィックス | 意味 |
|----------------|------|
| `[info]`  | 進捗・状態 |
| `[step]`  | 実際に実行する操作 (HTTP 呼び出し前 / git コマンド) |
| `[warn]`  | 続行はするが注意が必要な事象 (例: git-lfs 未導入) |
| `[error]` | リポジトリ単位の失敗 (他のリポジトリは継続処理) |

`[step] git clone --mirror https://x-access-token:***@github.com/...`
のように **資格情報部分は `***` でマスク** されます。

---

## 典型的な使用例

### ① 個人アカウントへ全リポジトリをコピー

```bash
export BITBUCKET_USERNAME=alice
export BITBUCKET_APP_PASSWORD=xxxxxxxxxxxx
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx

python -m b2g --workspace my-bb-team
```

### ② Organization 配下に作成

```bash
python -m b2g \
  --workspace my-bb-team \
  --github-org my-gh-org
```

### ③ まず計画だけ確認 (dry-run)

```bash
python -m b2g --workspace my-bb-team --dry-run
```

API は呼ぶが、リポジトリ作成 / clone / push は行いません。
処理対象数や対象スラッグの確認に使ってください。

### ④ リポジトリ名の個別変更

```bash
python -m b2g \
  --workspace my-bb-team \
  --rename old_name=old-name \
  --rename internal_proj=internal-project
```

`SRC` (Bitbucket 側スラッグ) を `DST` (GitHub 上の名前) に置き換えます。

### ⑤ 一度走らせた後の追加分のみを移送

```bash
python -m b2g --workspace my-bb-team --skip-existing
```

既に GitHub 側に同名のリポジトリがあるものは触らず、
新規追加された Bitbucket リポジトリのみ移行します。

### ⑥ 大きいリポジトリを別ディスクに配置

```bash
python -m b2g \
  --workspace my-bb-team \
  --work-dir /mnt/large-disk/b2g
```

---

## 動作の流れ (内部処理)

各リポジトリについて以下を順に実行します。

1. **存在確認**:
   `GET https://api.github.com/repos/<owner>/<name>` で 200 が返れば
   既存とみなす
2. **作成** (存在しない場合):
   - User: `POST /user/repos`
   - Org: `POST /orgs/<org>/repos`
   - Body は `{name, description, private, has_issues, has_wiki: false,
     auto_init: false}`
   - **`private` は Bitbucket の `is_private` をそのまま設定**
3. **mirror clone**:
   `git clone --mirror https://USER:TOKEN@bitbucket.org/<ws>/<slug>.git
   <work_dir>/<slug>.git`
4. **LFS 取得**: `git lfs fetch --all` (LFS 未使用なら no-op)
5. **mirror push**:
   `git push --mirror https://x-access-token:TOKEN@github.com/<owner>/<name>.git`
   → 全 ref / branch / tag / 削除予定 ref まで宛先と一致させる
6. **LFS push**: `git lfs push --all <dst-url>`

`--work-dir` 内のディレクトリは **再実行のたびに作り直します**
(`shutil.rmtree` 後に再 clone)。中途半端な状態が残ることはありません。

---

## Git LFS について

- `git-lfs` が PATH に存在しない場合は警告を出して LFS 工程をスキップします
  (mirror push 自体は通常通り実行)
- LFS が使われていないリポジトリでは `git lfs fetch` がエラー終了することが
  あるため、本ツールはこれを **soft failure** として続行します
- GitHub 側にはアカウントごとに **LFS ストレージ / 帯域の上限** があります。
  事前に Bitbucket のリポジトリ容量を確認し、有償プランの加入を検討してください
  - 容量確認: `du -sh <work_dir>/<slug>.git/lfs/objects` (mirror clone 後)

---

## 失敗時のリトライ・部分再実行

- 1リポジトリの失敗は他リポジトリの処理を止めません。
  失敗は `[error]` ログに出力され、最後に集計が表示されます
- 同じコマンドで **再実行** すると:
  - GitHub に既に存在するリポジトリは作成をスキップ
  - mirror clone は work-dir を作り直して再実行
  - mirror push はそのまま再実行 (べき等)
- 既存リポジトリをまったく触りたくない場合は `--skip-existing` を使用

例: ネットワーク断で半分失敗したケース

```bash
# 1回目 (一部失敗)
python -m b2g --workspace my-bb-team
# → exit 1, 5/100 失敗

# そのまま再実行で残り 5 つを再試行
python -m b2g --workspace my-bb-team
```

---

## トラブルシューティング

### `environment variable BITBUCKET_USERNAME is required`

→ 認証情報を `export` していません。[認証情報の取得](#認証情報の取得) を参照。

### `Bitbucket API error 401`

- App Password の権限不足 (Repositories: Read 必須)
- ユーザー名がメールアドレスになっている (App Password はユーザー名で認証)
- **Atlassian は Bitbucket Cloud の App Password を段階的廃止しています。**
  既存のものが失効している / 新規作成できない場合は **Atlassian API token**
  に切り替え、`BITBUCKET_USERNAME` には Atlassian アカウントのメールを設定
  してください (Basic 認証は `<email>:<api-token>` になります)。

切り分けに便利な curl:

```bash
# (a) 認証情報そのものの検証
curl -s -o /dev/null -w "/user => %{http_code}\n" \
  -u "$BITBUCKET_USERNAME:$BITBUCKET_APP_PASSWORD" \
  https://api.bitbucket.org/2.0/user

# (b) 自分がアクセスできるワークスペース一覧
curl -s -u "$BITBUCKET_USERNAME:$BITBUCKET_APP_PASSWORD" \
  https://api.bitbucket.org/2.0/workspaces \
  | python -m json.tool | grep '"slug"'
```

(a) が 200 なら認証 OK。(b) で出てきた `slug` を `--workspace` に渡してください。
`b2g` 側でも v0.1.1 以降は同等のプリフライト確認を行い、ワークスペース 401 時には
利用可能なスラッグ候補を表示します。

### `GitHub repo creation failed: HTTP 422 ... name already exists`

→ 既存と判定しきれなかったケース。`--skip-existing` を試すか、`--rename` で
別名にしてください。

### `git: 'lfs' is not a git command`

→ `git-lfs` が未インストール。各 OS のパッケージマネージャで導入:

```bash
# Debian/Ubuntu
sudo apt-get install git-lfs && git lfs install
# macOS (Homebrew)
brew install git-lfs && git lfs install
```

### `fatal: Authentication failed for 'https://github.com/...'`

- GitHub PAT のスコープ不足 (`repo` 必須)
- PAT が期限切れ
- Org に作成しようとしている場合は SSO 承認が必要なことがあります
  (`https://github.com/settings/tokens` からトークン横の **Configure SSO**)

### `Repository size exceeds the limit`

- GitHub の単一リポジトリ上限 (1.5GB 推奨 / 100GB ハードリミット) を超過
- 履歴の整理 (`git filter-repo` 等) が必要

### `LFS objects exceed quota`

- GitHub LFS の容量 / 帯域上限。**Settings → Billing → Git LFS** で
  追加 data pack を購入するか、不要オブジェクトをパージ

### work-dir に巨大なファイルが残る

`--work-dir` は再実行時に作り直しますが、途中中断した場合は残骸が残ります。
不要なら手動削除してください:

```bash
rm -rf /tmp/b2g
```

---

## FAQ

**Q. SSH 鍵で移行できますか？**

A. 現状は HTTPS のみ対応です。CI 等で扱いやすく、トークンの権限制御が
細かくできるためです。

**Q. 並列実行できますか？**

A. 現バージョンは逐次実行です。GitHub / Bitbucket 双方の API レート
制限を踏まないことを優先しています。並列が必要な場合はワークスペースを
分割し、別プロセスで `b2g` を実行してください。

**Q. 同期ツールとして定期実行できますか？**

A. 設計上は冪等なので cron で定期実行可能です。ただし GitHub 側で
直接編集された変更は **`git push --mirror` により上書きされる** 点に
注意してください。GitHub を真とする運用なら本ツールでの再 push は
危険です。

**Q. ブランチの保護設定や Default branch も移行されますか？**

A. **Default branch は GitHub 側の自動判定** に従います (通常は最初に
push された branch)。Branch protection 等は移行されないため、移行後に
GitHub 側で再設定してください。

**Q. ログを残したい**

A. 標準出力 / 標準エラーに分かれて出力されるので、`tee` でファイル化が容易です:

```bash
python -m b2g --workspace my-bb-team 2>&1 | tee b2g-$(date +%F).log
```

**Q. 移行後の確認**

A. 推奨手順:

```bash
# Bitbucket 側
git ls-remote https://USER:APP_PASS@bitbucket.org/<ws>/<slug>.git | wc -l
# GitHub 側
git ls-remote https://x-access-token:GH_TOKEN@github.com/<owner>/<name>.git | wc -l
```

ref 数が一致していれば全 branch / tag が移送されています。
