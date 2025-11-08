{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.mylittleserver;

  inherit (cfg) domain;

  acmeChallengePath = "/var/lib/acme/acme-challenge";

  hostMetaXml = pkgs.writeText "host-meta.xml" ''
    <?xml version="1.0" encoding="utf-8"?>

    <XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">
      ${concatMapStringsSep "\n" (meta: ''
        <Link rel="${meta.rel}" href="${meta.href}" />
      '')
      cfg.hostMeta.links}
    </XRD>
  '';

  hostMetaJson = pkgs.writeText "host-meta.json" (builtins.toJSON cfg.hostMeta);

  hostMetaLinksModule = {...}: {
    options = {
      rel = mkOption {
        type = types.str;
        description = ''
          Resource.
        '';
      };

      href = mkOption {
        type = types.str;
        description = ''
          Link.
        '';
      };
    };
  };

  mailuserBins = makeBinPath [pkgs.mkpasswd pkgs.gnused config.services.postgresql.package];

  mailuser = pkgs.writers.writeBashBin "mailuser" ''
    export PATH=${escapeShellArg mailuserBins}
    database=${escapeShellArg cfg.accounts.database}
    ${builtins.readFile ./mailuser.sh}
  '';
in {
  options = {
    mylittleserver = {
      enable = mkEnableOption "MyLittleServer";

      domain = mkOption {
        type = types.str;
        description = ''
          MyLittleServer domain.
        '';
      };

      accounts = {
        database = mkOption {
          type = types.str;
          default = "mylittleserver";
          description = ''
            PostgreSQL database that holds server accounts.
          '';
        };
      };

      ssl.nonHttpsCerts = mkOption {
        type = types.attrsOf (types.submodule {});
        default = {};
        internal = true;
        description = ''
          Certificates for hostnames that don't serve HTTPS.
        '';
      };

      hostMeta = {
        links = mkOption {
          type = types.listOf (types.submodule hostMetaLinksModule);
          internal = true;
          default = [];
          description = ''
            XRD links list.
          '';
        };
      };

      dnsRecords = mkOption {
        type = types.lines;
        internal = true;
        default = "";
        description = mdDoc ''
          DNS records that need to be added for the server to work.

          Exported to `/etc/mylittleserver.zone` for convenience.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    mylittleserver.dnsRecords = mkBefore ''
      # "@" needs A and/or AAAA records.
      # Also, the server's PTR record must point to ${domain}.
    '';

    networking.firewall.allowedTCPPorts = [
      80
      443 # HTTP
    ];

    environment.systemPackages = with pkgs; [
      mailuser
    ];

    services.postgresql = {
      enable = true;

      ensureDatabases = [cfg.accounts.database];

      ensureUsers = [
        {
          name = "auth";
          ensureClauses.login = false;
        }
        {
          name = "auth_update";
          ensureClauses.login = false;
        }
      ];
    };

    services.nginx = {
      enable = true;

      appendHttpConfig = ''
        # Trim local part of an email for authorization.
        map $remote_user $local_part {
          "~^(?<l>[^@]+)@${domain}$" $l;
          default $remote_user;
        }
      '';

      virtualHosts = mkMerge [
        {
          ${domain} = {
            forceSSL = true;
            enableACME = true;

            locations = {
              "= /.well-known/host-meta" = {
                alias = hostMetaXml;
                extraConfig = ''
                  types { } default_type "application/xrd+xml; charset=utf-8";
                  add_header Access-Control-Allow-Origin '*' always;
                '';
              };
              "= /.well-known/host-meta.json" = {
                alias = hostMetaJson;
                extraConfig = ''
                  types { } default_type "application/jrd+json; charset=utf-8";
                  add_header Access-Control-Allow-Origin '*' always;
                '';
              };
            };
          };
        }
        (mapAttrs (host: opts: {
            onlySSL = false;
            forceSSL = false;
            locations."^~ /.well-known/acme-challenge/".root = acmeChallengePath;
          })
          cfg.ssl.nonHttpsCerts)
      ];
    };

    security.acme.certs = mkMerge [
      {
        ${domain}.group = "mylittleserver-ssl";
      }

      (mapAttrs (host: opts: {
          webroot = acmeChallengePath;
          dnsProvider = mkOverride 1000 null;
        })
        cfg.ssl.nonHttpsCerts)
    ];

    systemd.services."mls-init-basic-database" = {
      description = "Initialize basic MyLittleServer database.";
      wantedBy = ["multi-user.target"];
      after = ["postgresql.service"];
      path = [config.services.postgresql.package];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
      };
      script = ''
        psql ${escapeShellArg cfg.accounts.database} < ${./init.sql}
      '';
    };

    environment.etc."mylittleserver.zone".text = ''
      $ORIGIN ${cfg.domain}.
      ${cfg.dnsRecords}
    '';

    users = {
      users.nginx.extraGroups = ["mylittleserver-ssl"];
      groups.mylittleserver-ssl = {};
    };
  };
}
