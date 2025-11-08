{
  inputs = {};

  outputs = {self}: {
    nixosModules.default.imports = [
      ./basic
      ./pam
      ./mail
      ./turn
      ./dav
      ./xmpp
      ./matrix
    ];
  };
}
