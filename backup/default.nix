{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  rootCfg = config.mylittleserver;
  cfg = config.mylittleserver.backup;

  pg = config.services.postgresql;

  databases = unique cfg.databases;

  dbJob = db: "mylittleserver-db-${db}";

  common = {
    inherit (cfg) repository passwordFile environmentFile;
  };
in {
  options.mylittleserver.backup = {
    enable = mkEnableOption "MyLittleServer restic backups";

    repository = mkOption {
      type = types.str;
      example = "sftp:backup@nas.example.com:/srv/restic/mylittleserver";
      description = ''
        restic repository to back up to.
      '';
    };

    passwordFile = mkOption {
      type = types.path;
      example = "/run/secrets/restic-password";
      description = ''
        Restic repository password file.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Extra environment variables for restic.
      '';
    };

    timerConfig = mkOption {
      type = types.attrsOf types.anything;
      default = {
        OnCalendar = "daily";
        Persistent = true;
      };
      description = ''
        When to run the backup.
      '';
    };

    pruneOpts = mkOption {
      type = types.listOf types.str;
      default = [
        "--keep-daily 7"
        "--keep-weekly 5"
        "--keep-monthly 12"
      ];
      description = "Retention options.";
    };

    paths = mkOption {
      type = types.listOf types.path;
      default = [];
      internal = true;
      description = ''
        On-disk data directories to back up.
      '';
    };

    databases = mkOption {
      type = types.listOf types.str;
      default = [];
      internal = true;
      description = ''
        PostgreSQL databases to dump and back up.
      '';
    };

    after = mkOption {
      type = types.listOf types.str;
      default = [];
      internal = true;
      description = ''
        systemd units that the backup of {option}`paths` waits for.
      '';
    };
  };

  config = mkIf (rootCfg.enable && cfg.enable) {
    services.restic.backups =
      {
        mylittleserver =
          common
          // {
            inherit (cfg) pruneOpts timerConfig;
            initialize = true;
            paths = cfg.paths;
          };
      }
      // listToAttrs (map (
          db:
            nameValuePair (dbJob db) (common
              // {
                initialize = false;
                pruneOpts = [];
                timerConfig = null;
                command = [
                  "${pkgs.util-linux}/bin/runuser"
                  "-u"
                  pg.superUser
                  "--"
                  "${pg.package}/bin/pg_dump"
                  "--format=custom"
                  "--compress=0"
                  db
                ];
                extraBackupArgs = [
                  "--stdin-filename"
                  "${db}.dump"
                  "--tag"
                  "postgresql"
                  "--tag"
                  db
                ];
              })
        )
        databases);

    systemd.services =
      {
        restic-backups-mylittleserver.after = cfg.after;
      }
      // listToAttrs (map (
          db:
            nameValuePair "restic-backups-${dbJob db}" {
              requires = ["postgresql.service"];
              # Run it together and after the main backup initializes the repo and prunes.
              wantedBy = ["restic-backups-mylittleserver.service"];
              after = [
                "postgresql.service"
                "restic-backups-mylittleserver.service"
              ];
            }
        )
        databases);
  };
}
