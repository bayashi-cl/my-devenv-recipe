# my-devenv-recipe

## 起動操作

### 1. 検証環境（verify）

```sh
scripts/develop.sh verify
# または
docker compose up --build
```

- `compose.yaml` + `compose.override.yaml` を使用
- application(api, web) + infra(db, proxy) + dashboard(db-admin) をフルスタックで起動

### 2. 開発環境（dev）

```sh
scripts/develop.sh dev
# または VSCode: Reopen in Container
```

- `compose.yaml` + `compose.override.yaml` + `docker/compose.dev.yaml` を使用
- infra + dashboard + devenv(dev コンテナ) を起動
- application(api, web) はリセット済み

ホスト側で実行する操作はここまで。以降は dev コンテナ内で完結する。

フロントエンド開発サーバーは dev コンテナ内でレポジトリ直下から手動起動する:

```sh
deno task web
```

起動後は proxy 経由で `http://${DOMAIN}:8080`（既定では `http://localhost:8080`）から
アクセスできる。

### 3. worktree での開発

worktree は **dev コンテナの中に**作る。ホスト側での操作もコンテナの追加も不要。

```sh
# dev コンテナ内で実行する
scripts/worktree.sh add feature-branch

cd .worktrees/feature-branch
deno task web
```

- チェックアウトはリポジトリ内 `.worktrees/<slug>` に作られる
- worktree ごとに専用 DB (`wt_<slug>`)・ポート・traefik ルートが割り当てられる
- `http://<slug>.${DOMAIN}:8080`（API は `http://api-<slug>.${DOMAIN}:8080`）でアクセスできる

| コマンド | 説明 |
|:--|:--|
| `scripts/worktree.sh add <branch>` | worktree を作成し一式を用意する |
| `scripts/worktree.sh list` | worktree と割り当て済みリソースを一覧する |
| `scripts/worktree.sh remove <slug>` | worktree と一式を撤去する |
| `scripts/worktree.sh sync` | `.env.worktree` を正として DB とルートを再生成する |

ホスト側で `git worktree prune` を実行しないこと。worktree の管理情報にはコンテナ内の
パスが記録されており、ホストからは存在しないパスに見えるため prune 対象になってしまう
（`add` は防御として `git worktree lock` をかけている）。

## 実行時設定

待ち受けポート・CORS のオリジン・接続先 DB は、チェックアウトごとの `.env.worktree` から
実行時に読み込まれる（`scripts/worktree.sh` が生成するため手で編集しない）。同じイメージを
環境ごとの env で動かす方針に合わせ、これらの値はビルドに焼き込まない。

## まとめ

|environment|command|
|:--|:--|
|production|`docker compose -f compose.yaml -f docker/compose.prod.yaml`|
|ci|`docker compose`|
|develop|`docker compose -f compose.yaml -f compose.override.yaml -f docker/compose.dev.yaml`|

|category|service(image)|production|ci|develop|
|:--|:--|:-:|:-:|:-:|
|application|api(python), web(next.js/deno)|◯|◯||
|infra|db(postgres), proxy(traefik)|◯|◯|◯|
|dashboard|db-admin(adminer)||◯|◯|
|devenv|dev(ubuntu)|||◯|

develop 環境の worktree は、この dev コンテナ 1 つの中で論理的に分割される。
