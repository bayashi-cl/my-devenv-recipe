#!/usr/bin/env bash
#
# Start Docker Compose services for the chosen development use case.
#
# Usage:
#   scripts/compose.sh            # interactive use-case menu
#   scripts/compose.sh dev        # start dev environment and exec into zsh
#   scripts/compose.sh worktree   # start worktree dev environment and exec into zsh
#   scripts/compose.sh verify     # start full verification stack (foreground)
#
# Use cases:
#   dev       infra + devenv を起動し、dev コンテナの zsh セッションに入る
#   worktree  共有インフラを確認・起動し、worktree devenv を起動して zsh に入る
#   verify    app + infra + dashboard をフルスタックで起動する（フォアグラウンド）
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# Compose file flags per use case
DEV_FILES=(-f compose.yaml -f compose.override.yaml -f docker/compose.dev.yaml)
WORKTREE_FILES=(-f docker/compose.dev.yaml -f docker/compose.worktree.yaml)

# Network created by the main repo's compose project (infra shared with worktrees)
INFRA_NETWORK="my-devenv-recipe-dev_default"

usage() {
  cat <<'EOF'
Usage: compose.sh [usecase]

Usecases:
  dev       開発を始める（直下）     infra + devenv を起動して dev コンテナに入る
  worktree  worktreeで開発を始める   共有インフラを確認し worktree devenv を起動して入る
  verify    検証環境を立ち上げる     app + infra + dashboard をフルスタック起動

EOF
}

run_dev() {
  cd "$REPO_ROOT"
  echo "==> [dev] infra + devenv を起動中..."
  docker compose "${DEV_FILES[@]}" up --detach --build
  echo "==> [dev] dev コンテナに接続します"
  docker compose "${DEV_FILES[@]}" exec dev zsh
}

run_worktree() {
  cd "$REPO_ROOT"

  # Resolve main repo root (git-common-dir points to main/.git from a worktree,
  # or ".git" relative to cwd in the main repo itself)
  local git_common_dir
  git_common_dir="$(git rev-parse --git-common-dir)"
  local main_repo_root
  main_repo_root="$(cd "$(dirname "$git_common_dir")" && pwd)"

  # Derive slug and DB name from branch name
  local branch_name
  branch_name="$(git rev-parse --abbrev-ref HEAD)"
  local worktree_slug
  worktree_slug="$(echo "$branch_name" | sed 's|[^a-zA-Z0-9]|-|g' | tr '[:upper:]' '[:lower:]')"
  local db_name
  db_name="$(echo "$branch_name" | sed 's|[^a-zA-Z0-9]|_|g' | tr '[:upper:]' '[:lower:]')"

  # worktree 自身の .env を用意し、動的な変数を書き込む
  local worktree_env="$REPO_ROOT/.env"
  if [[ ! -f "$worktree_env" ]]; then
    cp "$REPO_ROOT/.env.example" "$worktree_env"
    echo "==> [worktree] .env.example から .env を生成しました"
  fi

  _upsert_env() {
    local key="$1" val="$2" file="$3"
    if grep -q "^${key}=" "$file"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
      echo "${key}=${val}" >> "$file"
    fi
  }
  _upsert_env WORKTREE_SLUG  "$worktree_slug"  "$worktree_env"
  _upsert_env MAIN_REPO_ROOT "$main_repo_root" "$worktree_env"

  local env_file_arg=(--env-file "$worktree_env")
  local worktree_compose=(docker compose --project-directory "$REPO_ROOT" "${env_file_arg[@]}" "${WORKTREE_FILES[@]}")

  if ! docker network inspect "$INFRA_NETWORK" >/dev/null 2>&1; then
    echo "==> [worktree] 共有インフラネットワークが見つかりません。メインリポジトリで dev 環境を起動します..."
    (cd "$main_repo_root" && docker compose "${DEV_FILES[@]}" up -d)
  else
    echo "==> [worktree] 共有インフラ確認済み ($INFRA_NETWORK)"
  fi

  echo "==> [worktree] worktree devenv を起動中... (slug: $worktree_slug)"
  "${worktree_compose[@]}" up -d

  echo "==> [worktree] データベース '$db_name' を作成中..."
  (cd "$main_repo_root" && \
    docker compose "${DEV_FILES[@]}" exec -T db \
      psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='$db_name'" \
    | grep -q 1 \
    || docker compose "${DEV_FILES[@]}" exec -T db \
      psql -U postgres -c "CREATE DATABASE $db_name")

  echo "==> [worktree] 準備完了 — DB: $db_name / URL: http://api-${worktree_slug}.${DOMAIN:-localhost}"
  echo "==> [worktree] dev コンテナに接続します"
  "${worktree_compose[@]}" exec dev zsh
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
    "dev      — 開発を始める（直下）" \
    "worktree — worktreeで開発を始める" \
    "verify   — 検証環境を立ち上げる" \
    "quit"; do
    case "$uc" in
      quit*)     exit 0 ;;
      dev*)      run_dev;      break ;;
      worktree*) run_worktree; break ;;
      verify*)   run_verify;   break ;;
      *)         echo "無効な選択です" ;;
    esac
  done
}

case "${1:-}" in
  -h | --help) usage ;;
  dev)         run_dev ;;
  worktree)    run_worktree ;;
  verify)      run_verify ;;
  "")          select_usecase ;;
  *)
    echo "error: unknown usecase '${1}'" >&2
    echo "" >&2
    usage >&2
    exit 1
    ;;
esac
