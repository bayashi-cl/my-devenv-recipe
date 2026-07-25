#!/usr/bin/env bash
#
# dev コンテナ内で git worktree を管理する。
#
# 1 つの dev コンテナの中に複数の worktree を並べ、チェックアウト・ポート・DB・
# traefik ルートを worktree 単位で論理分割する。ホスト側の操作は不要。
#
# Usage:
#   scripts/worktree.sh init              基点チェックアウトの実行時設定を用意する
#   scripts/worktree.sh add <branch>      worktree を作成し一式を用意する
#   scripts/worktree.sh list              worktree と割り当て済みリソースを一覧する
#   scripts/worktree.sh remove <slug>     worktree と一式を撤去する
#   scripts/worktree.sh sync              .env.worktree を正として DB とルートを再生成する
#
# Options:
#   add     --no-install   依存関係のインストール（uv sync / deno install）を省く
#   remove  --force        未コミットの変更があっても撤去する
#

set -euo pipefail

# 基点チェックアウトに割り当てる固定ポート。compose.dev.yaml の traefik labels と対応する。
readonly BASE_PORT=3000
readonly BASE_API_PORT=8000

# worktree に割り当てるポートの起点と上限。
readonly WT_PORT_BASE=3100
readonly WT_API_PORT_BASE=8100
readonly WT_MAX=50

# proxy が公開されているホスト側ポート（compose.dev.yaml の ports と対応する）。
readonly PROXY_PORT=8080

readonly LOCK_REASON="dev コンテナ内で管理している worktree。ホストからは存在しないパスに見えるため prune 禁止。"

die() {
  echo "error: $*" >&2
  exit 1
}

info() {
  echo "==> $*"
}

# このスクリプトは dev コンテナ内で動くことを前提にしている。DB とルートの生成に
# 必要な情報が無ければ、黙って進めず即座に失敗させる。
require_devenv() {
  [[ -n "${DOMAIN:-}" ]] || die "DOMAIN が未設定です。dev コンテナ内で実行してください。"
  [[ -n "${PGHOST:-}" ]] || die "PGHOST が未設定です。dev コンテナ内で実行してください。"
  [[ -n "${PGUSER:-}" ]] || die "PGUSER が未設定です。dev コンテナ内で実行してください。"
  command -v psql >/dev/null || die "psql が見つかりません。dev コンテナ内で実行してください。"
}

# worktree の中から実行されても、常に基点チェックアウトを指す。
resolve_main_root() {
  local common_dir
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir)" \
    || die "git リポジトリの中で実行してください。"
  dirname "$common_dir"
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's|[^a-z0-9]\+|-|g' -e 's|^-||' -e 's|-$||'
}

db_name_for() {
  echo "wt_$(echo "$1" | tr '-' '_')"
}

env_path_for() {
  echo "$WORKTREES_DIR/$1/.env.worktree"
}

route_path_for() {
  echo "$TRAEFIK_DIR/wt-$1.yaml"
}

read_env_value() {
  local file="$1" key="$2"
  sed -n "s|^${key}=||p" "$file" | head -n 1
}

