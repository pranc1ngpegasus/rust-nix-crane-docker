{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    crane.url = "github:ipetkov/crane";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
      crane,
    }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        pkgsCross = pkgs.pkgsCross.aarch64-multiplatform-musl;

        rust = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
        craneLib = (crane.mkLib pkgsCross).overrideToolchain (_: rust);

        src = craneLib.cleanCargoSource ./.;
        commonArgs = {
          inherit src;
          strictDeps = true;
          CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        bin = craneLib.buildPackage (commonArgs // { inherit cargoArtifacts; });

        distroless = pkgs.dockerTools.pullImage {
          imageName = "gcr.io/distroless/static-debian12";
          imageDigest = "sha256:9c346e4be81b5ca7ff31a0d89eaeade58b0f95cfd3baed1f36083ddb47ca3160";
          sha256 = "sha256-P/g/uxIpirzCUpsZx3A42Tex+e3nLqh28abHODnxspU=";
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
            ExposedPorts = {
              "3000/tcp" = { };
            };
            User = "65532:65532";
          };
        };
      in
      {
        packages = {
          inherit bin docker;
          default = docker;
        };

        devShells.default = (crane.mkLib pkgs).devShell {
          packages = [ rust ];
        };

        formatter = pkgs.nixfmt;
      }
    );
}
