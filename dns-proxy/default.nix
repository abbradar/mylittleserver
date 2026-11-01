{
  config,
  lib,
  ...
}:
with lib; let
  rootCfg = config.mylittleserver;
  cfg = config.mylittleserver.dns-proxy;
in {
  options = {
    mylittleserver.dns-proxy = {
      enable = mkEnableOption "MyLittleServer local DNS resolver";

      useLocalResolver = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether the system uses the resolver too.
        '';
      };

      address = mkOption {
        type = types.str;
        readOnly = true;
        internal = true;
        description = ''
          Address services should query the resolver on.
        '';
      };

      extraConfig = mkOption {
        type = types.lines;
        default = "";
        example = ''
          net.ipv6 = false
        '';
        description = ''
          Knot Resolver configuration, applied before forwarding to
          {option}`networking.nameservers`.
        '';
      };
    };
  };

  config = mkIf (rootCfg.enable && cfg.enable) {
    mylittleserver.dns-proxy.address =
      if cfg.useLocalResolver
      then "127.0.0.1"
      else "127.0.0.153";

    services.kresd = {
      enable = true;
      listenPlain =
        if cfg.useLocalResolver
        then ["127.0.0.1:53" "[::1]:53"]
        else ["${cfg.address}:53"];
      extraConfig =
        cfg.extraConfig
        + optionalString (config.networking.nameservers != []) ''
          policy.add(policy.all(policy.FORWARD({${concatMapStringsSep ", " (a: "'${a}'") config.networking.nameservers}})))
        '';
    };

    # Overrides kresd's `mkDefault`.
    networking.resolvconf.useLocalResolver = mkIf (!cfg.useLocalResolver) (mkOverride 999 false);
  };
}
