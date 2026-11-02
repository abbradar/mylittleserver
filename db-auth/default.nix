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

  restrictPort = port: users: let
    allUsers = unique (["root"] ++ users);
  in ''
    oifname "lo" tcp dport ${toString port} meta skuid != { ${concatStringsSep ", " allUsers} } reject with tcp reset
  '';
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

      failedLogins = {
        burst = mkOption {
          type = types.ints.unsigned;
          default = 5;
          description = ''
            Failed logins allowed per client IP before further attempts are refused.
            Applies to callers that pass the client IP. 0 disables the limit.
          '';
        };

        period = mkOption {
          type = types.ints.positive;
          default = 30;
          description = ''
            Period in seconds in which at most {option}`burst` failed logins are allowed.
          '';
        };
      };

      ui.enable = mkEnableOption "exposing the password change UI via nginx";
    };

    mylittleserver.nginx.authDomains = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["xmpp.example.com"];
      description = ''
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
      assertions = [
        {
          assertion = config.networking.nftables.enable;
          message = "mylittleserver.db-auth restricts access to its ports with nftables; enable networking.nftables.";
        }
      ];

      networking.nftables = {
        tables.mylittleserver-db-auth = {
          family = "inet";
          content = ''
            chain output {
              type filter hook output priority filter; policy accept;
              ${optionalString (cfg.allowedUsers != []) (restrictPort 12343 cfg.allowedUsers)}
              ${optionalString (cfg.allowedUnsafeUsers != []) (restrictPort 12344 cfg.allowedUnsafeUsers)}
            }
          '';
        };
        # The build sandbox doesn't have our users.
        preCheckRuleset = ''
          sed -E 's/meta skuid != \{[^}]*\}/meta skuid != { root }/' -i ruleset.conf
        '';
      };

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
              ++ [
                "--failed-logins-burst"
                (toString cfg.failedLogins.burst)
                "--failed-logins-period"
                (toString cfg.failedLogins.period)
              ]
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
            psql ${escapeShellArg rootCfg.accounts.database} < ${./init.sql}
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
          proxyPass = "http://127.0.0.1:12343/nginx/check";
          recommendedProxySettings = true;
          extraConfig = ''
            internal;
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
        recommendedProxySettings = true;
      };
    })
  ];
}
