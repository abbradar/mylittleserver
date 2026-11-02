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

      maxSizeMb = mkOption {
        type = types.int;
        default = 32;
        description = ''
          Maximum allowed request size, e.g. for contacts with photos or calendar imports.
        '';
      };
    };
  };

  config = mkIf (rootCfg.enable && cfg.enable) {
    mylittleserver.db-auth.allowedUsers = ["radicale"];
    mylittleserver.nginx.hstsHosts = ["cal.${domain}"];

    mylittleserver.backup = {
      paths = [cfg.dataDir];
      exclude = ["${cfg.dataDir}/**/.Radicale.cache"];
    };

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
        locations."/" = {
          proxyPass = "http://127.0.0.1:5232";
          recommendedProxySettings = true;
          extraConfig = ''
            client_max_body_size ${toString cfg.maxSizeMb}m;
            proxy_set_header X-Remote-Addr $remote_addr;
          '';
        };
      };
    };

    services.radicale = {
      enable = true;
      # Passes the client IP to db-auth, which throttles failed logins per IP.
      package = pkgs.radicale.overridePythonAttrs (old: {
        patches = (old.patches or []) ++ [./radicale-oauth2-client-ip.patch];
      });
      settings = {
        server = {
          hosts = ["127.0.0.1:5232"];
          max_content_length = cfg.maxSizeMb * 1024 * 1024;
        };
        auth = {
          type = "oauth2";
          oauth2_token_endpoint = "http://127.0.0.1:12343/oauth2";
          oauth2_client_ip_header = "X-Forwarded-For";
          remote_ip_source = "X-Remote-Addr";
          cache_logins = true;
          strip_domain = true;
        };
        storage.filesystem_folder = cfg.dataDir;
      };
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 radicale radicale - -"
    ];
  };
}
