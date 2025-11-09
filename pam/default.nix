{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.mylittleserver.pam;
  rootCfg = config.mylittleserver;

  inherit (rootCfg) domain;

  # FIXME: upstream to Nixpkgs.
  pam_pgsql = pkgs.callPackage ./pam_pgsql.nix {};
in {
  options = {
    mylittleserver = {
      pam.enable = mkEnableOption "MyLittleServer authorization via PAM";

      nginx.pam = mkOption {
        type = types.bool;
        default = false;
        example = true;
        description = mdDoc ''
          If enabled, configures Nginx to be able to authorize requests by
          the server accounts. To protect a location, place this into its
          `extraConfig`:

          ```
            auth_pam "Restricted area";
            auth_pam_service_name "mylittleserver";
          ```
        '';
      };
    };
  };

  config = mkMerge [
    (mkIf rootCfg.nginx.pam {
      mylittleserver.pam.enable = true;

      services.postgresql.ensureUsers = [
        {
          name = "nginx";
        }
      ];

      services.nginx.package = pkgs.nginx.override {
        modules = [pkgs.nginxModules.pam];
      };

      systemd.services."mls-init-pam-database" = {
        description = "Initialize MyLittleServer Nginx PAM database.";
        wantedBy = ["multi-user.target"];
        after = ["postgresql.service" "mls-init-basic-database.service"];
        before = ["nginx.service"];
        path = [config.services.postgresql.package];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
        };
        script = ''
          psql ${escapeShellArg rootCfg.accounts.database} < ${./nginx-pam-init.sql}
        '';
      };
    })

    (mkIf cfg.enable {
      environment.systemPackages = with pkgs; [
        pamtester
      ];

      security.pam.services.mylittleserver.text = let
        confFile = pkgs.replaceVars ./pam_pgsql.conf {
          inherit domain;
          inherit (rootCfg.accounts) database;
        };
        clause = svc: "${svc} required ${pam_pgsql}/lib/security/pam_pgsql.so config_file=${confFile}";
        svcs = ["auth" "account" "password"];
      in
        concatMapStringsSep "\n" clause svcs;
    })
  ];
}