# 使用中のポートは .env.worktree 自身が持つ。別途レジストリを置くと実体と乖離するため、
# 割り当て済みポートは毎回チェックアウトから読み直す。
allocate_index() {
  local used=() file port i
  for file in "$WORKTREES_DIR"/*/.env.worktree; do
    [[ -f "$file" ]] || continue
    port="$(read_env_value "$file" PORT)"
    [[ -n "$port" ]] && used+=("$port")
  done

  for ((i = 0; i < WT_MAX; i++)); do
    port=$((WT_PORT_BASE + i))
    local taken=0 u
    for u in ${used[@]+"${used[@]}"}; do
      [[ "$u" == "$port" ]] && taken=1 && break
    done
    if [[ "$taken" -eq 0 ]]; then
      echo "$i"
      return 0
    fi
  done
  die "空きポートがありません（最大 ${WT_MAX} worktree）。不要な worktree を remove してください。"
}

write_env_file() {
  local path="$1" slug="$2" port="$3" api_port="$4" origin="$5" api_base_url="$6" db="$7"

  cat >"$path" <<EOF
# scripts/worktree.sh が生成する。手で編集しないこと。
# 作り直す場合は scripts/worktree.sh sync（基点は init --force）を使う。
WORKTREE_SLUG=${slug}
PORT=${port}
API_PORT=${api_port}
FRONTEND_ORIGIN=${origin}
API_BASE_URL=${api_base_url}
DATABASE_URL=postgresql://${PGUSER}:${PGPASSWORD:-}@${PGHOST}:${PGPORT:-5432}/${db}
EOF
}

write_route_file() {
  local slug="$1" port="$2" api_port="$3"

  cat >"$(route_path_for "$slug")" <<EOF
# scripts/worktree.sh が生成する。手で編集しないこと。
# traefik の file provider が監視しており、保存すると即座に反映される。
http:
  routers:
    wt-${slug}-web:
      rule: "Host(\`${slug}.${DOMAIN}\`)"
      entryPoints: ["web"]
      service: wt-${slug}-web
    wt-${slug}-api:
      rule: "Host(\`api-${slug}.${DOMAIN}\`)"
      entryPoints: ["web"]
      service: wt-${slug}-api
  services:
    wt-${slug}-web:
      loadBalancer:
        servers:
          - url: "http://dev:${port}"
    wt-${slug}-api:
      loadBalancer:
        servers:
          - url: "http://dev:${api_port}"
EOF
}

ensure_database() {
  local db="$1"
  if psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${db}'" | grep -q 1; then
    return 0
  fi
  psql -q -c "CREATE DATABASE \"${db}\""
}

cmd_init() {
  local force=0
  [[ "${1:-}" == "--force" ]] && force=1

  local path="$MAIN_ROOT/.env.worktree"
  if [[ -f "$path" && "$force" -eq 0 ]]; then
    info "基点チェックアウトの .env.worktree は既にあります（作り直すには --force）"
    return 0
  fi

  # 基点はサブドメインを持たず、compose.dev.yaml の labels が固定ポートでルートする。
  write_env_file "$path" "base" "$BASE_PORT" "$BASE_API_PORT" \
    "http://${DOMAIN}:${PROXY_PORT}" \
    "http://api.${DOMAIN}:${PROXY_PORT}" \
    "${PGDATABASE:-postgres}"
  info "基点チェックアウトの実行時設定を生成しました: $path"
}

cmd_add() {
  local branch="" no_install=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-install) no_install=1 ;;
      -*) die "unknown option '$1'" ;;
      *) [[ -n "$branch" ]] && die "ブランチは 1 つだけ指定してください"; branch="$1" ;;
    esac
    shift
  done
  [[ -n "$branch" ]] || die "ブランチ名を指定してください: worktree.sh add <branch>"

  local slug
  slug="$(slugify "$branch")"
  [[ -n "$slug" ]] || die "ブランチ名 '$branch' から slug を作れません"
  [[ "$slug" != "base" ]] || die "'base' は基点チェックアウト用に予約されています"
  # PostgreSQL の識別子は 63 バイトで黙って切り詰められ、別 worktree と同じ DB を
  # 指してしまう。そうなる前に止める。
  [[ "${#slug}" -le 40 ]] || die "ブランチ名が長すぎます（slug '$slug' は 40 文字以内にしてください）"

  local wt_dir="$WORKTREES_DIR/$slug"
  [[ ! -e "$wt_dir" ]] || die "worktree '$slug' は既に存在します: $wt_dir"

  local index port api_port db
  index="$(allocate_index)"
  port=$((WT_PORT_BASE + index))
  api_port=$((WT_API_PORT_BASE + index))
  db="$(db_name_for "$slug")"

  mkdir -p "$WORKTREES_DIR"

  info "worktree を作成中: $wt_dir (branch: $branch)"
  if git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$MAIN_ROOT" worktree add "$wt_dir" "$branch"
  elif git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$MAIN_ROOT" worktree add --track -b "$branch" "$wt_dir" "origin/$branch"
  else
    git -C "$MAIN_ROOT" worktree add -b "$branch" "$wt_dir"
  fi

  # worktree の管理情報はホストからバインドされた .git に、コンテナ内パスで記録される。
  # ホスト側からは存在しないパスに見えるため、git gc が誘発する prune で消えうる。lock で防ぐ。
  git -C "$MAIN_ROOT" worktree lock --reason "$LOCK_REASON" "$wt_dir"

  write_env_file "$(env_path_for "$slug")" "$slug" "$port" "$api_port" \
    "http://${slug}.${DOMAIN}:${PROXY_PORT}" \
    "http://api-${slug}.${DOMAIN}:${PROXY_PORT}" \
    "$db"

  info "データベースを作成中: $db"
  ensure_database "$db"

  info "traefik ルートを生成中: $(route_path_for "$slug")"
  write_route_file "$slug" "$port" "$api_port"

  if [[ "$no_install" -eq 0 ]]; then
    info "依存関係をインストール中（--no-install で省略可）"
    (cd "$wt_dir" && uv sync && deno install --allow-scripts --frozen)
  fi

  echo ""
  info "準備完了"
  print_worktree "$slug"
  echo ""
  echo "  開発を始めるには:"
  echo "    cd $wt_dir"
  echo "    deno task web      # フロント開発サーバー"
  echo "    uv run task api    # API"
}

print_worktree() {
  local slug="$1"
  local file wt_dir branch port api_port db
  file="$(env_path_for "$slug")"
  wt_dir="$WORKTREES_DIR/$slug"
  port="$(read_env_value "$file" PORT)"
  api_port="$(read_env_value "$file" API_PORT)"
  db="$(db_name_for "$slug")"
  branch="$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"

  printf '  %-16s branch=%-24s ports=%s/%s db=%s\n' "$slug" "$branch" "$port" "$api_port" "$db"
  printf '  %-16s web=http://%s.%s:%s  api=http://api-%s.%s:%s\n' \
    "" "$slug" "$DOMAIN" "$PROXY_PORT" "$slug" "$DOMAIN" "$PROXY_PORT"
}

cmd_list() {
  local found=0 file slug
  echo "基点チェックアウト: $MAIN_ROOT"
  if [[ -f "$MAIN_ROOT/.env.worktree" ]]; then
    printf '  %-16s ports=%s/%s  web=http://%s:%s\n' \
      "base" "$BASE_PORT" "$BASE_API_PORT" "$DOMAIN" "$PROXY_PORT"
  else
    echo "  (未初期化 — scripts/worktree.sh init を実行してください)"
  fi

  echo ""
  echo "worktree:"
  for file in "$WORKTREES_DIR"/*/.env.worktree; do
    [[ -f "$file" ]] || continue
    slug="$(basename "$(dirname "$file")")"
    print_worktree "$slug"
    found=1
  done
  [[ "$found" -eq 1 ]] || echo "  (なし)"
}

