{ lib, config, pkgs, ... }:

with lib;

let
  rootCfg = config.mylittleserver;
  cfg = config.mylittleserver.matrix;

  inherit (rootCfg) domain;

   matrixClientDiscover = pkgs.writeText "matrix-client-discover.json" (builtins.toJSON {
     "m.homeserver"."base_url" = "https://matrix.${domain}";
   });

   matrixServerDiscover = pkgs.writeText "matrix-server-discover.json" (builtins.toJSON {
     "m.server" = "matrix.${domain}:443";
   });

in {
  options = {
    mylittleserver.matrix = {
      enable = mkEnableOption "MyLittleServer Matrix module";

      database = mkOption {
        type = types.str;
        default = "matrix_synapse";
        description = ''
          Synapse PostgreSQL database.
        '';
      };

      upload.maxSizeMb = mkOption {
        type = types.int;
        default = 128;
        description = ''
          Maximum allowed uploaded file size.
        '';
      };
    };
  };

  config = mkIf (rootCfg.enable && cfg.enable) {
    mylittleserver = {
      turn.enable = true;
      pam.enable = true;

      dnsRecords = ''
        matrix CNAME ${domain}.
        _matrix._tcp SRV 0 1 443 matrix.${domain}.
      '';
    };

    services.nginx.virtualHosts = {
      ${domain}.locations = {
        "= /.well-known/matrix/client" = {
          alias = matrixClientDiscover;
          extraConfig = ''
            types { } default_type "application/json; charset=utf-8";
            add_header Access-Control-Allow-Origin '*' always;
          '';
        };

        "= /.well-known/matrix/server" = {
          alias = matrixServerDiscover;
          extraConfig = ''
            types { } default_type "application/json; charset=utf-8";
            add_header Access-Control-Allow-Origin '*' always;
          '';
        };
      };

      "matrix.${domain}" = {
        forceSSL = true;
        enableACME = true;

        locations."/" = {
          proxyPass = "http://127.0.0.1:8008";
          extraConfig = ''
            client_max_body_size ${toString cfg.upload.maxSizeMb}m;

            proxy_http_version 1.1;
            proxy_set_header X-Forwarded-For $remote_addr;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Host $host;
          '';
        };
      };
    };

    services.matrix-synapse = {
      enable = true;
      plugins = with pkgs.matrix-synapse-plugins; [ matrix-synapse-pam ];
      withJemalloc = true;
      settings = {
        password_config.localdb_enabled = false;
        password_providers = [
          { module = "pam_auth_provider.PAMAuthProvider";
            config = {
              create_users = true;
              skip_user_check = true;
            };
          }
        ];
        server_name = domain;
        database = {
          name = "psycopg2";
          args = {
            database = cfg.database;
          };
        };
        public_baseurl = "https://matrix.${domain}/";
        max_upload_size = "${toString cfg.upload.maxSizeMb}M";
        url_preview_enabled = true;
        turn_uris = [
          "turn:turn.${domain}:3478?transport=udp"
          "turn:turn.${domain}:3478?transport=tcp"
          # https://github.com/vector-im/riot-android/issues/3299
          # "turns:turn.${domain}:5349?transport=udp"
          # "turns:turn.${domain}:5349?transport=tcp"
        ];
        turn_shared_secret = config.mylittleserver.turn.secret;
        listeners = [{
          port = 8008;
          bind_addresses = ["127.0.0.1"];
          type = "http";
          tls = false;
          x_forwarded = true;
          resources = [
            { names = ["client"]; compress = false; }
            { names = ["federation"]; compress = false; }
          ];
        }];
      };
    };

    systemd.services."mls-init-matrix-database" = {
      description = "Initialize MyLittleServer's Matrix database.";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.service" "mls-init-basic-database.service" ];
      before = [ "matrix-synapse.service" ];
      path = [ config.services.postgresql.package ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
      };
      script = ''
        psql ${escapeShellArg cfg.database} < ${./init.sql}
      '';
    };

    services.postgresql = {
      ensureUsers = [
        {
          name = "matrix-synapse";
        }
      ];
    };

    security.pam.services.matrix-synapse.text = config.security.pam.services.mylittleserver.text;

    systemd.tmpfiles.rules = [
      "d '${config.services.matrix-synapse.dataDir}' 0700 matrix-synapse matrix-synapse - -"
    ];
  };
}
