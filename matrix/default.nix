{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  rootCfg = config.mylittleserver;
  cfg = config.mylittleserver.matrix;

  inherit (rootCfg) domain;

  dbAuth = pkgs.python3.pkgs.callPackage ../db-auth/db-auth {
    withService = false;
  };

  matrixClientDiscover = pkgs.writeText "matrix-client-discover.json" (builtins.toJSON ({
      "m.homeserver"."base_url" = "https://matrix.${domain}";
    }
    // cfg.clientWellKnown));

  matrixServerDiscover = pkgs.writeText "matrix-server-discover.json" (builtins.toJSON {
    "m.server" = "matrix.${domain}:443";
  });
in {
  imports = [./calls.nix];

  options = {
    mylittleserver.matrix = {
      enable = mkEnableOption "MyLittleServer Matrix module";

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/mylittleserver/matrix-synapse";
        description = ''
          Synapse data directory.
        '';
      };

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

      clientWellKnown = mkOption {
        type = types.attrsOf types.anything;
        default = {};
        internal = true;
        description = ''
          Extra entries for `/.well-known/matrix/client`.
        '';
      };
    };
  };

  config = mkIf (rootCfg.enable && cfg.enable) {
    mylittleserver = {
      turn.enable = true;
      db-auth.allowedUsers = ["matrix-synapse"];
      nginx.hstsHosts = ["matrix.${domain}"];

      backup = {
        paths = [cfg.dataDir];
        databases = [cfg.database];
      };

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
          proxyPass = "http://unix://run/matrix-synapse/http.sock";
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
      dataDir = cfg.dataDir;
      plugins = [dbAuth];
      withJemalloc = true;
      enableRegistrationScript = false;

      settings = {
        password_config.localdb_enabled = false;
        modules = [
          {
            module = "db_auth.matrix.DBAuthProvider";
            config = {
              url = "http://127.0.0.1:12343";
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
        media_retention.remote_media_lifetime = "30d";
        forget_rooms_on_leave = true;
        forgotten_room_retention_period = "30d";
        turn_uris = [
          "turn:turn.${domain}:3478?transport=udp"
          "turn:turn.${domain}:3478?transport=tcp"
          # https://github.com/vector-im/riot-android/issues/3299
          # "turns:turn.${domain}:5349?transport=udp"
          # "turns:turn.${domain}:5349?transport=tcp"
        ];
        turn_shared_secret_path = "/run/credentials/matrix-synapse.service/turn-secret";
        listeners = [
          {
            path = "/run/matrix-synapse/http.sock";
            mode = "660";
            type = "http";
            x_forwarded = true;
            resources = [
              {
                names = ["client" "federation"];
                compress = false;
              }
            ];
          }
        ];
      };
    };

    services.synapse-auto-compressor = {
      enable = true;
      postgresUrl = "postgresql://matrix-synapse@${escapeURL "/run/postgresql"}/${cfg.database}";
    };

    systemd.services.matrix-synapse.serviceConfig.LoadCredential = ["turn-secret:${config.mylittleserver.turn.secretFile}"];

    systemd.services."mls-init-matrix-database" = {
      description = "Initialize MyLittleServer's Matrix database.";
      wantedBy = ["multi-user.target"];
      after = ["postgresql.service" "mls-init-basic-database.service"];
      before = ["matrix-synapse.service"];
      path = [config.services.postgresql.package];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
      };
      script = let
        script = pkgs.replaceVars ./init.sql {
          inherit (cfg) database;
        };
      in ''
        psql postgres < ${script}
      '';
    };

    services.postgresql = {
      ensureUsers = [
        {
          name = "matrix-synapse";
        }
      ];
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 matrix-synapse matrix-synapse - -"
    ];

    users.users.nginx.extraGroups = ["matrix-synapse"];
  };
}
