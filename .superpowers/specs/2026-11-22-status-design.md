# --status (-S): 今の状況を見る

## 目的

ライブコンテナ、`--with` の派生イメージ、`.dozorc` の既定のイメージ、ラベルでの探索と、
dozo が作るもの・決めることが増え、今どうなっているかを把握しにくくなった
（利用者の言葉で「イメージやコンテナの管理が複雑になってきました」）。
dozo 自身で、次の 2 つを見られるようにする。

1. ここ（今のディレクトリ）で dozo を実行すると何が起きるか、それはなぜか
2. dozo が作ったライブコンテナと派生イメージの一覧と、片付けてよいもの

## 決まったこと

- オプションは `--status`、短い形は `-S`（設計者の判断。今は空いている）。
- 出力は stdout。何も作らず、起動もせず、消しもしない（読むだけ）。
- 3 つの部分を出す: here（見通し）、live containers（一覧）、derived images（一覧）。
  一覧の中で、今のディレクトリに関係する行に `*` を付ける。
- 片付け: dozo は消さない。消してよいものがあれば、消すコマンド
  （`docker image rm ...`, `docker rm ...`）を最後に表示し、利用者がコピーして使う。
- 判断は、実行するときと同じ処理を通る。オプション（`.dozorc` を含む）を読み、
  ラベルでコンテナを探し、`--with` のキャッシュを確かめるところまでは普段どおりで、
  kill / live / run の直前で status を表示して終了する。別の実装を持たない
  （表示と実際の動作がずれるため）。
- ほかのオプションと一緒に使える: `dozo -I alpine -S`、`dozo -N foo -S`、
  `dozo --with x -S` などで「そう指定したらどうなるか」を見せる。
- コマンド（引数）を付けたら、エラーにする（`--status takes no command`）
  （設計者の判断: 黙って無視すると、実行されたと誤解する）。

### here

今の指定で `-L` を使ったときの見通しを示す（`-L` がなくても `-L` として見る。
dozo の状況でいちばん分かりにくいのがライブコンテナのため）。

- マウントするディレクトリ（`dozo.mount` に書く物理パス）。
- イメージと、それがどこで決まったか: コマンドライン（`-I` / `-D`）、`.dozorc`
  （どのファイルか）、ラベルで見つけたコンテナ、決まっていない。
- `dozo -L` がつながるコンテナ: 名前、状態（running / exited / ...）、
  見つけ方（ラベル / 名前）。なければ「作る: <名前> from <イメージ>」、
  イメージもなければ、今のエラーと同じ内容。複数見つかれば、それを並べる。
- `--with` があれば、使う派生イメージのタグと、あるか（なければ「次に使うときに作る」。
  ビルドはしない）。feature が見つからなければ、そう表示する（終了しない）。
- 今の知らせ（`-A` / `--with` が既存コンテナに効かない、イメージ違い、
  別ディレクトリのコンテナ）に当たるものを `note` として出す。取り違えのエラー
  （別ディレクトリ）も、status では終了せずに note にする。

### live containers

dozo のライブコンテナを並べる。列: 名前、状態、イメージ、ディレクトリ、備考。

- 見つけ方: `docker ps -a` のコンテナのうち、ラベル `dozo.mount` があるもの、
  またはラベルはないが環境変数 `DOZO_RUNNING_ON_DOCKER=1` を持つもの
  （この変更より前の dozo で作ったもの。dozo は必ずこれを渡す。docker 29.8.2 で
  `docker inspect` の `.Config.Env` に見えることを確認）。`--rm` で動いている
  一時的なもの（`.HostConfig.AutoRemove` が true）は含めない。
- イメージは `dozo.image`、なければ `.Config.Image`。`--with` で作ったものは、
  `.Config.Image` が派生イメージのタグなので、元のイメージと feature も分かれば示す。
- ディレクトリは `dozo.mount`、なければ `/work` にマウントしたホストのパス。
  ラベルのないものは備考に `no label`（`-I` なしの `dozo -L` では見つからない）。
- 備考: ディレクトリがもうない（`gone`）、元のイメージが新しくなっている
  （コンテナのイメージ ID と今のイメージ ID が違う。`-KL` で作り直せる）。
- 片付けの候補: ディレクトリがもうないコンテナ（`docker rm`）。

### derived images

`--with` の派生イメージ（ラベル `dozo.base` のあるイメージ）を並べる。
列: タグ、元のイメージ（`dozo.base`）、feature（`dozo.with`）、状態、作った時期。

- 状態:
  - `current`: 今の feature と元のイメージから計算したタグと一致する（使われる）。
    途中の段（`dozo.with` が `a,b` の途中の `a`）も、その段の計算と一致すれば current。
  - `outdated`: 一致しない（feature を書き換えた、元のイメージが新しくなった）。
  - `feature gone`: feature が見つからない。
  - `base gone`: 元のイメージが手元にない。
- 計算は `with_image -c` と同じ処理で行う（`image=dozo.base`、
  `with_names=dozo.with を , で分けたもの`）。die で止まらないよう、サブシェルで行う。
- 大きさは出さない（設計者の判断: `docker image ls` の SIZE は元のイメージとの共有分を
  含み、消して空く量と大きく違うため。今日の brew で 2.06GB と出たが実際はわずか）。
- 片付けの候補: current 以外（`docker image rm`）。ライブコンテナが使っているものは
  候補から外す（消せないため）。

