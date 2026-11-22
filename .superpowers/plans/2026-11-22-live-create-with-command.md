# -L: コマンド付き作成 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** コンテナがない状態での `dozo -L cmd` が、シェルを主プロセスとするコンテナを裏で作り、そこへ `cmd` を exec するようにする。

**Architecture:** `script/dozo` の「Run container」節で、`-L` かつコマンド引数ありのときだけ、`docker run` を `--detach --interactive --tty` 付き・コマンドなしで実行し、続けて既存の exec 処理を呼ぶ。exec 処理は「Live container handling」節から関数 `live_exec` に切り出して両方で使う。

**Tech Stack:** Bash 4.4+（`script/dozo`）、Perl Test::More（`t/03_dozo.t`, `xt/author/docker_dozo.t`）

**Spec:** `.superpowers/specs/2026-11-22-live-create-with-command-design.md`

## Global Constraints

- 引数なしでの作成、およびコンテナが既にある場合の動作は変えない。
- 標準出力はコマンドの出力専用。`docker run -d` が出すコンテナ ID は捨てる。dryrun（`-n`）では `docker run ...` 行と `docker exec ...` 行の両方を標準出力に出す。
- `-A`（pull）、`-q` は作成時に今と同じく効く。
- POD は `script/dozo` だけを編集する（`lib/App/dozo.pm` はリリース時に同期される）。
- コミットメッセージは既存の英語の書き方に合わせ、末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` を付ける。`Claude-Session:` 行は入れない。

## Review Focus

- パイプ入力: `echo data | dozo -L -B cat` を最初に実行したとき、`data` が exec 側の `cat` に届くこと（`docker run -d` が stdin を消費しない）。→ Task 2 のテストで確認する。
- 終了ステータス: 作成時の `dozo -L -B sh -c 'exit 3'` が 3 で終わること。→ Task 1（スタブ）と Task 2（実機）で確認する。
- 作成の失敗: `docker run -d` が失敗したら exec を実行せず、0 以外で終わること。→ Task 1 のテストで確認する。
- サブディレクトリからの作成: git top の下のディレクトリで作成したとき、コマンドがそのサブディレクトリで動くこと（`live_exec` が `--workdir` を付ける既存の条件のまま）。→ Task 1 のテストで確認する。
- 端末つきの作成: stdin が端末のとき、exec には既存どおり `--interactive --tty` が付く。（`tty_opts` をそのまま使うので追加のテストはなし）

---

### Task 1: コマンド付き作成を detached 作成 + exec にする

**Files:**
- Modify: `script/dozo:400-411`（exec 部分を `live_exec` に切り出す）
- Modify: `script/dozo:416-472`（Run container 節に分岐を追加）
- Modify: `script/dozo` POD の `=head2 Container Lifecycle` 内「Container does not exist」項
- Test: `t/03_dozo.t`

**Interfaces:**
- Produces: `live_exec ID [COMMAND ARGS...]` — Bash 関数。引数が `ID` だけなら `warn "attaching to container $container ($1)"` してから `docker attach ID`。それ以外は、`exec_opts=("${tty_opts[@]}")` に、`[[ ! $unmount && $relative ]]` のとき `--workdir "$container_workdir"` を足し、`docker exec "${exec_opts[@]}" "${env_opts[@]}" ID COMMAND ARGS...` を実行する。戻り値は docker の終了ステータス。現在の `script/dozo:402-409` と同じ動作。

- [ ] **Step 1: 失敗するテストを書く**

`t/03_dozo.t` の `-A` サブテストにあるスタブ作成部分を、ファイル内の関数に切り出す。

`sub docker_stub { my $dir = shift; ... }` — `$dir/docker` にスタブを書いて実行可能にする。スタブの中身は今の `-A` 用に次の 2 点を足したもの:
- `run` の場合: `[[ ! $STUB_RUN_FAILS ]] || exit 1` を `echo ran` の前に入れる
- `exec` の場合: `echo execed; exit ${STUB_EXEC_STATUS:-0}`

`-A` サブテストはこの関数を使うように書き換える（中身のアサーションは変えない）。そのあとに新しいサブテスト `'-L creates a container, then execs the command'` を追加する。PATH、`STUB_LOG`、`$calls` は `-A` サブテストと同じ形で用意し、`STUB_CONTAINER` は設定しない（コンテナなし）。

```perl
    my $out = `$dozo -L -I alpine echo hi 2>/dev/null`;
    is($?, 0, 'exit status');
    is($out, "execed\n", 'only the output of the command is on stdout');
    my $log = $calls->();
    like($log, qr/^run .*--detach\b.* alpine$/m, 'run detached without the command');
    like($log, qr/^run .*--interactive\b.*--tty\b/m, 'with --interactive --tty');
    like($log, qr/^exec .* alpine\.\S+ echo hi$/m, 'then exec the command');

    {
        local $ENV{STUB_EXEC_STATUS} = 3;
        `$dozo -L -I alpine false 2>/dev/null`;
        is($? >> 8, 3, 'exit status of the command');
        $calls->();
    }

    {
        local $ENV{STUB_RUN_FAILS} = 1;
        `$dozo -L -I alpine echo hi 2>/dev/null`;
        isnt($?, 0, 'failed run: non-zero exit');
        unlike($calls->(), qr/^exec/m, 'failed run: no exec');
    }

    $out = `$dozo -L -I alpine 2>/dev/null`;
    my $log2 = $calls->();
    like($log2, qr/^run .* alpine$/m, 'no command: run as before');
    unlike($log2, qr/--detach/, 'no command: not detached');
    unlike($log2, qr/^exec/m, 'no command: no exec');

    $out = `$dozo -n -L -I alpine echo hi 2>/dev/null`;
    like($out, qr/^docker run .*--detach\b.* alpine$/m, 'dryrun shows docker run');
    like($out, qr/^docker exec .* echo hi$/m, 'dryrun shows docker exec');

    {
        my $sub = "$dir/repo/sub";
        system("mkdir -p $sub && cd $dir/repo && git init -q") == 0 or die;
        $out = `cd $sub && $dozo -L -I alpine pwd 2>/dev/null`;
        like($calls->(), qr{^exec .*--workdir /work/sub\b.* pwd$}m,
             'from a subdirectory: exec in it');
    }
