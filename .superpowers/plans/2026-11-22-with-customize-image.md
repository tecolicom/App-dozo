# --with（feature で任意のイメージを拡張する）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `dozo --with=NAME[,NAME...]` で、元イメージに feature（Dockerfile の断片）を 1 段ずつ重ねた派生イメージを作り、使い回して実行する。

**Architecture:** `script/dozo` に feature 用の関数群を足す。各段のタグを「親イメージ ID + feature の中身」の cksum から決め、`docker image inspect` で有無を確かめ、なければ `docker build` する。最終段のイメージを `run_image` として `docker run` に使う。`$image`（元イメージ）はコンテナ名・ホスト名にそのまま使う。

**Tech Stack:** Bash 4.4+、getoptlong.sh、docker CLI、Perl Test::More

**Spec:** `.superpowers/specs/2026-11-22-with-customize-image-design.md`

## Global Constraints

- `--with` がないときは、今の動作と完全に同じ（`docker image inspect` も増やさない）。
- 標準出力はコマンドの出力専用。ビルド・pull の出力は標準エラーへ。`-q` では出さない。
- bash と docker と、macOS / Linux の両方にある道具（`cksum`, `find`, `sort`, `mktemp`）だけを使う。`sha256sum` / `shasum` は使わない。
- 区切りは `,` だけ。`:` は区切りにしない。
- feature の置き場所は `${XDG_CONFIG_HOME:-$HOME/.config}/dozo/features/NAME`。
- POD は `script/dozo` だけを編集する。
- コミットメッセージは既存の英語の書き方。末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`、`Claude-Session:` 行は入れない。

## Review Focus

- `$HOME` が変わる `-H`（`--mount-home`）: feature の置き場所は**ホスト**の `$HOME` で決まり、コンテナ内の `HOME=/work` に影響されないこと。→ Task 1 のテスト `-H does not move the feature directory`。
- `USER` が UID（例 `1000`）や `user:group` のイメージ: 最後に戻す `USER` が元の値そのままで、`DOZO_USER` も同じ値になること。→ Task 1 のテスト `USER is restored as given`。
- feature ディレクトリのファイルを 1 つ変えただけで、その段とそれより後ろの段だけが作り直されること（前の段は使い回す）。→ Task 3 の実機テスト `changing a later feature rebuilds only that stage`。
- 元イメージが手元になく、pull もできない（オフラインなど）とき: 分かるエラーで止まり、コマンドを実行しないこと。→ Task 1 のテスト `missing base image that cannot be pulled`。
- feature 名にスラッシュや `..` が入ったとき: 置き場所の外を読まずにエラーにすること。→ Task 1 のテスト `feature name with a slash`。

---

### Task 1: feature の解決・タグ計算・ビルド（使い捨て実行）

**Files:**
- Modify: `script/dozo`（OPTS に `with` を追加、SYNOPSIS に 1 行、関数群を `pull_image` の後ろに追加、「Run container」節で `run_image` を使う）
- Test: `t/03_dozo.t`（`docker_stub` を拡張、新サブテスト `--with`）

**Interfaces:**
- Produces（Bash 関数とグローバル変数）:
  - `feature_dir` — グローバル。`${XDG_CONFIG_HOME:-$HOME/.config}/dozo/features`。**`-H` が `HOME` を書き換える前**のホストの値で決める（`DEFAULT_ENV+=(HOME=$workdir)` はコンテナ用の環境変数で、シェルの `$HOME` は変わらないが、それを前提にせず早めに決める）。
  - `with_names` — グローバル配列。`"${with[@]}"` を `,` で分けた、空でない名前の並び。
  - `feature_path NAME` — 標準出力に `$feature_dir/NAME` を出す。NAME が `/` を含む、`.` か `..` で始まる、または存在しないなら `die`（メッセージに `$feature_dir` を含める）。
  - `feature_sum PATH` — 標準出力に 1 行の cksum 値。ファイルならその中身、ディレクトリなら `find . -type f` を `LC_ALL=C sort` した各ファイルの「パス名と中身」を連結したものの `cksum`。
  - `with_image [-c]` — `$image` から始めて `with_names` の各段を解決し、最終段のイメージ名をグローバル `run_image` に入れる。`-c`（check only）のときはビルドせず、タグがない段があれば戻り値 1。各段のタグは `dozo/<base>:<名前>-<値>`。`<base>` は `container_name` と同じ規則（`$image` の最後の名前部分、タグなし）、`<値>` は `printf '%s\n%s\n' "$parent_id" "$(feature_sum PATH)" | cksum` の 1 列目。タグに使えない文字（`[A-Za-z0-9_.-]` 以外）は名前部分で `_` に置き換え、128 文字を超えるなら名前部分を切り詰める（値の部分は残す）。
  - `feature_build PARENT_ID TAG NAME PATH` — 生成した Dockerfile を標準入力で渡して `docker build` する。ファイル feature は `docker build ... -`（context なし）、ディレクトリ feature は `docker build ... -f - PATH`。`--label dozo.base=$image --label dozo.with=<そこまでの名前を , でつないだもの> -t TAG` を付ける。出力は標準エラーへ、`-q` なら `--quiet` と `>/dev/null`。失敗したら `die`。
  - 生成する Dockerfile:
    ```
    FROM <PARENT_ID>
    ARG DOZO_USER=<user>
    ARG DOZO_HOME=<home>
    <feature の中身（ファイル、または PATH/Dockerfile）>
    USER <元イメージの Config.User>      ← Config.User が空なら書かない
    ```
    `<user>` は元イメージの `Config.User`（空なら `root`）。`<home>` は `docker run --rm --entrypoint sh ${Config.User:+--user "$Config.User"} "$image" -c 'echo "$HOME"'` の出力。この調査はビルドが必要になった最初の 1 回だけ行う。`sh` がなく失敗したら `die`。
  - 元イメージの ID は `command docker image inspect --format '{{.Id}}' "$image"`。取れなければ（`-A` でなくても）`pull_image` してからもう一度取り、それでもなければ `die "cannot find image $image"`。

- [ ] **Step 1: スタブを拡張し、失敗するテストを書く**

`docker_stub` に次の動作を足す（`STUB_IMAGES` が未設定のときは今までと同じ動作にして、既存の `-A` と `-L` のサブテストを壊さない）:
- `image inspect --format F NAME`: `$STUB_IMAGES` ファイルの行に NAME があれば、F が `{{.Id}}` なら `sha256:` + NAME を出す、`{{.Config.User}}` なら `$STUB_USER` を出す、`{{json .Config.Entrypoint}}` なら `${STUB_ENTRYPOINT:-null}` を出す。NAME がなければ `exit 1`。
- `build`: 標準入力を `$STUB_LOG.dockerfile.N`（N は 1 から）に保存し、`-t` の値を `$STUB_IMAGES` に追記する。`STUB_BUILD_FAILS` なら `exit 1`。
- `run` で引数に `--entrypoint sh` があるとき: `${STUB_HOME:-/root}` を出す。
- `pull`: `STUB_PULL_ADDS` が設定されていれば、pull したイメージ名を `$STUB_IMAGES` に追記する。

新サブテスト `'--with'`（`$dir` は `Cwd::realpath(tempdir)`、`HOME` と `XDG_CONFIG_HOME` を `local` で `$dir` 配下に向ける）:

```perl
    # features: a file and a directory
    my $fd = "$dir/config/dozo/features";
    # $fd/locale   : "ENV LANG=C.UTF-8\n"
    # $fd/home/Dockerfile : "COPY . \$DOZO_HOME/\n", $fd/home/.inputrc : "x\n"
    # STUB_IMAGES に "alpine" を入れておく

    my $out = `$dozo -I alpine --with locale,home echo hi 2>/dev/null`;
    is($?, 0, 'exit status');
    is($out, "ran\n", 'only the output of the command is on stdout');
    my $log = $calls->();
    my @build = $log =~ /^build .*$/mg;
    is(scalar @build, 2, 'two stages are built');
    like($build[0], qr/-t dozo\/alpine:locale-\d+ -$/, 'file feature: no context');
    like($build[1], qr/-t dozo\/alpine:home-\d+ -f - \Q$fd\E\/home$/, 'directory feature: context');
    like($log, qr/^run .* dozo\/alpine:home-\d+ echo hi$/m, 'run the last stage');
    like(dockerfile(1), qr/\AFROM sha256:alpine\nARG DOZO_USER=root\nARG DOZO_HOME=\/root\nENV LANG=C.UTF-8\n\z/, 'generated Dockerfile');

    `$dozo -I alpine --with locale,home echo hi 2>/dev/null`;
    unlike($calls->(), qr/^build/m, 'second time: nothing is built');

    `$dozo -I alpine --with locale --with home echo hi 2>/dev/null`;
    unlike($calls->(), qr/^build/m, 'repeated --with is the same as a comma list');
