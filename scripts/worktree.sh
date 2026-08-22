#!/usr/bin/env bash
#
# dev コンテナ内で git worktree を管理する。
#
# 1 つの dev コンテナの中に複数の worktree を並べ、チェックアウト・ポート・DB・
# traefik ルートを worktree 単位で論理分割する。ホスト側の操作は不要。
#
# Usage:
#   scripts/worktree.sh init                基点チェックアウトの実行時設定を用意する
#   scripts/worktree.sh add <branch>        worktree を作成し一式を用意する
#   scripts/worktree.sh provision [<path>]  worktree（既定は現在地）の副資源を冪等に用意する
#   scripts/worktree.sh provision --gc      対応する worktree の無い DB・ルートを刈り取る
#   scripts/worktree.sh list                worktree と割り当て済みリソースを一覧する
#   scripts/worktree.sh remove <slug>       worktree と一式を撤去する
#   scripts/worktree.sh sync                全 worktree を正として DB とルートを再生成する
#
# provision は作成主体を問わない。外部ツール（claude -w 等）が作った worktree でも、
# その中で provision を叩けば .env.worktree・DB・ルート・依存が一式そろう（uv sync 相当）。
#
# Options:
#   add        --no-install   依存関係のインストール（uv sync / deno install）を省く
#   provision  --no-install   同上
#   remove     --force        未コミットの変更があっても撤去する
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
  # 採番の critical section を直列化するのに使う。複数エージェントが別 worktree を同時に
  # provision したときのポート二重採番を防ぐため必須。
  command -v flock >/dev/null || die "flock が見つかりません。dev コンテナ内で実行してください。"

  # worktree の管理情報を相対パスで記録するために必須（Git 2.48 以降）。絶対パスで
  # 記録されると、ホストとコンテナでマウント先が違うせいで prune 対象になってしまう。
  # `-h` は終了コード 129 を返すため、pipefail に巻き込まれないよう握りつぶす。
  { git worktree add -h 2>&1 || true; } | grep -q "relative-paths" \
    || die "git が --relative-paths に対応していません（Git 2.48 以降が必要）。"
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

# 割り当て済みポートを持つ .env.worktree を、worktree の置き場所に依存せず列挙する。
# `.worktrees/` 配下を glob すると、外部ツール（claude -w 等）がリポジトリ外に切った
# worktree を採番時に見落とし、ポートが衝突しうる。git を正として全 worktree を辿り、
# 各チェックアウト直下の .env.worktree を拾う。基点チェックアウトも含まれるが、
# 基点のポート（3000/8000）は worktree の採番区間（3100+/8100+）と重ならない。
worktree_env_files() {
  local line path
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path="${line#worktree }"
        [[ -f "$path/.env.worktree" ]] && printf '%s\n' "$path/.env.worktree"
        ;;
    esac
  done < <(git -C "$MAIN_ROOT" worktree list --porcelain)
  return 0
}

