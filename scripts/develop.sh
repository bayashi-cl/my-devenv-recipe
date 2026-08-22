#!/usr/bin/env bash
#
# Start Docker Compose services for the chosen development use case.
#
# ホスト側で実行する唯一の運用スクリプト。worktree での開発は dev コンテナ内の
# scripts/worktree.sh が担うため、ここには含まれない。
#
# Usage:
#   scripts/develop.sh              # interactive use-case menu
#   scripts/develop.sh dev          # start dev environment and exec into zsh
#   scripts/develop.sh dev --rebuild  # rebuild images and update env (recreate 伴う)
#   scripts/develop.sh verify       # start full verification stack (foreground)
#
# Use cases:
#   dev     infra + devenv を起動し、dev コンテナの zsh セッションに入る
#           （すでに起動済みなら既存コンテナへ接続し、recreate しない）
#   verify  app + infra + dashboard をフルスタックで起動する（フォアグラウンド）
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# Compose file flags per use case
DEV_FILES=(-f compose.yaml -f compose.override.yaml -f docker/compose.dev.yaml)

# dev サービスが running かどうかを判定する（build/recreate を伴わない）。
dev_running() {
  [ -n "$(docker compose "${DEV_FILES[@]}" ps --status running --quiet dev 2>/dev/null)" ]
}

usage() {
  cat <<'EOF'
Usage: develop.sh [usecase]

Usecases:
  dev     開発を始める         infra + devenv を起動して dev コンテナに入る
                               （起動済みなら既存コンテナへ接続し recreate しない）
  verify  検証環境を立ち上げる  app + infra + dashboard をフルスタック起動

Options (dev):
  --rebuild  イメージを再ビルドして環境を更新する（recreate を伴う）

worktree での開発は dev コンテナに入ってから scripts/worktree.sh を使う。

EOF
}

run_dev() {
  local rebuild="${1:-}"
  cd "$REPO_ROOT"

  if [ "$rebuild" = "--rebuild" ]; then
    echo "==> [dev] --rebuild: イメージを再ビルドして環境を更新します"
    echo "    (稼働中のセッションは切断される可能性があります)"
    docker compose "${DEV_FILES[@]}" up --detach --build
    # 基点チェックアウトの .env.worktree を用意する（冪等・DB 接続不要）
    docker compose "${DEV_FILES[@]}" exec dev scripts/worktree.sh init
  elif dev_running; then
    # 既起動時は up も --build も呼ばず recreate を避け、他セッションを維持する。
    echo "==> [dev] 既存の dev 環境に接続します (build/recreate しません)"
  else
    echo "==> [dev] infra + devenv を起動中..."
    docker compose "${DEV_FILES[@]}" up --detach --build
    # 基点チェックアウトの .env.worktree を用意する（冪等・DB 接続不要）
    docker compose "${DEV_FILES[@]}" exec dev scripts/worktree.sh init
  fi

  echo "==> [dev] dev コンテナに接続します"
  docker compose "${DEV_FILES[@]}" exec dev zsh
}

run_verify() {
  cd "$REPO_ROOT"
  echo "==> [verify] 検証環境をフルスタックで起動します (Ctrl-C で停止)"
  docker compose up --build
}

select_usecase() {
  echo "ユースケースを選んでください:"
  echo ""
  PS3="番号を入力: "
  select uc in \
    "dev    — 開発を始める" \
    "verify — 検証環境を立ち上げる" \
    "quit"; do
    case "$uc" in
      quit*)   exit 0 ;;
      dev*)    run_dev;    break ;;
      verify*) run_verify; break ;;
      *)       echo "無効な選択です" ;;
    esac
  done
}

case "${1:-}" in
  -h | --help) usage ;;
  dev)         run_dev "${2:-}" ;;
  verify)      run_verify ;;
  "")          select_usecase ;;
  *)
    echo "error: unknown usecase '${1}'" >&2
    echo "" >&2
    usage >&2
    exit 1
    ;;
esac
