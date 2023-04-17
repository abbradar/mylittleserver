{ lib, config, pkgs, ... }:

with lib;

let
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
    mylittleserver.nginx.pam = true;

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
          extraConfig = ''
            auth_pam "Restricted area";
            auth_pam_service_name "mylittleserver";

            proxy_set_header X-Remote-User $local_part;
          '';
        };
      };
    };

    services.radicale = {
      enable = true;
      settings = {
        server.hosts = [ "127.0.0.1:5232" ];
        auth.type = "http_x_remote_user";
        storage.filesystem_folder = cfg.dataDir;
      };
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 radicale radicale - -"
    ];
  };
}
