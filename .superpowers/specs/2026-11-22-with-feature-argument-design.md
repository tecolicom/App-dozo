# --with: feature に引数を渡す（NAME/ARG）

## 目的

locale のように「手順は同じで、値だけが違う」設定を、値ごとに feature を
書き分けずに済ませたい。

```
dozo -I homebrew/brew --with locale/ja_JP+en_US,tz/Asia/Tokyo make test
```

## 決まったこと

- `--with` の各要素は `NAME` または `NAME/ARG`。**最初の `/`** で分け、
  後ろを丸ごと `ARG` とする（`tz/Asia/Tokyo` の `ARG` は `Asia/Tokyo`）。
- feature には `DOZO_ARG` として渡す。`/` がなければ、または `NAME/` なら空。
- 複数の値を区切る仕組みは dozo に持たせない。feature の中でシェルの `IFS` を
  使って分ける（例: `IFS=+ && for l in $DOZO_ARG; do ...; done`）。
  `RUN` は `/bin/sh -c` で実行され、alpine（busybox）と debian（dash）で
  動くことを確認済み。
- 名前の検査（`/` を含まない、`.` で始まらない）は `NAME` の部分だけに行う。
  `ARG` には制限を付けない（ファイルのパスには使わず、ビルド引数として渡すだけ）。
- `ARG` もタグの計算に含める。`locale/ja_JP` と `locale/en_US` は別のイメージになり、
  それぞれ使い回される。タグの名前部分は `NAME/ARG` から作り、使えない文字は
  今と同じく `_` に置き換える（長すぎれば切り詰める）。
- ラベル `dozo.with` には `NAME/ARG` をそのまま書く。

## 検討した方法

- 複数パラメータを `/` で区切る: `tz/Asia/Tokyo` のように値に `/` が入る場合に
  割れてしまうので不採用。
- feature に区切り文字の宣言（例: `# dozo: separator=+`）を書かせ、dozo が
  `DOZO_ARG1`, `DOZO_ARG2`… に分けて渡す: `IFS` で済むことに仕組みを足すことに
  なるので不採用。

## 前提・制約

- 前回の設計（`.superpowers/specs/2026-11-22-with-customize-image-design.md`）の
  制約はすべてそのまま（`--with` なしの動作は不変、標準出力はコマンド専用、
  bash と docker と macOS / Linux 共通の道具だけ）。
- `ARG` には空白・引用符・`$` などが入りうる。生成する Dockerfile に値を直接
  書き込まず、`docker build --build-arg DOZO_ARG=...` で渡す（Dockerfile 側は
  dozo が `ARG DOZO_ARG` を宣言する）。

## 実装者に任せる点

- タグの名前部分の作り方（`NAME/ARG` の `/` も `_` になる）。
- POD: OPTIONS の `--with` と FEATURES 節に `NAME/ARG` と `DOZO_ARG`、
  `IFS` で分ける locale の例、`tz/Asia/Tokyo` の例を足す。
- テスト: スタブで、引数の受け渡し（`--build-arg`）、引数違いで別タグ、
  `NAME/` が引数なしと同じこと、`ARG` に `/` や空白が入る場合、名前検査が
  `NAME` だけに効くこと。実機で `IFS` 分割の feature が動くこと。

## 追記: 配列オプションの区切り（レビューを受けて）

最初の実装では `--with` を値付きのコールバックにしたが、`--no-with` で `.dozorc` の
値を打ち消せなくなり、`--with 'a, b'` も失敗するようになった。そこで次のようにする。

- dozo の `OPTS` に `[&DELIM]=,` を書き、dozo の配列オプションはカンマだけで分ける
  （getoptlong 1.1.0 から使える設定。getoptlong 自体は変えない）。
- `--with` は配列オプション（`@`）に戻す。`--no-with` と `.dozorc` との積み重ねは
  getoptlong の配列オプションの動作どおり。
- `-P` と `-O` は、値に空白が入ることがないので、dozo 側で空白・タブでも分け直し、
  今と同じ動作を保つ（`-O '--memory 2g'` は 2 つ、`-P '8000 9000'` も 2 つ）。
- `-E`, `-V`, `--with` は空白を含む値を 1 つのまま扱う（`-E 'MSG=hello world'` は
  1 つの変数）。POD の OPTIONS 冒頭にあった「空白を含む値は渡せない」制限がなくなる。
- 各要素の前後の空白・タブは落とす（`'a, b'` は `a` と `b`）。空になった要素は捨てる。
- 利用者は多くないと考え、`-E 'A=1 B=2'` のように空白区切りで書いていた場合の
  動作が変わることは受け入れる（ユーザー判断）。
