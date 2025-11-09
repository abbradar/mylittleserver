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
        ./mail
        ./turn
        ./dav
        ./xmpp
        ./matrix
      ];

      systems = ["x86_64-linux"];

      perSystem = {pkgs, ...}: {
        formatter = pkgs.alejandra;
        packages = {
          db-auth = pkgs.python3.pkgs.callPackage ./xmpp/db-auth {};
          pam_pgsql = pkgs.callPackage ./pam/pam_pgsql.nix {};
        };
      };
    });
}
