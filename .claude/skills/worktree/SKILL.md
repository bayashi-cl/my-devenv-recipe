---
name: worktree
description: このリポジトリで git worktree を作成・一覧・撤去するときに使う。worktree ごとに DB・ポート・traefik ルートの割り当てが必要なため、`git worktree` を直接叩かず必ずこの手順に従う。「worktree を作って」「別ブランチで並行して作業したい」「使い終わった worktree を片付けて」といった依頼で使用する。
---

# worktree の管理

このリポジトリの worktree は、**dev コンテナ 1 つの中に並べて**運用する。worktree ごとに
コンテナを立てることはしない。分離はコンテナではなく、チェックアウト単位の

- `.env.worktree`（実行時設定: オリジン・ポート・接続先 DB）
- 専用データベース `wt_<slug>`
- traefik の動的ルート `docker/traefik/dynamic/wt-<slug>.yaml`

によって行う。これらを揃えるのが `scripts/worktree.sh` の役割であり、**`git worktree add` を
直接実行してはいけない**（設定・DB・ルートが無いまま開発サーバーが起動できない状態になる）。

## コマンド

すべて dev コンテナ内から実行する。基点チェックアウト・worktree のどちらから実行してもよい。

```sh
scripts/worktree.sh add <branch>      # worktree を作成し一式を用意する
scripts/worktree.sh list              # worktree と割り当て済みリソースを一覧する
scripts/worktree.sh remove <slug>     # worktree と一式を撤去する
scripts/worktree.sh sync              # .env.worktree を正として DB とルートを再生成する
scripts/worktree.sh init              # 基点チェックアウトの実行時設定を用意する
```

`add` はブランチが未作成なら作成し、`origin/<branch>` があれば追跡ブランチとして
チェックアウトする。`--no-install` を付けると依存関係のインストール（`uv sync` /
`deno install`）を省略でき、確認だけしたいときに速い。

## worktree で開発する

`add` が出力したパスへ移動してから、通常どおりタスクを起動する。

```sh
cd .worktrees/<slug>
deno task web      # フロント開発サーバー
uv run task api    # API
```

待ち受けポート・CORS のオリジン・接続先 DB は、いずれもそのディレクトリの
`.env.worktree` から読まれる。**`.env.worktree` を手で編集しない**。ポートを書き換えると
traefik のルートと食い違い、疎通しなくなる。

アクセス先は `add` / `list` が表示する `http://<slug>.${DOMAIN}:8080`（API は
`http://api-<slug>.${DOMAIN}:8080`）。基点チェックアウトは `http://${DOMAIN}:8080`。

## 撤去

```sh
scripts/worktree.sh remove <slug>
```

未コミットの変更、未 push のコミット、upstream 未設定のいずれかがあると既定で中断する。
その状態で撤去してよいか判断できないときは、**勝手に `--force` を付けず利用者に確認する**。
`remove` はローカルブランチを消さないので、同じブランチで `add` をやり直せる。

## 注意点

- **worktree を手動で `git worktree add` しない。** DB・ポート・ルートが揃わないだけでなく、
  管理情報が絶対パスで記録される。ホストとコンテナではリポジトリのマウント先が違うため、
  絶対パスだと一方からは存在しないパスに見え、`git worktree prune` で管理情報を失う。
  `scripts/worktree.sh` は `--relative-paths` を付けてこれを回避している。
- **`add` が途中で失敗した場合**は `remove <slug> --force` で片付けてからやり直す。DB や
  ルートだけが欠けている状態なら `sync` で復旧できる。
- **`docker compose down -v` の後**は DB が消えているので `sync` を実行する。worktree の
  チェックアウト自体はリポジトリ内 `.worktrees/` にあるため失われない。
- 全 worktree が同じコンテナ・同じ CPU/メモリを共有する。重いビルドを複数同時に走らせない。
- `docker compose` の実行はホスト側の操作であり、エージェントが行う場面は無い。
