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

### 2. レポジトリ直下からの開発（dev）

```sh
scripts/develop.sh dev
# または VSCode: Reopen in Container
```

- `compose.yaml` + `compose.override.yaml` + `docker/compose.dev.yaml` を使用
- infra + dashboard + devenv(dev コンテナ) を起動
- application(api, web) はリセット済み

フロントエンド開発サーバーは dev コンテナ内でレポジトリ直下から手動起動する:

```sh
deno task web
```

### 3. worktree での開発（worktree）

```sh
# worktree を作成して移動
git worktree add ../feature-branch feature-branch && cd ../feature-branch

# 開発環境起動（dev 環境が未起動なら自動起動）
scripts/develop.sh worktree
```

- `docker/compose.worktree.yaml` のみを使用（build/command/volumes は `docker/compose.dev.yaml` と二重管理）
- infra と dashboard は dev 環境のものを共有（`my-devenv-recipe-dev_default` ネットワーク）
- worktree 専用の devenv(dev コンテナ) を起動

## まとめ

|environment|command|
|:--|:--|
|production|`docker compose -f compose.yaml -f docker/compose.prod.yaml`|
|ci|`docker compose`|
|develop|`docker compose -f compose.yaml -f compose.override.yaml -f docker/compose.dev.yaml`|
|develop(worktree)|`docker compose --project-directory . -f docker/compose.worktree.yaml`|

|category|service(image)|production|ci|develop|develop(worktree)|
|:--|:--|:-:|:-:|:-:|:-:|
|application|api(python), web(next.js/deno)|◯|◯|||
|infra|db(postgres), proxy(traefik)|◯|◯|◯|共有|
|dashboard|db-admin(adminer)||◯|◯|共有|
|devenv|dev(ubuntu)|||◯|◯|
