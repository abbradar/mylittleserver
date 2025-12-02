{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  rootCfg = config.mylittleserver;
  cfg = config.mylittleserver.db-auth;

  inherit (rootCfg) domain;

  dbAuth = pkgs.python3.pkgs.callPackage ./db-auth {};

  makeFirewallRules = port: users: let
    allUsers = ["root"] ++ users;
  in {
    extraCommands = ''
      ${concatMapStringsSep "\n" (user: ''
          ip46tables -A OUTPUT -o lo -m owner --uid-owner ${escapeShellArg user} -p tcp -m tcp --dport ${toString port} -j ACCEPT
        '')
        allUsers}
      ip46tables -A OUTPUT -o lo -p tcp -m tcp --dport ${toString port} -j REJECT
    '';

    extraStopCommands = ''
      ${concatMapStringsSep "\n" (user: ''
          ip46tables -D OUTPUT -o lo -m owner --uid-owner ${escapeShellArg user} -p tcp -m tcp --dport ${toString port} -j ACCEPT 2>/dev/null || true
        '')
        allUsers}
      ip46tables -D OUTPUT -o lo -p tcp -m tcp --dport ${toString port} -j REJECT 2>/dev/null || true
    '';
  };
in {
  options = {
    mylittleserver.db-auth = {
      allowedUsers = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Linux users allowed to authenticate via HTTP.
        '';
      };

      allowedUnsafeUsers = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Linux users allowed to authenticate *and reset passwords* via HTTP.
        '';
      };
    };
  };

  config = mkIf (rootCfg.enable && (cfg.allowedUsers != [] || cfg.allowedUnsafeUsers != [])) {
    networking.firewall = mkMerge [
      (mkIf (cfg.allowedUsers != []) (makeFirewallRules 12343 cfg.allowedUsers))
      (mkIf (cfg.allowedUnsafeUsers != []) (makeFirewallRules 12344 cfg.allowedUnsafeUsers))
    ];

    systemd.services = {
      "mls-db-auth" = {
        description = "Responds to authentication requests by HTTP.";
        wantedBy = ["multi-user.target"];
        after = ["network.target"];
        serviceConfig = {
          User = "db-auth";
          Group = "db-auth";
          DynamicUser = true;
          ExecStart = concatMapStringsSep " " escapeShellArg (
            [
              "${dbAuth}/bin/db_auth"
            ]
            ++ optionals (cfg.allowedUsers != []) ["--port" "12343"]
            ++ optionals (cfg.allowedUnsafeUsers != []) ["--unsafe-port" "12344"]
            ++ [rootCfg.accounts.database]
          );
          Restart = "on-failure";
        };
      };

      "mls-init-db-auth-database" = {
        description = "Initialize MyLittleServer's db-auth database.";
        wantedBy = ["multi-user.target"];
        after = ["postgresql.service" "mls-init-basic-database.service"];
        before = ["mls-db-auth.service"];
        path = [config.services.postgresql.package];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
        };
        script = ''
          psql prosody < ${./init.sql}
        '';
      };
    };

    services.postgresql = {
      ensureUsers = [
        {
          name = "db-auth";
        }
      ];
    };
  };
}
