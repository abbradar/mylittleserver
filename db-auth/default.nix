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

  dbAuth = pkgs.python3.pkgs.callPackage ./db-auth {
    withMatrix = false;
  };

  makeFirewallRules = port: users: let
    allUsers = unique (["root"] ++ users);
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

      ui.enable = mkEnableOption "exposing the password change UI via nginx";
    };

    mylittleserver.nginx.authDomains = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["xmpp.example.com"];
      description = mdDoc ''
        Nginx virtual hosts that should have an internal `/internal/auth`
        location for `auth_request` against db-auth. To protect a location,
        add to its `extraConfig`:

        ```
          auth_request /internal/auth;
        ```
      '';
    };
  };

  config = mkMerge [
    (mkIf (rootCfg.enable && (cfg.allowedUsers != [] || cfg.allowedUnsafeUsers != [])) {
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
    })

    (mkIf (rootCfg.nginx.authDomains != []) {
      mylittleserver.db-auth.allowedUsers = ["nginx"];

      services.nginx.virtualHosts = genAttrs rootCfg.nginx.authDomains (host: {
        locations."= /internal/auth" = {
          extraConfig = ''
            internal;
            proxy_pass http://127.0.0.1:12343/nginx/check;
            proxy_pass_request_body off;
            proxy_set_header Content-Length "";
          '';
        };
      });
    })

    (mkIf (rootCfg.enable && cfg.ui.enable) {
      mylittleserver.db-auth.allowedUsers = ["nginx"];

      services.nginx.virtualHosts.${domain}.locations."/ui/" = {
        proxyPass = "http://127.0.0.1:12343";
      };
    })
  ];
}