cmd_remove() {
  local slug="" force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1 ;;
      -*) die "unknown option '$1'" ;;
      *) [[ -n "$slug" ]] && die "slug は 1 つだけ指定してください"; slug="$1" ;;
    esac
    shift
  done
  [[ -n "$slug" ]] || die "slug を指定してください: worktree.sh remove <slug>"

  local wt_dir="$WORKTREES_DIR/$slug"
  [[ -d "$wt_dir" ]] || die "worktree '$slug' が見つかりません: $wt_dir"

  # 作業内容の消失は取り返しがつかないので、未コミット・未 push は既定で止める。
  if [[ "$force" -eq 0 ]]; then
    if [[ -n "$(git -C "$wt_dir" status --porcelain)" ]]; then
      die "'$slug' に未コミットの変更があります。コミットするか --force を付けてください。"
    fi
    local upstream
    if upstream="$(git -C "$wt_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
      if [[ -n "$(git -C "$wt_dir" log --oneline "$upstream..HEAD")" ]]; then
        die "'$slug' に push されていないコミットがあります。push するか --force を付けてください。"
      fi
    else
      die "'$slug' のブランチに upstream がありません。push するか --force を付けてください。"
    fi
  fi

  local db
  db="$(db_name_for "$slug")"

  # DB の削除は接続を要するため最も失敗しやすい。ここで落ちれば他は無傷で済むよう先に行う。
  info "データベースを削除中: $db"
  psql -q -c "DROP DATABASE IF EXISTS \"${db}\" WITH (FORCE)"

  info "traefik ルートを削除中"
  rm -f "$(route_path_for "$slug")"

  info "worktree を削除中: $wt_dir"
  git -C "$MAIN_ROOT" worktree unlock "$wt_dir" 2>/dev/null || true
  if [[ "$force" -eq 1 ]]; then
    git -C "$MAIN_ROOT" worktree remove --force "$wt_dir"
  else
    git -C "$MAIN_ROOT" worktree remove "$wt_dir"
  fi
  git -C "$MAIN_ROOT" worktree prune

  info "'$slug' を撤去しました"
}

# docker compose down -v や DB の作り直しの後、チェックアウトを正として
# 失われた DB とルートを復元する。
cmd_sync() {
  cmd_init

  local file slug port api_port db route
  local -a known=()

  for file in "$WORKTREES_DIR"/*/.env.worktree; do
    [[ -f "$file" ]] || continue
    slug="$(basename "$(dirname "$file")")"
    port="$(read_env_value "$file" PORT)"
    api_port="$(read_env_value "$file" API_PORT)"
    db="$(db_name_for "$slug")"
    known+=("wt-${slug}.yaml")

    ensure_database "$db"
    write_route_file "$slug" "$port" "$api_port"
    info "同期しました: $slug (ports=${port}/${api_port} db=${db})"
  done

  # チェックアウトが消えているのにルートだけ残っている場合を掃除する。
  for route in "$TRAEFIK_DIR"/wt-*.yaml; do
    [[ -f "$route" ]] || continue
    local name
    name="$(basename "$route")"
    local orphan=1 k
    for k in ${known[@]+"${known[@]}"}; do
      [[ "$k" == "$name" ]] && orphan=0 && break
    done
    if [[ "$orphan" -eq 1 ]]; then
      info "対応する worktree が無いルートを削除: $name"
      rm -f "$route"
    fi
  done
}

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's|^#[[:space:]]\?||'
}

main() {
  case "${1:-}" in
    -h | --help | "")
      usage
      exit 0
      ;;
  esac

  require_devenv

  MAIN_ROOT="$(resolve_main_root)"
  WORKTREES_DIR="$MAIN_ROOT/.worktrees"
  TRAEFIK_DIR="$MAIN_ROOT/docker/traefik/dynamic"
  readonly MAIN_ROOT WORKTREES_DIR TRAEFIK_DIR

  [[ -d "$TRAEFIK_DIR" ]] || die "traefik の監視ディレクトリがありません: $TRAEFIK_DIR"

  local subcommand="$1"
  shift
  case "$subcommand" in
    init)   cmd_init "$@" ;;
    add)    cmd_add "$@" ;;
    list)   cmd_list "$@" ;;
    remove) cmd_remove "$@" ;;
    sync)   cmd_sync "$@" ;;
    *)
      echo "error: unknown subcommand '$subcommand'" >&2
      echo "" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
