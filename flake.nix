{
  description = "Experimental Nix Installer";

  inputs = {
    # can track upstream versioning with
    # git show $most_recently_merged_commit:flake.lock | jq '.nodes[.nodes.root.inputs.nixpkgs].locked.rev'
    nixpkgs.url = "github:loongson-community/nixpkgs/6aede27df8ab09d66428317427e5f30c82567a35";

    fenix = {
      # can track upstream versioning with
      # git show $most_recently_merged_commit:flake.lock | jq '.nodes[.nodes.root.inputs.fenix].locked.rev'
      url = "github:darkyzhou/fenix/6f6a8aaee0c97c4e43538c86772e9424f0f570eb";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    naersk = {
      url = "github:nix-community/naersk";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix = {
      url = "github:darkyzhou/nix/2.28.4-loongarch";
      # Omitting `inputs.nixpkgs.follows = "nixpkgs";` on purpose
    };
    # We don't use this, so let's save download/update time
    # determinate = {
    #   url = "https://flakehub.com/f/DeterminateSystems/determinate/0.1.tar.gz";

    #   # We set the overrides below so the flake.lock has many fewer nodes.
    #   #
    #   # The `determinate` input is used to access the builds of `determinate-nixd`.
    #   # Below, we access the `packages` outputs, which download static builds of `determinate-nixd` and makes them executable.
    #   # The way we consume the determinate flake means the `nix` and `nixpkgs` inputs are not meaningfully used.
    #   # This means `follows` won't cause surprisingly extensive rebuilds, just trivial `chmod +x` rebuilds.
    #   inputs.nixpkgs.follows = "nixpkgs";
    #   inputs.nix.follows = "nix";
    # };

    flake-compat.url = "github:edolstra/flake-compat/v1.0.0";
  };

  outputs =
    { self
    , nixpkgs
    , fenix
    , naersk
    , nix
      # , determinate
    , ...
    } @ inputs:
    let
      supportedSystems = [ "loongarch64-linux" ];
      systemsSupportedByDeterminateNixd = [ ]; # avoid refs to detsys nixd for now

      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: (forSystem system f));

      forSystem = system: f: f rec {
        inherit system;
        pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
        lib = pkgs.lib;
      };

      fenixToolchain = system: with fenix.packages.${system};
        combine ([
          stable.clippy
          stable.rustc
          stable.cargo
          stable.rustfmt
          stable.rust-src
        ] ++ nixpkgs.lib.optionals (system == "loongarch64-linux") [
          targets.loongarch64-unknown-linux-musl.stable.rust-std
        ]);

      nixTarballs = forAllSystems ({ system, ... }:
        inputs.nix.tarballs_direct.${system}
          or "${inputs.nix.packages."${system}".binaryTarball}/nix-${inputs.nix.packages."${system}".default.version}-${system}.tar.xz");

      optionalPathToDeterminateNixd = system: if builtins.elem system systemsSupportedByDeterminateNixd then "${inputs.determinate.packages.${system}.default}/bin/determinate-nixd" else null;

      version = (builtins.fromTOML (builtins.readFile ./Cargo.toml)).package.version;
    in
    {
      overlays.default = final: prev:
        let
          toolchain = fenixToolchain final.stdenv.system;
          naerskLib = final.callPackage naersk {
            cargo = toolchain;
            rustc = toolchain;
          };
          sharedAttrs = {
            inherit version;
            pname = "nix-installer";
            src = builtins.path {
              name = "nix-installer-source";
              path = self;
              filter = (path: type: baseNameOf path != "nix" && baseNameOf path != ".github");
            };

            nativeBuildInputs = with final; [ ];
            buildInputs = with final; [ ] ++ lib.optionals (final.stdenv.isDarwin) (with final.darwin.apple_sdk.frameworks; [
              SystemConfiguration
              # temporary fix for naersk to nix flake update; see df13b0b upstream
              final.darwin.libiconv
            ]);

            copyBins = true;
            copyDocsToSeparateOutput = true;

            doCheck = false;
            doDoc = true;
            doDocFail = true;
            RUSTFLAGS = "--cfg tokio_unstable";
            cargoTestOptions = f: f ++ [ "--all" ];

            NIX_INSTALLER_TARBALL_PATH = nixTarballs.${final.stdenv.system};
            DETERMINATE_NIXD_BINARY_PATH = optionalPathToDeterminateNixd final.stdenv.system;

            override = { preBuild ? "", ... }: {
              preBuild = preBuild + ''
                # logRun "cargo clippy --all-targets --all-features -- -D warnings"
              '';
            };
            postInstall = ''
              cp nix-installer.sh $out/bin/nix-installer.sh
            '';
          };
        in
        rec {
          # NOTE(cole-h): fixes build -- nixpkgs updated libsepol to 3.7 but didn't update
          # checkpolicy to 3.7, checkpolicy links against libsepol, and libsepol 3.7 changed
          # something in the API so checkpolicy 3.6 failed to build against libsepol 3.7
          # Can be removed once https://github.com/NixOS/nixpkgs/pull/335146 merges.
          checkpolicy = prev.checkpolicy.overrideAttrs ({ ... }: rec {
            version = "3.7";

            src = final.fetchurl {
              url = "https://github.com/SELinuxProject/selinux/releases/download/${version}/checkpolicy-${version}.tar.gz";
              sha256 = "sha256-/T4ZJUd9SZRtERaThmGvRMH4bw1oFGb9nwLqoGACoH8=";
            };
          });

          nix-installer = naerskLib.buildPackage sharedAttrs;
        } // nixpkgs.lib.optionalAttrs (prev.stdenv.system == "x86_64-linux") rec {
          default = nix-installer-static;
          nix-installer-static = naerskLib.buildPackage
            (sharedAttrs // {
              CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
            });
        } // nixpkgs.lib.optionalAttrs (prev.stdenv.system == "aarch64-linux") rec {
          default = nix-installer-static;
          nix-installer-static = naerskLib.buildPackage
            (sharedAttrs // {
              CARGO_BUILD_TARGET = "aarch64-unknown-linux-musl";
            });
        } // nixpkgs.lib.optionalAttrs (prev.stdenv.system == "loongarch64-linux") rec {
          default = nix-installer-static;
          nix-installer-static = naerskLib.buildPackage
            (sharedAttrs // {
              CARGO_BUILD_TARGET = "loongarch64-unknown-linux-musl";
              RUSTFLAGS = "-C target-feature=+crt-static -C link-self-contained=yes -C default-linker-libraries=yes";
            });
        };


      devShells = forAllSystems ({ system, pkgs, ... }:
        let
          toolchain = fenixToolchain system;
          check = import ./nix/check.nix { inherit pkgs toolchain; };
        in
        {
          default = pkgs.mkShell {
            name = "nix-install-shell";

            RUST_SRC_PATH = "${toolchain}/lib/rustlib/src/rust/library";
            NIX_INSTALLER_TARBALL_PATH = nixTarballs.${system};
            DETERMINATE_NIXD_BINARY_PATH = optionalPathToDeterminateNixd system;

            nativeBuildInputs = with pkgs; [ ];
            buildInputs = with pkgs; [
              toolchain
              shellcheck
              rust-analyzer
              cargo-outdated
              cacert
              # cargo-audit # NOTE(cole-h): build currently broken because of time dependency and Rust 1.80
              cargo-watch
              nixpkgs-fmt
              check.check-rustfmt
              check.check-spelling
              check.check-nixpkgs-fmt
              check.check-editorconfig
              check.check-semver
              check.check-clippy
              editorconfig-checker
            ]
            ++ lib.optionals (pkgs.stdenv.isDarwin) (with pkgs; [
              libiconv
              darwin.apple_sdk.frameworks.Security
              darwin.apple_sdk.frameworks.SystemConfiguration
            ])
            ++ lib.optionals (pkgs.stdenv.isLinux) (with pkgs; [
              checkpolicy
              semodule-utils
              /* users are expected to have a system docker, too */
            ]);
          };
        });

      checks = forAllSystems ({ system, pkgs, ... }:
        let
          toolchain = fenixToolchain system;
          check = import ./nix/check.nix { inherit pkgs toolchain; };
        in
        {
          check-rustfmt = pkgs.runCommand "check-rustfmt" { buildInputs = [ check.check-rustfmt ]; } ''
            cd ${./.}
            check-rustfmt
            touch $out
          '';
          check-spelling = pkgs.runCommand "check-spelling" { buildInputs = [ check.check-spelling ]; } ''
            cd ${./.}
            check-spelling
            touch $out
          '';
          check-nixpkgs-fmt = pkgs.runCommand "check-nixpkgs-fmt" { buildInputs = [ check.check-nixpkgs-fmt ]; } ''
            cd ${./.}
            check-nixpkgs-fmt
            touch $out
          '';
          check-editorconfig = pkgs.runCommand "check-editorconfig" { buildInputs = [ pkgs.git check.check-editorconfig ]; } ''
            cd ${./.}
            check-editorconfig
            touch $out
          '';
        });

      packages = forAllSystems ({ system, pkgs, ... }:
        {
          inherit (pkgs) nix-installer;
        } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          inherit (pkgs) nix-installer-static;
          default = pkgs.nix-installer-static;
        } // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") {
          inherit (pkgs) nix-installer-static;
          default = pkgs.nix-installer-static;
        } // nixpkgs.lib.optionalAttrs (pkgs.stdenv.isDarwin) {
          default = pkgs.nix-installer;
        } // nixpkgs.lib.optionalAttrs (system == "loongarch64-linux") {
          inherit (pkgs) nix-installer-static;
          default = pkgs.nix-installer-static;
        });

      hydraJobs =
        let
          installerName = "nix-installer-loongarch64-linux";
          installerScriptName = "nix-installer.sh";
        in
        rec {
          build = forAllSystems (
            { system, pkgs, ... }:
            let
              dist = self.packages.${system}.default;
            in
            pkgs.runCommand "build" { } ''
              mkdir -p $out/nix-support $out/bin

              cp ${dist}/bin/nix-installer $out/bin/${installerName}
              cp ${dist}/bin/nix-installer.sh $out/bin/${installerScriptName}
              sed -i 's/\$assemble_installer_templated_version/v${version}/g' $out/bin/${installerScriptName}
              echo "v${version}" > $out/version

              echo "file binary-dist $out/bin/${installerName}" >> $out/nix-support/hydra-build-products
              echo "file binary-dist $out/bin/${installerScriptName}" >> $out/nix-support/hydra-build-products
            ''
          );

          runCommandHook.publish = forSystem "loongarch64-linux" (
            { pkgs, ... }:
            let
              app = pkgs.writeShellApplication {
                name = "publish-hook";
                runtimeInputs = with pkgs; [
                  jq
                  curl
                ];
                text = ''
                  set -euo pipefail

                  VERSION_PATH="${build.loongarch64-linux}/version"
                  NIX_INSTALLER_PATH="${build.loongarch64-linux}/bin/${installerName}"
                  NIX_INSTALLER_SH_PATH="${build.loongarch64-linux}/bin/${installerScriptName}"
                  if [ "$VERSION_PATH" = "null" ] || [ ! -f "$VERSION_PATH" ]; then
                    echo "Error: version file not found"
                    exit 1
                  fi
                  if [ "$NIX_INSTALLER_PATH" = "null" ] || [ ! -f "$NIX_INSTALLER_PATH" ]; then
                    echo "Error: nix-installer not found"
                    exit 1
                  fi
                  if [ "$NIX_INSTALLER_SH_PATH" = "null" ] || [ ! -f "$NIX_INSTALLER_SH_PATH" ]; then
                    echo "Error: nix-installer.sh not found"
                    exit 1
                  fi

                  VERSION=$(cat "$VERSION_PATH")
                  echo "Version: $VERSION"
                  echo "Found nix-installer at: $NIX_INSTALLER_PATH"
                  echo "Found nix-installer.sh at: $NIX_INSTALLER_SH_PATH"

                  PUBLISH_JSON=$(jq -n \
                    --arg nix_installer "$NIX_INSTALLER_PATH" \
                    --arg nix_installer_sh "$NIX_INSTALLER_SH_PATH" \
                    --arg version "$VERSION" \
                    '[
                      {
                        "from": $nix_installer,
                        "to": ("nix-installer/" + $version + "/"),
                        "overwrite": true
                      },
                      {
                        "from": $nix_installer_sh, 
                        "to": ("nix-installer/" + $version + "/"),
                        "overwrite": true
                      },
                      {
                        "from": $nix_installer,
                        "to": "nix-installer/latest/",
                        "overwrite": true
                      },
                      {
                        "from": $nix_installer_sh,
                        "to": "nix-installer/latest/",
                        "overwrite": true
                      }
                    ]')

                  echo "Publishing JSON:"
                  echo "$PUBLISH_JSON" | jq .

                  if curl -fSs -X POST \
                    -H "Content-Type: application/json" \
                    -d "$PUBLISH_JSON" \
                    "http://127.0.0.1:8888/publish"; then
                    echo "Successfully published version $VERSION"
                  else
                    echo "Error: Failed to publish version $VERSION"
                    exit 1
                  fi
                '';
              };
            in
            pkgs.writeScript "publish.sh" ''
              #!${pkgs.runtimeShell}
              exec ${app}/bin/publish-hook "$@"
            ''
          );

        # vm-test = import ./nix/tests/vm-test {
        #   inherit forSystem;
        #   inherit (nixpkgs) lib;

        #   binaryTarball = nix.tarballs_indirect;
        # };
        # container-test = import ./nix/tests/container-test {
        #   inherit forSystem;

        #   binaryTarball = nix.tarballs_indirect;
        # };
      };
    };
}
