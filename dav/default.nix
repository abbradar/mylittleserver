{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  rootCfg = config.mylittleserver;
  cfg = config.mylittleserver.dav;

  inherit (rootCfg) domain;
in {
  options = {
    mylittleserver.dav = {
      enable = mkEnableOption "MyLittleServer CardDAV & CalDAV module";

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/mylittleserver/radicale";
        description = ''
          WebDAV (Radicale) data directory.
        '';
      };
    };
  };

  config = mkIf (rootCfg.enable && cfg.enable) {
    mylittleserver.db-auth.allowedUsers = ["radicale"];

    mylittleserver.dnsRecords = ''
      cal CNAME ${domain}.
      _caldavs._tcp SRV 0 1 443 cal.${domain}.
      _carddavs._tcp SRV 0 1 443 cal.${domain}.
    '';

    services.nginx.virtualHosts = {
      ${domain}.locations = {
        "= /.well-known/carddav".return = "301 $scheme://cal.$host/";
        "= /.well-known/caldav".return = "301 $scheme://cal.$host/";
      };
      "cal.${domain}" = {
        forceSSL = true;
        enableACME = true;
        locations."/".proxyPass = "http://127.0.0.1:5232";
      };
    };

    services.radicale = {
      enable = true;
      /*
        package = pkgs.radicale.overridePythonAttrs (self: let
        # Cursed but it works.
        python = (head self.build-system).pythonModule;
      in {
        dependencies =
          self.dependencies or []
          ++ [
            python.pkgs.python-pam
          ];
      });
      */
      settings = {
        server.hosts = ["127.0.0.1:5232"];
        auth = {
          type = "oauth2";
          oauth2_token_endpoint = "http://127.0.0.1:12343/oauth2";
        };
        storage.filesystem_folder = cfg.dataDir;
      };
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 radicale radicale - -"
    ];
  };
}