## 出力の例（形は実装者に任せる）

```
$ cd ~/Clone/ir_report_checklist && dozo -S
here: /Users/utashiro/Clone/ir_report_checklist
  image      tecolicom/xlate (from ~/.dozorc -D)
  container  xlate.ir_report_checklist, exited (found by label)
  --with     locale: dozo/xlate:locale-3580643729 (exists)
  note       the container is not made with --with; dozo -KL to recreate it

live containers:
  NAME                        STATUS   IMAGE            DIRECTORY
* xlate.ir_report_checklist   exited   tecolicom/xlate  ~/Clone/ir_report_checklist
* brew.ir_report_checklist    exited   homebrew/brew    ~/Clone/ir_report_checklist
  xlate.old                   exited   tecolicom/xlate  ~/old (gone, no label)

derived images:
  IMAGE                          BASE             WITH    STATE     CREATED
* dozo/xlate:locale-3580643729   tecolicom/xlate  locale  current   2 hours ago
  dozo/brew:locale-2017098170    homebrew/brew    locale  outdated  7 hours ago

to clean up:
  docker rm xlate.old
  docker image rm dozo/brew:locale-2017098170
```

この例のように、同じディレクトリのコンテナが複数ある（ラベルの付いた xlate と brew）
と、`-I` なしの `dozo -L` はエラーになる。here にはそれを出す。

## 検討した方法

- 別のスクリプト（`dozo-status`）: 判断の処理を二重に持ち、ずれていくので不採用。
- `-n`（dryrun）を広げる: docker のコマンドしか分からず、理由も一覧も出せないので不採用。
- `--prune` で dozo が消す: 取り消せない操作を dozo に持たせるので不採用。
  消すコマンドを表示するだけにする（利用者が選んだ）。

## 前提・制約

- bash 4.4 以降と docker だけで動く（perl を使わない。`--bundle` の性質を保つ）。
- docker への問い合わせを抑える: `docker ps -a -q` 1 回、コンテナの `docker inspect`
  をまとめて 1 回、`docker image ls --filter label=dozo.base` 1 回、派生イメージの
  判定に `image inspect`（段ごと）。数十個で 1 秒程度に収まればよい。
- `-S` を使わないときの動作は変えない。

## 実装者に任せる点

- 出力の細かい形（列の幅、ホームを `~` にするか、色は付けない）。
- `.dozorc` のどのファイルでイメージが決まったかの調べ方（ファイルごとに parse を
  分けるなど）。分からなければ「.dozorc」とだけ出してもよい。
- 状態の時期の表示（`docker image ls` の `CreatedSince` など）。
- POD: OPTIONS に `-S`、LIVE CONTAINER と FEATURES の片付けの説明から `-S` を案内。
- テスト: スタブで、here の各場合（コマンドライン / .dozorc / ラベル、見つからない、
  複数、`--with` の有無）、一覧（ラベルあり / なし / 一時的なもの / ディレクトリなし）、
  派生イメージの状態、片付けのコマンド、コマンド付きでエラー、何も作らないこと
  （`run` / `build` / `rm` を呼ばない）。実機で、ライブコンテナと派生イメージを
  作って `-S` の出力を確かめる。

## 設計者の判断（レビューの質問への答え）

- **読むだけを最優先する**: `-S` は、普段の処理と同じ判断を通るが、docker を変える
  操作（pull, build, rm, run, start, exec）は一つもしない。「同じ道筋」は判断の
  部分を指す。
  - `-A`: pull しない。here に「`-A`: would pull <image>（既存コンテナには効かない）」と出す。
  - `--with`: `with_image -c` だけを使う。ないものは「次に使うときに作る」と出す。
  - `-K` / `-KL`: 消さない。here に「would remove <名前>」、`-KL` なら続けて
    「then create from <イメージ>」と出す。`-KL` でイメージが分からないときは、
    今のエラーと同じ内容を出す。
- **here は常に -L として見る**: `$live` がなくても、`-L` のときの探索（ラベル、
  `.dozorc` のイメージは既定値、複数見つかったときの扱い）を通す。`-N` や
  コマンドラインの `-I` があるときは名前で探し（`docker_find`）、見つけ方を
  「by name (-N)」「by name (from -I)」と出す。
- **--with のコンテナとの比較**: 今の知らせと同じく、派生イメージの ID
  （`with_image -c` が成り立つとき）とコンテナのイメージ ID を比べる。派生イメージが
  まだないときは「the container is not made with --with」とし、作るとは書かない。
- **derived images の current**: 今の feature ディレクトリにある feature と、
  `dozo.base` の名前で手元にある元のイメージから計算する。`.dozorc` の `--with` とは
  関係しない。`dozo.with` には `NAME/ARG` がそのまま入っているので `,` で分ける。
  `dozo.base` の名前で `image inspect` できなければ `base gone`。
- **終了コード**: here に「エラーに当たること」（イメージがない、複数ある、
  別ディレクトリ）があっても 0。status を出せたら 0、docker に問い合わせられない
  ときだけ 0 以外。普段の `warn`（stderr）はそのまま出る。テストは stdout を見る。
- **`*` の判定**: `dozo.mount`、ラベルがなければ `/work` にマウントしたホストのパスを
  物理パスにして、here のディレクトリ（`live_mount`）と比べる。`/work` 以外の
  マウントは見ない。