```

同じサブテストに、Review Focus のテストを足す:
- `'USER is restored as given'`: `STUB_USER=1000:1000` で新しい feature を使うと、生成 Dockerfile に `ARG DOZO_USER=1000:1000` と最後の行 `USER 1000:1000` がある。`STUB_USER` 空のときは `USER` 行がない（上の `generated Dockerfile` で確認済み）。
- `'-H does not move the feature directory'`: `-H --with locale` で `die` しない（feature が見つかる）。
- `'missing base image that cannot be pulled'`: `STUB_IMAGES` に元イメージがなく `STUB_PULL_ADDS` もない → 0 以外で終わり、ログに `^run ` がない。標準エラーに `cannot find image`。
- `'missing base image is pulled'`: `STUB_PULL_ADDS=1` → ログが `pull` を含み、その後 `build` と `run` がある。
- `'unknown feature'`: `--with nosuch` → 0 以外、標準エラーに `$fd` を含む。
- `'feature name with a slash'`: `--with ../x` と `--with a/b` → どちらも 0 以外、`^build` なし。
- `'build failure'`: `STUB_BUILD_FAILS=1` で新しい feature → 0 以外、`^run ` なし。
- `'changing a feature rebuilds from that stage'`: `$fd/home/.inputrc` を書き換えて再実行 → `build` は 1 回で `home-` の段だけ。
- `'no --with: no image inspect'`: `--with` なしの `echo hi` で、ログに `^image inspect --format \{\{\.Id` がない。

（`dockerfile(N)` は `$STUB_LOG.dockerfile.N` を読んで返す小さな sub としてサブテスト内に置く。）

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `prove -v t/03_dozo.t`
Expected: `--with` サブテストが FAIL（`--with` が未知のオプション）。他のサブテストは PASS。

- [ ] **Step 3: 実装する**

- OPTS に `[       with |   @ # add features to the image        ]=` を追加（`other` の後）。SYNOPSIS に `        --with=#       add features to the image (repeatable)` を `-A` の後に追加。
- 上の Interfaces の関数を実装する。
- 「Run container」節: `[[ $auto_pull ]] && pull_image` の後で、`with_names` が空でなければ `with_image` を呼ぶ。`run_image` の既定値は `$image`。ENTRYPOINT の判定と 2 か所の `docker run` は `$run_image` を使う。`hostname` と `container_name` は `$image` のまま。

- [ ] **Step 4: テストを実行して通ることを確認する**

Run: `prove -lr t`
Expected: すべて PASS

- [ ] **Step 5: コミット**

```bash
git add script/dozo t/03_dozo.t
git commit -F - <<'EOF'
Add --with to run an image with features added

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 2: `-L` と dryrun への対応

**Files:**
- Modify: `script/dozo`（「Live container handling」節、`with_image` の dryrun 動作）
- Test: `t/03_dozo.t`（`--with` サブテストに追加、または `'--with and -L'` サブテストを新設）

**Interfaces:**
- Consumes: Task 1 の `with_image [-c]`, `run_image`
- Produces: なし（動作のみ）

- [ ] **Step 1: 失敗するテストを書く**

```perl
    # -L, no container: created from the derived image, named after the original
    $out = `$dozo -L -I alpine --with locale echo hi 2>/dev/null`;
    $log = $calls->();
    like($log, qr/^run .*--name alpine\.\S+ .*dozo\/alpine:locale-\d+$/m, '-L: named after the original image');
    like($log, qr/^run .*--hostname alpine\b/m, '-L: hostname from the original image');

    # -L, existing container on the same image: no notice
    # (STUB_CONTAINER=1、stub の `inspect -f {{.Image}}` が派生イメージの ID を返すように STUB_CONTAINER_IMAGE を設定)
    $out = `$dozo -L -I alpine --with locale echo hi 2>&1`;
    unlike($out, qr/-K/, 'same image: no notice');

    # -L, existing container on another image: notice, and nothing is built
    $out = `$dozo -L -I alpine --with locale,home echo hi 2>&1`;
    like($out, qr/use -K to recreate it/, 'different image: notice');
    unlike($calls->(), qr/^build/m, 'existing container: nothing is built');

    # dryrun: shows build and run, builds nothing
    $out = `$dozo -n -I alpine --with newone echo hi 2>/dev/null`;
    like($out, qr/^docker build .* -t dozo\/alpine:newone-\d+ /m, 'dryrun shows docker build');
    like($out, qr/^docker run .* dozo\/alpine:newone-\d+ echo hi$/m, 'dryrun shows docker run');
    unlike($calls->(), qr/^build/m, 'dryrun builds nothing');
```

スタブには、`inspect` で `--format`/`-f` が `{{.Image}}` のとき `$STUB_CONTAINER_IMAGE` を出す動作を足す。

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `prove -v t/03_dozo.t`
Expected: 新しいアサーションが FAIL

- [ ] **Step 3: 実装する**

- 「Live container handling」節で、コンテナが見つかり `with_names` が空でないとき: `with_image -c` を呼ぶ。戻り値 1、またはコンテナの `{{.Image}}` が `run_image` の `{{.Id}}` と違うなら、`warn "--with does not change existing container $container, use -K to recreate it"`。`-A` の知らせと同じ位置に置く。
- dryrun（`$dryrun`）のとき `feature_build` は、`docker` 関数を通して `docker build ...` の行を表示するだけにする（ユーザー調査の `docker run` も実行しない。`DOZO_USER`/`DOZO_HOME` は表示に含めなくてよい）。後ろの段の親 ID には、前の段のタグ名を使う。

- [ ] **Step 4: テストを実行して通ることを確認する**

Run: `prove -lr t`
Expected: すべて PASS

- [ ] **Step 5: コミット**

```bash
git add script/dozo t/03_dozo.t
git commit -F - <<'EOF'
--with: work with -L and dryrun

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 3: POD と実機テスト

**Files:**
- Modify: `script/dozo`（OPTIONS に `--with` 項、新しい `=head1 FEATURES` 節を `=head1 LIVE CONTAINER` の後に）
- Test: `xt/author/docker_dozo.t`（サブテスト `'--with'`）

**Interfaces:**
- Consumes: Task 1・2 の動作

- [ ] **Step 1: 実機テストを書く**

`HOME` は既存どおり空の tempdir。`XDG_CONFIG_HOME` を tempdir に向け、`features/hello`（`RUN echo hello > /hello`）と `features/home/Dockerfile`（`COPY --chown=$DOZO_USER greeting $DOZO_HOME/greeting`）、`features/home/greeting`（`hi`）を作る。イメージは `alpine:latest`。

```perl
    my $out = `$dozo -I alpine:latest -B --with hello,home sh -c 'cat /hello ~/greeting' 2>/dev/null`;
    is($out, "hello\nhi\n", 'features are added');

    $out = `$dozo -I alpine:latest -B --with hello,home true 2>&1`;
    unlike($out, qr/^#\d|Step \d|building/mi, 'second time: nothing is built');   # 実装のビルド表示に合わせて調整してよい

    # changing a later feature rebuilds only that stage
    # greeting を "hey" に変えて実行し、出力が "hello\nhey\n"、hello の段のタグが変わっていないこと
    # （docker image ls --filter label=dozo.base=alpine:latest で dozo/alpine:hello-* が 1 つのまま）

    # USER is restored: USER nobody で作った小さな元イメージ
    # （docker build で FROM alpine:latest / USER nobody を dozo-test-user:latest として作る）に
    # USER root を含む feature を足して `id -un` が nobody
```

最後に `docker image ls -q --filter label=dozo.base=alpine:latest` と `dozo-test-user` を削除する。

- [ ] **Step 2: テストを実行する**

Run: `prove -v xt/author/docker_dozo.t`
Expected: すべて PASS

- [ ] **Step 3: POD を書く**

- OPTIONS に `=item B<--with>=I<name>[,I<name>...]`: 指定した feature を元イメージに足したイメージで実行すること、繰り返し指定できること、`.dozorc` と積み重なること、詳細は L</FEATURES>。
- `=head1 FEATURES`: 次を含める。
  - 置き場所 `~/.config/dozo/features/`（`XDG_CONFIG_HOME`）、ファイルとディレクトリの 2 形式
  - `DOZO_USER` / `DOZO_HOME`、`USER root` にしてよく最後に戻ること
  - 例: `ja-locale`（spec の例そのまま）と `home/Dockerfile`。ディレクトリの `Dockerfile` 自体もコピーされるので、気になるなら `.dockerignore` に書くこと
  - 一度作ったイメージを使い回し、feature か元イメージが変わったときだけ作り直すこと。前の段は使い回されるので、重いものを前に置くとよいこと
  - `-L` の既存コンテナは変わらず、`-K` で作り直すこと
  - 派生イメージの探し方と消し方: `docker image ls --filter label=dozo.base` / `docker image rm $(docker image ls -q --filter label=dozo.base)`

Run: `podchecker script/dozo`
Expected: `script/dozo pod syntax OK.`

- [ ] **Step 4: 全テストを実行する**

Run: `prove -lr t && prove xt/author/docker_dozo.t`
Expected: すべて PASS

- [ ] **Step 5: コミット**

```bash
git add script/dozo xt/author/docker_dozo.t
git commit -F - <<'EOF'
Document --with and features, and test them with docker

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```
