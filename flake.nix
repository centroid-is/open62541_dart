{
description = "Flutter";
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  flake-utils.url = "github:numtide/flake-utils";
};
outputs = { self, nixpkgs, flake-utils }:
  flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
        };
      };
    in
    {
      devShell =
        with pkgs; mkShell rec {
          buildInputs = [
            flutter
            pkg-config
            libsecret
            gtk3
            cmake
            gcc
            llvmPackages_latest.libclang
            clang
          ];

          shellHook = ''
            cp ${pkgs.writers.writeYAML "ffigen.yaml" {
              llvm-path = [ "${pkgs.lib.getLib pkgs.llvmPackages_latest.libclang}/lib/libclang.so" ];
              compiler-opts = [
                "-isystem ${pkgs.lib.getLib pkgs.llvmPackages_latest.libclang}/lib/clang/${pkgs.lib.versions.major (pkgs.lib.getVersion pkgs.llvmPackages_latest.libclang)}/include"
                "-idirafter ${pkgs.stdenv.cc.libc_dev}/include"
              ];
              headers.entry-points = [ "open62541_build/open62541.h" ];
              output = "lib/bindings.dart";
              name = "Open62541Bindings";
            }} ffigen.yaml
          '';
        };
    });
}
