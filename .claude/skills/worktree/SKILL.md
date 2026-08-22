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

によって行う。これらを揃えるのが `scripts/worktree.sh` の役割である。

作成から一式の用意までを一度に行うなら `add` を使う。一方、副資源の用意（`.env.worktree`・
DB・ルート・依存のインストール）は `provision` という**作成主体を問わない冪等な処理**に
切り出してある。外部ツール（`claude -w` など）や素の `git worktree add` で作られた worktree でも、
その中で `provision` を叩けば一式がそろう（`uv sync` と同じ感覚で使える）。設定・DB・ルートが
無いまま開発サーバーを起動しようとすると失敗するので、**作成しただけの worktree は必ず
`provision` する**こと。

## コマンド

すべて dev コンテナ内から実行する。基点チェックアウト・worktree のどちらから実行してもよい。

```sh
scripts/worktree.sh add <branch>        # worktree を作成し一式を用意する
scripts/worktree.sh provision [<path>]  # worktree（既定は現在地）の副資源を冪等に用意する
scripts/worktree.sh provision --gc      # 対応する worktree の無い DB・ルートを刈り取る
scripts/worktree.sh list                # worktree と割り当て済みリソースを一覧する
scripts/worktree.sh remove <slug>       # worktree と一式を撤去する
scripts/worktree.sh sync                # 全 worktree を正として DB とルートを再生成する
scripts/worktree.sh init                # 基点チェックアウトの実行時設定を用意する
```

`add` はブランチが未作成なら作成し、`origin/<branch>` があれば追跡ブランチとして
チェックアウトする。`--no-install` を付けると依存関係のインストール（`uv sync` /
`deno install`）を省略でき、確認だけしたいときに速い。

`provision` は既存の `.env.worktree` があればそれを正として再利用し（ポート等は変えない）、
無ければブランチ名から slug を導出して空きポートを新規採番する。冪等なので何度叩いてもよい。
外部ツールで worktree を作ったときはその中で `provision` を実行する。ポートの採番は
`git worktree list` が返す全 worktree を走査するため、`.worktrees/` の外に作られた worktree も
見落とさず衝突しない。

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

外部ツールや素の `git worktree remove` で worktree を消すと、DB とルートだけが取り残される。
`scripts/worktree.sh provision --gc` を叩くと、対応する worktree が無い `wt_*` DB と
`wt-*.yaml` ルートを刈り取れる。

## 注意点

- **外部ツールや素の `git worktree add` で作った場合は必ず `provision` する。** そのままでは
  DB・ポート・ルートが揃わず、開発サーバーが起動できない。`provision` は場所を問わず一式を用意する。
- **worktree の管理情報は相対パスで記録される必要がある。** ホストとコンテナではリポジトリの
  マウント先が違うため、絶対パスだと一方からは存在しないパスに見え、`git worktree prune` で
  管理情報を失う。`scripts/worktree.sh` は自身の `add` に `--relative-paths` を付けるだけでなく、
  実行時に `git config worktree.useRelativePaths true` を担保するので、外部ツール経由の
  `git worktree add`（`--relative-paths` を付けない）でも相対パスで記録される（Git 2.48 以降が必要）。
- **`add` が途中で失敗した場合**は `remove <slug> --force` で片付けてからやり直す。DB や
  ルートだけが欠けている状態なら `sync` で復旧できる。
- **`docker compose down -v` の後**は DB が消えているので `sync` を実行する。worktree の
  チェックアウト自体はリポジトリ内 `.worktrees/` にあるため失われない。
- 全 worktree が同じコンテナ・同じ CPU/メモリを共有する。重いビルドを複数同時に走らせない。
- `docker compose` の実行はホスト側の操作であり、エージェントが行う場面は無い。
