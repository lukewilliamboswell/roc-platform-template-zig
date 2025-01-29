{
  description = "Roc zig template devShell";

  inputs = {
    roc.url = "github:roc-lang/roc";

    nixpkgs.follows = "roc/nixpkgs";

    # to easily make configs for multiple architectures
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, roc, flake-utils }:
    let supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ];
    in flake-utils.lib.eachSystem supportedSystems (system:
      let
        overlays = [];
        pkgs = import nixpkgs { inherit system overlays; };

        rocPkgs = roc.packages.${system};

        linuxInputs = with pkgs;
          lib.optionals stdenv.isLinux [
            valgrind
          ];

        darwinInputs = with pkgs;
          lib.optionals stdenv.isDarwin
          (with pkgs.darwin.apple_sdk.frameworks; [
            Security
          ]);

        sharedInputs = (with pkgs; [
          zig
          expect
          rocPkgs.cli
        ]);
      in {

        devShell = pkgs.mkShell {
          buildInputs = sharedInputs ++ darwinInputs ++ linuxInputs;

          # Clear all problematic environment variables for Zig on macOS
          shellHook = pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
            unset NIX_CFLAGS_COMPILE
            unset NIX_CFLAGS_LINK
            unset NIX_ENFORCE_PURITY
            unset NIX_LDFLAGS
            unset NIX_CXXSTDLIB_COMPILE
            unset NIX_CXXSTDLIB_LINK
          '';

          # nix does not store libs in /usr/lib or /lib
          # for libgcc_s.so.1
          NIX_LIBGCC_S_PATH =
            if pkgs.stdenv.isLinux then "${pkgs.stdenv.cc.cc.lib}/lib" else "";
          # for crti.o, crtn.o, and Scrt1.o
          NIX_GLIBC_PATH =
            if pkgs.stdenv.isLinux then "${pkgs.glibc.out}/lib" else "";
        };

        formatter = pkgs.nixpkgs-fmt;
      });
}
