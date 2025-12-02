{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} ({...}: {
      flake.nixosModules.default.imports = [
        ./basic
        ./pam
        ./db-auth
        ./mail
        ./turn
        ./dav
        ./xmpp
        ./matrix
      ];

      systems = ["x86_64-linux"];

      perSystem = {pkgs, ...}: let
        db-auth = pkgs.python3.pkgs.callPackage ./db-auth/db-auth {};
      in {
        formatter = pkgs.alejandra;
        packages = {
          inherit db-auth;
          pam_pgsql = pkgs.callPackage ./pam/pam_pgsql.nix {};
        };
        devShells = {
          db-auth = db-auth.overridePythonAttrs (self: {
            nativeBuildInputs = [pkgs.pyright pkgs.ruff];
          });
        };
      };
    });
}
