{ config, lib, pkgs, ... }:

with lib;

# We use `smtp.` and `imap.` so that clients which randomly guess
# configurations would have a better chance.

let
  rootCfg = config.mylittleserver;
  cfg = config.mylittleserver.mail;

  inherit (rootCfg) domain;

  roundcubeDb = config.services.roundcube.database.dbname;

  dkimPublicKey = replaceStrings ["\n"] [""] cfg.dkim.publicKey;

in {
  options = {
    mylittleserver.mail = {
      enable = mkEnableOption "MyLittleServer mail module";

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/mylittleserver/dovecot2";
        description = ''
          Mail (Dovecot) data directory.
        '';
      };

      maxSizeMb = mkOption {
        type = types.int;
        default = 32;
        description = ''
          Maximum allowed e-mail size.
        '';
      };

      dkim = {
        publicKey = mkOption {
          type = types.str;
          description = ''
            DKIM public key.
          '';
        };

        privateKeyPath = mkOption {
          type = types.path;
          description = mdDoc ''
            DKIM private key file path. Needs to be accessible by `rspamd` user.
          '';
        };
      };
    };
  };

  config = mkIf (rootCfg.enable && cfg.enable) {
    mylittleserver.dnsRecords = ''
      # "smtp" needs A and/or AAAA records.
      imap CNAME ${domain}.
      mail CNAME ${domain}.
      @ MX 10 smtp.${domain}.
      @ TXT "v=spf1 mx -all"
      mail._domainkey TXT "v=DKIM1; h=sha256; s=email; p=${dkimPublicKey}; t=s"
      _dmarc TXT "v=DMARC1; p=reject; rua=mailto:dmarc@${domain}; ruf=mailto:dmarc-forensics@${domain}; fo=1"
    '';

    nixpkgs.overlays = singleton (final: prev: {
      postfix = prev.postfix.override {
        withPgSQL = true;
      };

      dovecot = prev.dovecot.override {
        withPgSQL = true;
        withSQLite = false;
      };
    });

    networking.firewall.allowedTCPPorts = [
      25 # SMTP
      587 # SMTP submission
      143 # IMAP
      993 # IMAPS
      4190 # Sieve
    ];

    environment.systemPackages = with pkgs; [
      # To filter mail queue.
      jq
    ];

    services.nginx.virtualHosts = {
      ${domain}.locations = {
        "= /.well-known/autoconfig/mail/config-v1.1.xml" = {
          alias = pkgs.substituteAll {
            src = ./autoconfig.xml;
            inherit (rootCfg) domain;
            extra = "";
          };
          extraConfig = ''
            types { } default_type "application/xml; charset=utf-8";
            add_header Access-Control-Allow-Origin '*' always;
          '';
        };
      };
      "mail.${domain}" = {
        forceSSL = true;
        enableACME = true;
        locations."/".extraConfig = ''
          client_max_body_size ${toString cfg.maxSizeMb}m;
        '';
      };
    };

    services.roundcube = {
      enable = true;
      hostName = "mail.${domain}";
      plugins = [ "managesieve" ];
      maxAttachmentSize = cfg.maxSizeMb;
      extraConfig = ''
        $config['username_domain'] = '${domain}';
        $config['username_domain_forced'] = true;
      '';
    };

    services.postfix = let
      configs = pkgs.substituteAllFiles {
        src = ./postfix;
        files = [ "main.cf" "alias_maps.cf" "login_maps.cf" "recipient_maps.cf" "header_checks.cf" ];

        inherit domain;
        inherit (rootCfg.accounts) database;
      };
    in {
      enable = true;

      hostname = "smtp.${domain}";
      inherit domain;
      destination = [ ];
      networksStyle = "host";
      postmasterAlias = "";

      sslCert = "/var/lib/acme/smtp.${domain}/full.pem";
      sslKey = "/var/lib/acme/smtp.${domain}/full.pem";

      mapFiles = {
        "sender_access" = pkgs.substituteAll {
          src = ./postfix/sender_access.cf;
          inherit domain;
        };

        "recipient_access" = pkgs.substituteAll {
          src = ./postfix/recipient_access.cf;
          inherit domain;
        };

        "restrict_admin" = pkgs.substituteAll {
          src = ./postfix/restrict_admin.cf;
          inherit domain;
        };
      };

      extraConfig = ''
        message_size_limit = ${toString (cfg.maxSizeMb * 1024 * 1024)}
        ${builtins.readFile "${configs}/main.cf"}
      '';
      extraMasterConf = builtins.readFile ./postfix/master.cf;
    };

    services.postsrsd = {
      enable = true;
      inherit domain;
    };

    services.redis.servers.rspamd = {
      enable = true;
      port = 0;
      bind = null;
      user = "rspamd";
      settings.maxmemory = "128mb";
    };

    services.rspamd = {
      enable = true;
      # debug = true;
      locals = {
        "dkim_signing.conf".source = pkgs.substituteAll {
          src = ./rspamd/dkim_signing.conf;
          inherit domain;
          dkimPrivateKeyPath = cfg.dkim.privateKeyPath;
        };
        "milter_headers.conf".source = ./rspamd/milter_headers.conf;
        "replies.conf".source = ./rspamd/replies.conf;
        "neural.conf".source = ./rspamd/neural.conf;
        "neural_group.conf".source = ./rspamd/neural_group.conf;
        "redis.conf".source = ./rspamd/redis.conf;
        "classifier-bayes.conf".source = ./rspamd/classifier-bayes.conf;
      };

      workers = {
        controller = {
          includes = [ "$CONFDIR/worker-controller.inc" ];
          bindSockets = [
            { socket = "/run/rspamd/controller.sock";
              mode = "0660";
            }
          ];
        };
      };

      postfix.enable = true;
    };

    services.dovecot2 = {
      enable = true;
      modules = with pkgs; [ dovecot_pigeonhole ];

      enablePop3 = false;
      enableLmtp = true;
      protocols = [ "sieve" ];
      mailLocation = "mdbox:%h/mdbox";
      enablePAM = false;
      sslCACert = "/var/lib/acme/imap.${domain}/full.pem";
      sslServerCert = "/var/lib/acme/imap.${domain}/full.pem";
      sslServerKey = "/var/lib/acme/imap.${domain}/full.pem";

      mailUser = "dovecot2-mail";
      mailGroup = "dovecot2-mail";

      sieveScripts = {
        "before" = ./dovecot/sieve-before.d;
        "system" = ./dovecot/sieve-system;
      };

      extraConfig = let
        configs = pkgs.substituteAllFiles {
          src = ./dovecot;
          files = [ "dovecot.conf" "dovecot-sql.conf.ext" ];

          inherit domain;
          inherit (cfg) dataDir;
          inherit (rootCfg.accounts) database;
          sieveBin = pkgs.symlinkJoin {
            name = "sieve-bin";
            paths = [
              # Runs as `dovecot2-mail`; should have the necessary permissions.
              (pkgs.writeScriptBin "learn-spam" ''
                #!${pkgs.stdenv.shell}
                user="$1"
                exec ${pkgs.rspamd}/bin/rspamc -h /run/rspamd/controller.sock -u "$user" learn_spam
              '')
              (pkgs.writeScriptBin "learn-ham" ''
                #!${pkgs.stdenv.shell}
                user="$1"
                exec ${pkgs.rspamd}/bin/rspamc -h /run/rspamd/controller.sock -u "$user" learn_ham
              '')
            ];
          };
        };
      in builtins.readFile "${configs}/dovecot.conf";
    };

    systemd.services."mls-init-mail-database" = {
      description = "Initialize MyLittleServer's mail database.";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.service" "mls-init-basic-database.service" ];
      before = [ "postfix.service" "dovecot2.service" ];
      path = [ config.services.postgresql.package ];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
      };
      script = ''
        psql ${escapeShellArg rootCfg.accounts.database} < ${pkgs.substituteAll {
          src = ./init.sql;
          inherit domain;
        }}
      '';
    };

    services.postgresql = {
      ensureDatabases = [ roundcubeDb ];
      ensureUsers = [
        {
          name = "postfix";
        }
        {
          name = "dovecot2";
        }
        {
          name = "roundcube";
          ensurePermissions = { "DATABASE \"${roundcubeDb}\"" = "ALL PRIVILEGES"; };
        }
      ];
    };

    mylittleserver.ssl.nonHttpsCerts = {
      "imap.${domain}" = {};
      "smtp.${domain}" = {};
    };

    security.acme.certs = {
      "imap.${domain}" = {
        group = "dovecot2";
        postRun = ''
          systemctl reload dovecot2
        '';
      };
      "smtp.${domain}" = {
        group = "postfix";
        postRun = ''
          systemctl reload postfix
        '';
      };
    };

    security.dhparams = {
      enable = true;
      params.postfix = {};
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 dovecot2-mail dovecot2-mail - -"
    ];

    users = {
      users = {
        dovecot2-mail = {
          group = "dovecot2-mail";
          isSystemUser = true;
          extraGroups = [ "rspamd" ];
        };
      };
      groups = {
        dovecot2-mail = {};
      };
    };
  };
}
