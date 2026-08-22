# 設計情報

`my-devenv-recipe` の具体的な構成・環境・コマンドに関する参照情報。思想・原則は [AGENTS.md](../AGENTS.md) を参照。

## リポジトリ構成

各言語の workspace 機能で構成される。

- **Python**: uv workspace（`pyproject.toml` の `[tool.uv.workspace]`）。`python/*` にパッケージを追加していく構成（現状 `mdr-api` のみ）
- **TypeScript**: deno workspace（`deno.json` の `workspace`）。`typescript/*` にパッケージを追加していく構成（現状 `mdr-web` のみ）
- **Docker**: Dockerfile・環境別 compose overlay は `docker/` 配下に集約

## 開発環境の起動

verify / dev の2ユースケースがあり、`scripts/develop.sh` がエントリポイント。ホスト側で実行する操作はこれだけで、worktree を含む以降の作業は dev コンテナ内で完結する。詳細な起動手順は [README.md](../README.md) を参照。

フロント開発サーバー (`deno task web`) は dev コンテナ内から手動起動する必要がある。

## サービス・環境マトリクス

| environment | command |
|:--|:--|
| production | `docker compose -f compose.yaml -f docker/compose.prod.yaml` |
| ci | `docker compose` |
| develop | `docker compose -f compose.yaml -f compose.override.yaml -f docker/compose.dev.yaml` |

| category | service(image) | production | ci | develop |
|:--|:--|:-:|:-:|:-:|
| application | api(python), web(next.js/deno) | ◯ | ◯ | |
| infra | db(postgres), proxy(traefik) | ◯ | ◯ | ◯ |
| dashboard | db-admin(adminer) | | ◯ | ◯ |
| devenv | dev(ubuntu) | | | ◯ |

ルーティングは traefik によるサブドメイン方式（`${DOMAIN}`, `api.${DOMAIN}` 等）。

## 実行時設定（`.env.worktree`）

待ち受けポート・CORS のオリジン・接続先 DB は、チェックアウトごとの `.env.worktree` に置き、実行時に読み込む。`scripts/worktree.sh` が生成するため手で編集しない。

| キー | 用途 |
|:--|:--|
| `WORKTREE_SLUG` | 表示・識別用の slug（基点は `base`） |
| `PORT` | フロント開発サーバーの待ち受けポート（`next dev` が解釈する） |
| `API_PORT` | API の待ち受けポート |
| `FRONTEND_ORIGIN` | API が CORS で許可するオリジン |
| `API_BASE_URL` | フロントが叩く API のベース URL |
| `DATABASE_URL` | そのチェックアウト専用の DB への接続文字列 |

読み込み経路は `deno.json` の `web` タスク（`deno task --env-file`）と `pyproject.toml` の `api` タスク（`.` で source）。dev コンテナ側の環境変数には置かない — 全 worktree で共有されてしまううえ、`--env-file` は既存の環境変数を上書きしないため worktree 側の設定が無視される。

## Git worktree 運用

worktree は dev コンテナ 1 つの中に並べ、リポジトリ内 `.worktrees/<slug>` にチェックアウトする。分離はコンテナではなく以下の3点で行う。

| 分離対象 | 実体 | 割り当て |
|:--|:--|:--|
| 実行時設定 | `<worktree>/.env.worktree` | ポート `3100+i` / `8100+i`（基点は 3000 / 8000） |
| データベース | postgres の database | `wt_<slug>` |
| ルーティング | `docker/traefik/dynamic/wt-<slug>.yaml` | `<slug>.${DOMAIN}` / `api-<slug>.${DOMAIN}` |

ポートは別途レジストリを持たず、`git worktree list` が返す全 worktree の `.env.worktree` を走査して空き番号を採番する（実体との乖離を防ぐため）。`.worktrees/` 配下を glob するのではなく git を正とするので、外部ツール（`claude -w` 等）がリポジトリ外に切った worktree も採番時に見落とさない。採番と `.env.worktree` の書き出しは `flock`（`.worktrees/.alloc.lock`）で直列化しており、複数エージェントが別々の worktree を同時に `provision` してもポートは二重採番されない（DB 作成・依存インストールはロックの外なので並行する）。

管理は dev コンテナ内の `scripts/worktree.sh`（`init` / `add` / `provision` / `list` / `remove` / `sync`）が担う。エージェント向けの入口は [.claude/skills/worktree/SKILL.md](../.claude/skills/worktree/SKILL.md)。

`add` は「worktree の作成」と「副資源の用意」を一度に行うが、後者は `provision` という作成主体に依存しない冪等な処理に切り出してある。外部ツール（`claude -w` 等）や素の `git worktree add` で作られた worktree でも、その中で `provision` を叩けば `.env.worktree`・DB・ルート・依存が一式そろう（`uv sync` に相当）。`provision --gc` は対応する worktree の無い `wt_*` DB と `wt-*.yaml` ルートを刈り取る（作成を外部に委ねると撤去も外部で行われ、DB とルートだけが残るため）。

### traefik の2つの provider

- **docker provider**: 起動時に確定しているルート（基点の dev コンテナ、db-admin、proxy 自身）を labels から拾う
- **file provider**: `docker/traefik/dynamic/` を監視し、worktree のルートを動的に増減させる

labels はコンテナ作成時に固定されるため、コンテナを作り直さずにルートを追加するには file provider が必要になる。これが「ホスト操作なしで worktree を増やせる」ことの前提。

### 注意点

- worktree の管理情報はホストからバインドされた `.git` に記録されるが、ホストとコンテナではリポジトリのマウント先が違う。絶対パスで記録すると一方からは存在しないパスに見え、`git gc` が誘発する `git worktree prune` の対象になってしまうため、相対パスで記録する必要がある（Git 2.48 以降）。`add` は自身の `git worktree add` に `--relative-paths` を付けるだけでなく、`scripts/worktree.sh` はどのコマンドでも実行時に `git config worktree.useRelativePaths true` を担保する。これにより外部ツール（`claude -w` 等）が `--relative-paths` を付けずに `git worktree add` しても相対パスで記録され、prune 事故を防げる。どちらから見ても正しく解決されるので、ホスト側からも通常どおり worktree を扱える
- `scripts/worktree.sh` は `--relative-paths` 非対応の git を検出したら実行を拒否する。絶対パスで記録された worktree を作ってしまうと、prune で管理情報を失うため
- `.worktrees/` は build context を肥大させるため `.dockerignore` で除外している
- `docker compose down -v` の後は DB が失われるため `scripts/worktree.sh sync` で復元する

## コマンドリファレンス

dev コンテナ内から実行可能なコマンド。

- フロント開発サーバー起動: `deno task web`（チェックアウト直下から実行、`mdr-web` の `next dev` を起動）
- API 起動: uv 経由のタスクランナー（`pyproject.toml` の `[tool.taskipy.tasks]` を参照）
- 型チェック・lint: Python は `ty` / `ruff`、TypeScript は `mdr-web` 配下の lint タスクを利用
- worktree 管理: `scripts/worktree.sh`
