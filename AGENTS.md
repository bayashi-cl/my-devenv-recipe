# AGENTS.md

## 概要

`my-devenv-recipe` は、Python(FastAPI) + Next.js/Deno + Docker Compose によるマルチ環境 devenv テンプレートである。現状はごく初期段階（API は health-check のみ）。実装済み機能を過大に前提せず、既存コードを確認したうえで作業すること。

具体的なリポジトリ構成・環境マトリクス・コマンド等は [docs/design.md](docs/design.md) を参照。

## 設計原則（Conventions）

- **設定管理原則**: 環境ごとに変わる値に dev 用のデフォルトを持たせない。未設定なら起動を失敗させ、設定漏れを即座に顕在化させる（fail-fast）
- **オリジン制御原則**: 各コンポーネントは自身に対応する環境のオリジンのみを許可し、同時起動する複数環境（dev/worktree等）が混線しないようにする
- **実行時設定原則**: 環境ごとに変わる設定はビルドに焼き込まず、実行時に環境変数として注入する（build once, deploy anywhere）

## エージェントとして作業する上での注意

- コンテナ群の起動・切り替え（`docker compose`, `scripts/develop.sh` 等）はホスト側で人間が行う操作。エージェントは通常すでに dev コンテナ内から起動されているため、これらを自ら実行する場面は基本的に無い
- 例外として、フロント開発サーバー (`deno task web`) は dev コンテナ内から手動起動する必要がある
- `typescript/mdr-web/AGENTS.md` には Next.js の破壊的変更に関する固有の注意書きがある。`mdr-web` 配下で作業する際は必ず参照すること
