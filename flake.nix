{
  inputs = {
    poetry2nix.url = "github:nix-community/poetry2nix/master";
  };

  outputs = { self, poetry2nix }: {
    nixosModules.default.imports = [
      ./basic
      ./pam
      ./mail
      ./turn
      ./dav
      (import ./xmpp { inherit (poetry2nix.lib) mkPoetry2Nix; })
      ./matrix
    ];
  };
}

