# 将来の拡張: feature の同梱（先送り）

ロケールの設定のように、誰にとっても役に立つ feature は dozo に同梱してもよい、
という案。2026-11-22 に検討し、同梱自体を先送りにした。検討で分かったことを残す。

## 前提

- dozo の実行に perl は要らない。`--bundle` の出力は「bash 4.4 以降と docker
  だけで動く 1 ファイル」（POD の INSTALLATION）。
- 同梱した feature の探し方も、この性質を崩さないこと。

## 方法の候補

### share ディレクトリで配布する

Minilla の share として `share/features/NAME` を配布し、ユーザーの置き場所
（`${XDG_CONFIG_HOME:-$HOME/.config}/dozo/features/`）になければ share を探す。
同じ名前を自分で置けば上書きできる。

問題は、perl なしで share の場所を決められないこと。

- xlate は `perl -MFile::Share=:all -E "say dist_dir 'App-Greple-xlate'"` で探し、
  なければスクリプトの 2 つ上の `share/` を使う（開発中のリポジトリ用）。
  dozo で同じことをすると perl が要る。
- インストール先ごとの share の場所（この Mac で確認）:
  - local::lib（`~/perl5`）: `bin/dozo` から見て `../lib/perl5/auto/share/dist/App-dozo`
  - Homebrew: `libexec/lib/perl5/auto/share/dist/App-dozo`。`bin/` のラッパーが
    `PERL5LIB` を設定して `libexec/bin/` の本体を呼ぶ
  - システムの perl: `installsitebin` と `installsitelib` の関係は環境ごとに違い、
    スクリプトの場所からは決められない
- 考えられる組み合わせ: 既知の相対位置を順に探し、見つからず perl があれば
  File::Share に聞く。`--with` の名前がユーザーの置き場所にないときだけ探せば、
  普段の起動は遅くならない。

### スクリプトに埋め込む

同梱する feature を `script/dozo` にヒアドキュメントとして持たせる。share が
要らず、CPAN・Homebrew・`--bundle` のどれでも同じように使える。

- ファイル形式の feature だけ。`COPY` するファイルを持つディレクトリ形式は難しい。
- locale のように `RUN` だけで済むものなら十分。

## 決めることが残っている点

- 同梱する feature が動くことを期待するイメージ（Ubuntu / Debian 系だけか、
  alpine や Fedora も含めるか）。前回の設計では「ディストリビューションの違いは
  吸収しない」としたが、同梱して誰でも使えるようにするなら、apt / apk / dnf を
  判別して分岐させる必要がある。
- locale 以外に同梱する候補。
