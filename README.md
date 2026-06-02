# rust-nix-crane-docker

Rust アプリケーションを、ホストマシンの CPU アーキテクチャに依存せず、Docker デーモンも QEMU エミュレーションも使わずに、`nix build` 一発でコンテナイメージとしてビルドできることを示すサンプルリポジトリです。

```sh
nix build .#docker   # Linux/arm64 向けの Docker イメージ (tarball) が出力される
```

このコマンドは、x86_64 Linux 上でも、Apple Silicon の macOS 上でも、arm64 Linux 上でも、まったく同じ成果物を生成します。

## 概要

このリポジトリでは、次の 4 つの仕組みを組み合わせています。

- [Nix](https://nixos.org/) が toolchain・依存・ベースイメージまで含めて環境を固定し、再現性を保証します。
- [crane](https://github.com/ipetkov/crane) が Rust の依存ビルドをキャッシュ層として分離し、効率よくクロスコンパイルします。
- [`dockerTools`](https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-dockerTools) が `Dockerfile` も Docker デーモンも使わずに、宣言的に OCI イメージを組み立てます。

その結果、`pkgsCross` によるクロスコンパイル（エミュレーションではありません）で、ホストの arch によらず Linux/arm64 イメージを生成できます。

## 解決したい課題

Rust アプリを「手元の Mac とは別アーキテクチャの Linux コンテナ」として配布したいとき、従来のやり方には次のような痛みがありました。

| 課題 | 従来の `docker build` / `buildx` |
| --- | --- |
| クロスアーキテクチャ | foreign arch のビルドは QEMU エミュレーション頼みで、極端に遅くなります |
| Docker デーモン | ビルドに常時 Docker デーモン（や互換ランタイム）が必要です |
| 再現性 | `apt-get`・`rustup`・ベースイメージの `latest` などで、ビルドごとに中身がブレます |
| 環境差 | 「手元では通るが CI で落ちる」が起きやすくなります |
| イメージサイズ / 攻撃面 | ベースイメージに不要なシェルやパッケージが同梱されがちです |

## このリポジトリのアプローチ

`flake.nix` がすべてを宣言的に定義しています。ポイントは 4 つです。

### 1. `pkgsCross` によるクロスコンパイル

```nix
pkgsCross = pkgs.pkgsCross.aarch64-multiplatform-musl;
craneLib = (crane.mkLib pkgsCross).overrideToolchain (_: rust);
```

ターゲットを `aarch64-unknown-linux-musl` に固定し、Nix のクロスコンパイル機構でビルドします。QEMU エミュレーションではなくネイティブのクロスコンパイルなので、x86_64 Linux でも Apple Silicon でも高速に動作します。`flake-utils.lib.eachSystem` で `x86_64-linux` / `aarch64-linux` / `aarch64-darwin` のいずれをホストにしても、出力されるイメージは常に Linux/arm64 です。

### 2. crane による効率的な Rust ビルド

```nix
cargoArtifacts = craneLib.buildDepsOnly commonArgs;          # 依存だけを先にビルドしてキャッシュ
bin = craneLib.buildPackage (commonArgs // { inherit cargoArtifacts; });
```

`buildDepsOnly` で依存クレートのビルド結果を独立した Nix derivation として切り出すため、アプリ本体のコードを変更しても依存の再ビルドは走りません。`Cargo.lock` をそのまま入力に使うので、依存バージョンも完全に固定されます。

### 3. musl による完全静的リンク

```nix
CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
```

musl ターゲットで静的リンクするため、libc を含む共有ライブラリを一切必要としない単一バイナリになります。これにより、最小構成の distroless イメージにバイナリを置くだけで動作します。

### 4. `dockerTools` による宣言的イメージ構築

```nix
distroless = pkgs.dockerTools.pullImage {
  imageName = "gcr.io/distroless/static-debian12";
  imageDigest = "sha256:9c346e4be81b5ca7ff31a0d89eaeade58b0f95cfd3baed1f36083ddb47ca3160";
  os = "linux";
  arch = "arm64";
};

docker = pkgs.dockerTools.buildImage {
  name = "rust-nix-crane-docker";
  tag = "latest";
  fromImage = distroless;
  copyToRoot = pkgs.runCommand "root" { } ''
    mkdir -p $out/app
    cp ${bin}/bin/rust-nix-crane-docker $out/app/
  '';
  config = {
    Cmd = [ "/app/rust-nix-crane-docker" ];
    ExposedPorts = { "3000/tcp" = { }; };
    User = "65532:65532";
  };
};
```

ベースイメージは digest で固定 (`pullImage`) するため、`latest` のような揺れが起きません。`Dockerfile` を書かず、レイヤー構成を Nix の式として表現します。distroless/static をベースにすることで、シェルもパッケージマネージャも含まない、最小で攻撃面の小さいイメージになります。非 root ユーザー (`65532:65532`) で実行する設定も宣言的に付与しています。

## 優位性まとめ

| 観点 | 従来の Docker ビルド | 本リポジトリ (Nix + crane + dockerTools) |
| --- | --- | --- |
| クロス arch ビルド | QEMU エミュレーションで低速 | ネイティブなクロスコンパイルで高速 |
| Docker デーモン | ビルドに必須 | 不要（tarball を出力し、`docker load` するだけ） |
| 再現性 | ブレやすい | 入力が完全に固定され、ビット単位で再現できる |
| ホスト依存 | ホスト環境に左右される | ホストの arch・OS に依存しない |
| イメージ最小性 | 設計次第で肥大化 | distroless と静的バイナリで最小・低攻撃面 |
| CI 構成 | OS / arch ごとに分岐しがち | どの runner でも同一コマンド |

## 使い方

事前に [Nix](https://nixos.org/download)（flakes 有効）が必要です。Docker デーモンはビルドには要りません。

```sh
# Linux/arm64 向け Docker イメージ (tarball) をビルド
nix build .#docker

# 生成された tarball を Docker にロード
docker load < result

# 実行（イメージは arm64。x86_64 ホストで動かす場合は --platform を指定）
docker run --rm -p 3000:3000 rust-nix-crane-docker:latest

# 動作確認
curl localhost:3000/health   # => ok
```

バイナリ単体だけが欲しい場合は次のようにします。

```sh
nix build .#bin
./result/bin/rust-nix-crane-docker
```

開発用シェル（リポジトリの `rust-toolchain.toml` と同じ toolchain が入ります）を使う場合は次のようにします。

```sh
nix develop
```

> [!NOTE]
> このリポジトリは [direnv](https://direnv.net/) に対応しています（`.envrc` に `use flake`）。`direnv allow` を実行すれば、ディレクトリに入るだけで開発環境が有効になります。

## サンプルアプリケーション

イメージ化の対象は、ヘルスチェック用エンドポイントだけを持つ最小の [axum](https://github.com/tokio-rs/axum) サーバーです（`src/main.rs`）。

- `GET /health` は `ok` を返します。
- リッスンアドレスは `--listen-addr` または環境変数 `LISTEN_ADDR` で設定します（デフォルトは `0.0.0.0:3000`）。

## CI

`.github/workflows/build.yaml` では、x86_64 Linux / arm64 Linux / macOS の 3 つの runner 上で `nix build .#bin` と `nix build .#docker` を実行しています。どのホスト arch からでも同じコマンドで同じ成果物が得られることを、CI 自体が実証しています。

## ファイル構成

```
.
├── flake.nix             # Nix flake 定義（クロスコンパイル・crane・dockerTools の中核）
├── flake.lock            # 全 input を固定するロックファイル
├── rust-toolchain.toml   # Rust toolchain とターゲットの固定
├── Cargo.toml / Cargo.lock
├── src/main.rs           # サンプルの axum サーバー
└── .github/workflows/build.yaml  # 3 アーキテクチャでの CI
```

## 構成要素

| ツール | 役割 |
| --- | --- |
| [Nix](https://nixos.org/) + [flakes](https://nixos.wiki/wiki/Flakes) | 環境・依存・成果物の再現性を保証します |
| [rust-overlay](https://github.com/oxalica/rust-overlay) | `rust-toolchain.toml` に従った Rust toolchain を提供します |
| [crane](https://github.com/ipetkov/crane) | Rust の依存ビルドをキャッシュし、クロスコンパイルを担います |
| [`dockerTools`](https://nixos.org/manual/nixpkgs/stable/#sec-pkgs-dockerTools) | `Dockerfile`・Docker デーモン不要で OCI イメージを生成します |
| [distroless](https://github.com/GoogleContainerTools/distroless) | 最小で攻撃面の小さいベースイメージです |
