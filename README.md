# bitbuckettogithub

Bitbucket Cloud のワークスペースに含まれる全リポジトリを GitHub に
一括移行する Python 製 CLI です。標準ライブラリのみで動作します
(外部 HTTP ライブラリ等は不要)。

> 詳細な使い方は [docs/USAGE.md](docs/USAGE.md) を参照してください。

## 特徴

- ワークスペース配下のリポジトリを Bitbucket REST API で列挙 (ページング対応)
- GitHub 側に同名リポジトリを自動作成し、**`is_private` を引き継ぐ**
  (プライベートリポジトリはプライベートのまま)
- `git clone --mirror` + `git push --mirror` で全 ref / tag / branch を移送
- **Git LFS** に対応 (`git lfs fetch --all` → `git lfs push --all`)
- 既に存在する GitHub リポジトリの取扱いを `--skip-existing` で制御
- `--dry-run` で実行計画のみ表示
- `--rename SRC=DST` で個別にリポジトリ名を変更可能

## 必要環境

- Python 3.10 以上 (標準ライブラリのみ)
- `git` 本体 (1.8 以降)
- `git-lfs` (LFS リポジトリを扱う場合)
- 環境変数:
  - `BITBUCKET_USERNAME` — Bitbucket のユーザ名
  - `BITBUCKET_APP_PASSWORD` — App Password (`Repositories: Read` 必須)
  - `GITHUB_TOKEN` — GitHub Personal Access Token
    (`repo` スコープ。Org に作成する場合はさらに `admin:org` も推奨)

## インストール

```
pip install .
```

または直接モジュール実行:

```
python -m b2g --help
```

## 使い方

ユーザーアカウント直下に作成する例:

```
export BITBUCKET_USERNAME=alice
export BITBUCKET_APP_PASSWORD=xxxxxxxxxxxx
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx

python -m b2g \
  --workspace my-bb-team \
  --work-dir /var/tmp/b2g
```

GitHub Organization に作成する場合:

```
python -m b2g \
  --workspace my-bb-team \
  --github-org my-gh-org
```

事前確認だけしたいとき:

```
python -m b2g --workspace my-bb-team --dry-run
```

リポジトリ名を変更しつつ移行:

```
python -m b2g \
  --workspace my-bb-team \
  --rename old-name=new-name \
  --rename legacy_repo=legacy-repo
```

## 動作の流れ (リポジトリ毎)

1. Bitbucket API でリポジトリを列挙 (ページング対応)
2. GitHub に同名リポジトリが存在するか `GET /repos/:owner/:repo` で確認
3. 無ければ `POST /user/repos` または `POST /orgs/:org/repos` で作成
   (`private` は Bitbucket 側の値をそのまま設定)
4. `git clone --mirror` で Bitbucket からベアミラーを取得
5. `git lfs fetch --all` で LFS オブジェクトを取得 (LFS 不使用なら no-op)
6. `git push --mirror` で GitHub へ全 ref / tag を送出
7. `git lfs push --all` で LFS オブジェクトを送出

clone / push 用 URL には `https://USER:TOKEN@host/...` 形式で
資格情報を埋め込み、ディスクに資格情報を保存しません。
ログには `***` でマスクして出力します。

## 終了コード

- `0` — 全リポジトリの移行に成功
- `1` — 1件以上の失敗あり (それぞれの詳細は `[error]` ログを参照)

## 注意

- App Password と PAT は秘密情報です。シェル履歴に残さないでください
  (`direnv` などの利用を推奨)。
- LFS オブジェクトの容量によっては GitHub の LFS 転送上限に達する可能性が
  あります。事前に容量を見積もってください。
- Bitbucket 側の Issue / Pull Request / Pipelines は移行対象外です
  (Git の履歴とタグ・ブランチのみ)。
