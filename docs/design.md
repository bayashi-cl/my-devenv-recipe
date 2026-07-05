# 設計情報

`my-devenv-recipe` の具体的な構成・環境・コマンドに関する参照情報。思想・原則は [AGENTS.md](../AGENTS.md) を参照。

## リポジトリ構成

各言語の workspace 機能で構成される。

- **Python**: uv workspace（`pyproject.toml` の `[tool.uv.workspace]`）。`python/*` にパッケージを追加していく構成（現状 `mdr-api` のみ）
- **TypeScript**: deno workspace（`deno.json` の `workspace`）。`typescript/*` にパッケージを追加していく構成（現状 `mdr-web` のみ）
- **Docker**: Dockerfile・環境別 compose overlay は `docker/` 配下に集約

## 開発環境の起動

verify / dev / worktree の3ユースケースがあり、`scripts/develop.sh` がエントリポイント。詳細な起動手順は [README.md](../README.md) を参照。

フロント開発サーバー (`deno task web`) は dev コンテナ内から手動起動する必要がある。

## サービス・環境マトリクス

| environment | command |
|:--|:--|
| production | `docker compose -f compose.yaml -f docker/compose.prod.yaml` |
| ci | `docker compose` |
| develop | `docker compose -f compose.yaml -f compose.override.yaml -f docker/compose.dev.yaml` |
| develop(worktree) | `docker compose --project-directory . -f docker/compose.worktree.yaml` |

| category | service(image) | production | ci | develop | develop(worktree) |
|:--|:--|:-:|:-:|:-:|:-:|
| application | api(python), web(next.js/deno) | ◯ | ◯ | | |
| infra | db(postgres), proxy(traefik) | ◯ | ◯ | ◯ | 共有 |
| dashboard | db-admin(adminer) | | ◯ | ◯ | 共有 |
| devenv | dev(ubuntu) | | | ◯ | ◯ |

ルーティングは traefik によるサブドメイン方式（`${DOMAIN}`, `api.${DOMAIN}` 等）。

## Git worktree 運用

ブランチごとに独立した dev コンテナ・DB を持ちつつ、インフラ（proxy/db）は dev 環境と共有される。worktree の作成・起動自体はホスト側操作（`scripts/develop.sh worktree`）。

## コマンドリファレンス

dev コンテナ内から実行可能なコマンド。

- フロント開発サーバー起動: `deno task web`（ルートから実行、`mdr-web` の `next dev` を起動）
- API 起動: uv 経由のタスクランナー（`pyproject.toml` の `[tool.taskipy.tasks]` を参照）
- 型チェック・lint: Python は `ty` / `ruff`、TypeScript は `mdr-web` 配下の lint タスクを利用