```

（注: 新しいサブテストの `$dir` は `Cwd::realpath(tempdir(CLEANUP => 1))` で取る。macOS では tempdir が `/var/...` で、`git rev-parse --show-toplevel` は `/private/var/...` を返す。そのままだと dozo の `cwd`（`pwd`）と前方一致せず、`--workdir` が付かない。）

（注: `-A` サブテストが `$HOME` に `.dozorc` を残すことがあるため、`-I alpine` は毎回明示する。`git init` したディレクトリで HOME の `.dozorc` 以外が読まれないよう、`$dir/repo` には `.dozorc` を置かない。）

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `prove -v t/03_dozo.t`
Expected: 新しいサブテストが FAIL する（`--detach` がない、`exec` がない）。`-A` サブテストは PASS のまま。

- [ ] **Step 3: `live_exec` を切り出し、Run container 節に分岐を入れる**

- `live_exec` を「Live container handling」節の直前に定義し、`script/dozo:402-409` をその呼び出し（`live_exec "$id" "$@"; exit`）に置き換える。
- Run container 節: `[[ $live ]] && (( $# > 0 ))` のときだけ、
  - `dockopt` の `"${tty_opts[@]}"` の代わりに `--detach --interactive --tty` を入れる（重複させない）
  - `docker run "${dockopt[@]}" "$image"` をコマンド引数なしで実行する。dryrun でなければ標準出力を `/dev/null` に捨てる（dryrun では `docker` 関数が出す行を残す）。失敗したら `exit 1`。
  - 続けて `live_exec "$container" "$@"; exit`。
- それ以外は今の `docker run "${dockopt[@]}" "${image}" "$@"` のまま。
- `-q` でないときの `warn "docker run ${info}"` はそのまま出してよい（`command=` も含めてよい）。

- [ ] **Step 4: POD を更新する**

`=item 1. B<Container does not exist>` の本文を次に置き換える:

```
Create a new persistent container (without C<--rm> flag).  Without a
command, the container is started with the image's default command
(usually a shell) and you are connected to it.  With a command, the
container is started in the background with the default command,
and then the command is executed in it as in case 2.  So you can
build up an environment from the first invocation, even in batch
mode:

    dozo -L -B apt-get install -y foo
    dozo -L -B pip install bar
```

- [ ] **Step 5: テストを実行して通ることを確認する**

Run: `prove -lr t`
Expected: すべて PASS

- [ ] **Step 6: コミット**

```bash
git add script/dozo t/03_dozo.t
git commit -F - <<'EOF'
-L with a command: create the container in the background, then exec

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```

### Task 2: 実機テストを追加する

**Files:**
- Test: `xt/author/docker_dozo.t`

**Interfaces:**
- Consumes: Task 1 の動作（コマンド付き作成 → exec）

- [ ] **Step 1: テストを追加する**

`'dryrun mode'` サブテストのあとに `'live container created with a command'` を追加する。最初の `skip 'Docker not available', 4` の数は今のままでよい（既存の不整合には触れない）。

```perl
    subtest 'live container created with a command' => sub {
        my $image = 'alpine:latest';
        my $container = 'dozo-test-create-cmd';
        `$dozo -I $image -N $container -K 2>&1`;

        my $out = `$dozo -I $image -N $container -L -B sh -c 'echo one > /tmp/stack' 2>&1`;
        like($out, qr/create live container/, 'created');
        is(`docker inspect -f '{{.State.Status}}' $container`, "running\n",
           'still running after the command');

        $out = `$dozo -I $image -N $container -L -B cat /tmp/stack 2>/dev/null`;
        is($out, "one\n", 'next command sees the result');

        `$dozo -I $image -N $container -K 2>&1`;
        $out = `echo data | $dozo -I $image -N $container -L -B cat 2>/dev/null`;
        is($out, "data\n", 'piped input reaches the command on creation');

        `$dozo -I $image -N $container -K 2>&1`;
        `$dozo -I $image -N $container -L -B sh -c 'exit 3' 2>/dev/null`;
        is($? >> 8, 3, 'exit status of the command on creation');

        `$dozo -I $image -N $container -K 2>&1`;
    };
```

- [ ] **Step 2: テストを実行する**

Run: `prove -v xt/author/docker_dozo.t`
Expected: すべて PASS（既存の `'live container'` と `'dryrun mode'` も含む）

- [ ] **Step 3: コミット**

```bash
git add xt/author/docker_dozo.t
git commit -F - <<'EOF'
Test creating a live container with a command

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
```
