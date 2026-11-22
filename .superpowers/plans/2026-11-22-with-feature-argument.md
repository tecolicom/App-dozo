# --with NAME/ARG 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `--with NAME/ARG` で feature に `DOZO_ARG` を渡す。

**Architecture:** `with_image` で各要素を最初の `/` で `NAME` と `ARG` に分け、`feature_path` には `NAME` だけを渡す。`ARG` が空でなければタグの cksum 入力に足す。`feature_build` は `ARG` を受け取り、生成 Dockerfile に `ARG DOZO_ARG` を宣言して `--build-arg DOZO_ARG=$ARG` で渡す。

**Tech Stack:** Bash、docker、Perl Test::More

**Spec:** `.superpowers/specs/2026-11-22-with-feature-argument-design.md`

## Global Constraints

- `--with` なしの動作・出力は不変。標準出力はコマンド専用。bash と docker と macOS / Linux 共通の道具だけ。
- 引数なしの feature のタグは今と同じ値（cksum 入力を変えない）。`NAME/` は引数なしと同じ。
- `ARG` は生成 Dockerfile に書き込まず、`--build-arg` で渡す。
- コミットメッセージは英語、末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`、`Claude-Session:` 行なし。

## Review Focus

- `ARG` に空白・引用符・`$`・`/` が入る: そのまま `DOZO_ARG` に届く。→ テスト `argument with special characters`。
- `../x/y` のように `NAME` 側に不正な名前: 引数があっても拒否。→ テスト `invalid name with an argument`。
- 引数なしの既存 feature のタグが変わらない（既存イメージを作り直さない）。→ テスト `no argument: same tag as before`。
- dryrun でも `--build-arg` 付きの `docker build` が表示される。→ テスト `dryrun shows the argument`。
- 実機で `IFS` 分割の feature が動く。→ xt テスト。

---

### Task 1: NAME/ARG の受け渡し

**Files:**
- Modify: `script/dozo`（`with_image`, `feature_build`、POD の OPTIONS `--with` と FEATURES）
- Test: `t/03_dozo.t`（`--with` サブテストに追加）、`xt/author/docker_dozo.t`（`--with` サブテストに追加）

**Interfaces:**
- Produces: `feature_build FROM_NAME TAG NAME PATH ARG`（ARG は空でもよい）。生成 Dockerfile の 4 行目に `ARG DOZO_ARG`、docker build 引数に `--build-arg DOZO_ARG=<ARG>`。

- [ ] **Step 1: 失敗するテストを書く**（t/03: `argument is passed`（ログに `--build-arg DOZO_ARG=ja_JP+en_US`、Dockerfile に `ARG DOZO_ARG`）、`different arguments, different tags`、`NAME/ is the same as NAME`、`argument with special characters`（`tz/Asia/Tokyo` と `x/a b'c$d`）、`invalid name with an argument`、`no argument: same tag as before`（変更前に作ったタグが再利用され build されない）、`dryrun shows the argument`）
- [ ] **Step 2: `prove -v t/03_dozo.t` で失敗を確認**
- [ ] **Step 3: 実装**（`generated Dockerfile` の期待値に `ARG DOZO_ARG\n` を足す）
- [ ] **Step 4: `prove -lr t` が PASS**
- [ ] **Step 5: xt に `IFS=+` で分ける feature を足し、`--with split/a+b` で 2 行出ることを確認。`prove xt/author/docker_dozo.t` が PASS**
- [ ] **Step 6: POD を更新し `podchecker script/dozo` が OK。Derived Images の長い 1 行も折り返す**
- [ ] **Step 7: コミット**