# 使用中のポートは .env.worktree 自身が持つ。別途レジストリを置くと実体と乖離するため、
# 割り当て済みポートは毎回チェックアウトから読み直す。
allocate_index() {
  local used=() file port i
  while IFS= read -r file; do
    port="$(read_env_value "$file" PORT)"
    [[ -n "$port" ]] && used+=("$port")
  done < <(worktree_env_files)

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

# 外部ツール（claude -w 等）が --relative-paths を付けずに worktree を作っても、
# 管理情報が相対パスで記録されるようリポジトリ既定にする（Git 2.48+）。ホストと
# コンテナでマウント先が違うため、絶対パス記録は git gc が誘発する prune 事故の原因になる。
# add は明示フラグでも相対にしているが、こちらは「外部ツール経由の add」を守るための保険。
ensure_relative_paths_config() {
  local current
  current="$(git -C "$MAIN_ROOT" config --get worktree.useRelativePaths 2>/dev/null || true)"
  if [[ "$current" != "true" ]]; then
    git -C "$MAIN_ROOT" config worktree.useRelativePaths true
    info "git config worktree.useRelativePaths=true を設定（外部ツール製 worktree の絶対パス記録を防ぐ）"
  fi
}

# 別の worktree が同じ slug を確保していないか確認する。異なるブランチ名でも slugify 後に
# 衝突しうる（feat/foo と feat-foo など）。DB とサブドメインが混線するため止める。
ensure_slug_unused() {
  local want="$1" self="$2" file other
  while IFS= read -r file; do
    local dir
    dir="$(dirname "$file")"
    [[ "$dir" -ef "$self" ]] && continue
    other="$(read_env_value "$file" WORKTREE_SLUG)"
    [[ "$other" == "$want" ]] \
      && die "slug '$want' は既に別の worktree が使用中です: $dir"
  done < <(worktree_env_files)
  # while ループの最後の比較が偽だと終了ステータス 1 が漏れ、set -e で呼び出し元を
  # 巻き込む。ここまで来たら衝突は無いので明示的に成功を返す。
  return 0
}

# 1 つの worktree（チェックアウト）を冪等に収束させる。uv sync に相当する処理単位で、
# worktree の作成主体（add / claude -w / 素の git worktree add）に依存しない。
#   - .env.worktree があればそれを正として再利用する（= lock 兼キャッシュ）
#   - 無ければブランチ名から slug を導出し、空きポートを新規採番して書き出す
# その後 DB とルートを揃え、既定で依存関係をインストールする。
provision_worktree() {
  local wt_dir="$1" no_install="$2"
  local env_file slug port api_port db branch

  env_file="$wt_dir/.env.worktree"
  if [[ -f "$env_file" ]]; then
    slug="$(read_env_value "$env_file" WORKTREE_SLUG)"
    port="$(read_env_value "$env_file" PORT)"
    api_port="$(read_env_value "$env_file" API_PORT)"
    [[ -n "$slug" && -n "$port" && -n "$api_port" ]] \
      || die "$env_file が壊れています（WORKTREE_SLUG/PORT/API_PORT が読めません）。remove して作り直してください。"
  else
    branch="$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
      || die "worktree のブランチを解決できません: $wt_dir"
    [[ "$branch" != "HEAD" ]] \
      || die "detached HEAD の worktree は provision できません（ブランチが必要）: $wt_dir"
    slug="$(slugify "$branch")"
    [[ -n "$slug" ]] || die "ブランチ名 '$branch' から slug を作れません"
    [[ "$slug" != "base" ]] || die "'base' は基点チェックアウト用に予約されています"
    # PostgreSQL の識別子は 63 バイトで黙って切り詰められ、別 worktree と同じ DB を
    # 指してしまう。そうなる前に止める。
    [[ "${#slug}" -le 40 ]] || die "ブランチ名が長すぎます（slug '$slug' は 40 文字以内にしてください）"

    # slug 衝突チェック・空きポート採番・.env.worktree 書き出しは、他 worktree の
    # .env.worktree 群という共有状態を読んで書くため、flock で直列化する。ここさえ直列なら
    # 複数エージェントが別々の worktree を同時に provision してもポートは二重採番されない。
    # DB 作成・依存インストールはロックの外なので並行できる。
    mkdir -p "$WORKTREES_DIR"
    (
      flock 9 || die "採番ロックを取得できません: $LOCK_FILE"
      # ロック待ちの間に他プロセスが同じ worktree を用意していたら上書きしない。
      if [[ ! -f "$env_file" ]]; then
        ensure_slug_unused "$slug" "$wt_dir"
        local idx
        idx="$(allocate_index)"
        write_env_file "$env_file" "$slug" \
          "$((WT_PORT_BASE + idx))" "$((WT_API_PORT_BASE + idx))" \
          "http://${slug}.${DOMAIN}:${PROXY_PORT}" \
          "http://api-${slug}.${DOMAIN}:${PROXY_PORT}" \
          "$(db_name_for "$slug")"
      fi
    ) 9>"$LOCK_FILE"

    # 確定値はファイルから読み直す（採番はサブシェル内なので変数が親に伝播しない）。
    port="$(read_env_value "$env_file" PORT)"
    api_port="$(read_env_value "$env_file" API_PORT)"
    info "実行時設定を生成: $env_file (ports=${port}/${api_port})"
  fi

  db="$(db_name_for "$slug")"
  info "データベースを用意中: $db"
  ensure_database "$db"

  info "traefik ルートを生成中: $(route_path_for "$slug")"
  write_route_file "$slug" "$port" "$api_port"

  if [[ "$no_install" -eq 0 ]]; then
    info "依存関係をインストール中（--no-install で省略可）"
    (cd "$wt_dir" && uv sync && deno install --allow-scripts --frozen)
  fi
}

# 対応する worktree の無い DB・ルートを刈り取る。作成を外部ツールに委ねると撤去も
# 外部（git worktree remove）で行われ、DB とルートだけが残る。git を正として孤児を掃除する。
gc_orphans() {
  local file slug
  local -a known_db=() known_route=()
  while IFS= read -r file; do
    slug="$(read_env_value "$file" WORKTREE_SLUG)"
    [[ -n "$slug" && "$slug" != "base" ]] || continue
    known_db+=("$(db_name_for "$slug")")
    known_route+=("wt-${slug}.yaml")
  done < <(worktree_env_files)

  local datname in_use k
  while IFS= read -r datname; do
    [[ -n "$datname" ]] || continue
    in_use=0
    for k in ${known_db[@]+"${known_db[@]}"}; do
      [[ "$k" == "$datname" ]] && in_use=1 && break
    done
    if [[ "$in_use" -eq 0 ]]; then
      info "対応する worktree の無い DB を削除: $datname"
      psql -q -c "DROP DATABASE IF EXISTS \"${datname}\" WITH (FORCE)"
    fi
  done < <(psql -tAc "SELECT datname FROM pg_database WHERE datname LIKE 'wt\_%'")

  local route name
  for route in "$TRAEFIK_DIR"/wt-*.yaml; do
    [[ -f "$route" ]] || continue
    name="$(basename "$route")"
    in_use=0
    for k in ${known_route[@]+"${known_route[@]}"}; do
      [[ "$k" == "$name" ]] && in_use=1 && break
    done
    if [[ "$in_use" -eq 0 ]]; then
      info "対応する worktree の無いルートを削除: $name"
      rm -f "$route"
    fi
  done
  return 0
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

  mkdir -p "$WORKTREES_DIR"

  # --relative-paths が要。管理情報を絶対パスで記録すると、ホストとコンテナで
  # マウント先が違うせいでホスト側からは存在しないパスに見え、git gc が誘発する
  # prune の対象になってしまう。相対パスならどちらから見ても正しく解決される。
  info "worktree を作成中: $wt_dir (branch: $branch)"
  if git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$MAIN_ROOT" worktree add --relative-paths "$wt_dir" "$branch"
  elif git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$MAIN_ROOT" worktree add --relative-paths --track -b "$branch" "$wt_dir" "origin/$branch"
  else
    git -C "$MAIN_ROOT" worktree add --relative-paths -b "$branch" "$wt_dir"
  fi

  # 副資源（.env.worktree・DB・ルート・依存）の用意は provision に委ねる。add は
  # 「worktree そのものの作成」だけを担い、それ以降は作成主体を問わない共通処理になる。
  provision_worktree "$wt_dir" "$no_install"

  echo ""
  info "準備完了"
  print_worktree_dir "$wt_dir"
  echo ""
  echo "  開発を始めるには:"
  echo "    cd $wt_dir"
  echo "    deno task web      # フロント開発サーバー"
  echo "    uv run task api    # API"
}

# worktree の場所に依存せず、その .env.worktree を読んで 1 件表示する。
print_worktree_dir() {
  local wt_dir="$1"
  local file slug branch port api_port db
  file="$wt_dir/.env.worktree"
  slug="$(read_env_value "$file" WORKTREE_SLUG)"
  port="$(read_env_value "$file" PORT)"
  api_port="$(read_env_value "$file" API_PORT)"
  db="$(db_name_for "$slug")"
  branch="$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"

  printf '  %-16s branch=%-24s ports=%s/%s db=%s\n' "$slug" "$branch" "$port" "$api_port" "$db"
  printf '  %-16s web=http://%s.%s:%s  api=http://api-%s.%s:%s\n' \
    "" "$slug" "$DOMAIN" "$PROXY_PORT" "$slug" "$DOMAIN" "$PROXY_PORT"
}

print_worktree() {
  print_worktree_dir "$WORKTREES_DIR/$1"
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
  if [[ "$force" -eq 1 ]]; then
    git -C "$MAIN_ROOT" worktree remove --force "$wt_dir"
  else
    git -C "$MAIN_ROOT" worktree remove "$wt_dir"
  fi
  git -C "$MAIN_ROOT" worktree prune

  info "'$slug' を撤去しました"
}

# チェックアウト（の中）を正として、その worktree の副資源を冪等に収束させる。
# uv sync 相当。作成主体を問わず、外部ツールが作った worktree もここで一式が揃う。
#   scripts/worktree.sh provision              いま居る worktree を provision する
#   scripts/worktree.sh provision <path>       指定した worktree を provision する
#   scripts/worktree.sh provision --gc         孤児 DB・ルートを刈り取る
cmd_provision() {
  local target="" no_install=0 gc=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-install) no_install=1 ;;
      --gc) gc=1 ;;
      -*) die "unknown option '$1'" ;;
      *) [[ -n "$target" ]] && die "パスは 1 つだけ指定してください"; target="$1" ;;
    esac
    shift
  done

  if [[ "$gc" -eq 1 ]]; then
    [[ -z "$target" && "$no_install" -eq 0 ]] || die "--gc は単独で指定してください"
    gc_orphans
    return 0
  fi

  local wt_dir
  if [[ -n "$target" ]]; then
    wt_dir="$(cd "$target" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" \
      || die "worktree ではありません: $target"
  else
    wt_dir="$(git rev-parse --show-toplevel 2>/dev/null)" \
      || die "worktree の中で実行してください（またはパスを指定してください）"
  fi

  # 基点チェックアウトは init が扱う（サブドメイン無し・固定ポート・共有 DB）。
  if [[ "$wt_dir" -ef "$MAIN_ROOT" ]]; then
    cmd_init
    return 0
  fi

  provision_worktree "$wt_dir" "$no_install"
  echo ""
  info "準備完了"
  print_worktree_dir "$wt_dir"
}

# docker compose down -v や DB の作り直しの後、全 worktree を正として
# 失われた DB とルートを一括で復元し、孤児を刈り取る。
cmd_sync() {
  cmd_init

  local file wt_dir
  while IFS= read -r file; do
    wt_dir="$(dirname "$file")"
    [[ "$wt_dir" -ef "$MAIN_ROOT" ]] && continue   # 基点は cmd_init が済ませた
    provision_worktree "$wt_dir" 1                  # 依存は down -v で消えないので入れ直さない
  done < <(worktree_env_files)

  gc_orphans
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
  # 採番＋.env.worktree 書き出しを直列化するためのロック。.worktrees/ は gitignore 済み。
  LOCK_FILE="$WORKTREES_DIR/.alloc.lock"
  readonly MAIN_ROOT WORKTREES_DIR TRAEFIK_DIR LOCK_FILE

  [[ -d "$TRAEFIK_DIR" ]] || die "traefik の監視ディレクトリがありません: $TRAEFIK_DIR"

  # 外部ツール製の worktree も相対パスで記録されるよう、どのコマンドでも既定を担保する。
  ensure_relative_paths_config

  local subcommand="$1"
  shift
  case "$subcommand" in
    init)      cmd_init "$@" ;;
    add)       cmd_add "$@" ;;
    provision) cmd_provision "$@" ;;
    list)      cmd_list "$@" ;;
    remove)    cmd_remove "$@" ;;
    sync)      cmd_sync "$@" ;;
    *)
      echo "error: unknown subcommand '$subcommand'" >&2
      echo "" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
