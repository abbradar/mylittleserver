{
  config,
  lib,
  pkgs,
  ...
}:
# We use `smtp.` and `imap.` so that clients which randomly guess
# configurations would have a better chance.
with lib; let
  rootCfg = config.mylittleserver;
  cfg = config.mylittleserver.mail;

  inherit (rootCfg) domain;

  dkimPublicKey = replaceStrings ["\n"] [""] cfg.dkim.publicKey;

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
      ;; "mx" needs A and/or AAAA records.
      smtp CNAME ${domain}.
      imap CNAME ${domain}.
      mail CNAME ${domain}.
      @ MX 10 mx.${domain}.
      @ TXT "v=spf1 mx -all"
      mail._domainkey TXT "v=DKIM1; h=sha256; s=email; p=${dkimPublicKey}; t=s"
      _dmarc TXT "v=DMARC1; p=reject; rua=mailto:dmarc@${domain}; fo=1"
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
      465 # SMTPS submission
      143 # IMAP
      993 # IMAPS
      4190 # Sieve
    ];

    environment.systemPackages = with pkgs; [
      # To filter mail queue.
      jq
      # Dovecot modules
      dovecot_pigeonhole
    ];

    services.nginx.virtualHosts = {
      ${domain}.locations = {
        "= /.well-known/autoconfig/mail/config-v1.1.xml" = {
          alias = pkgs.replaceVars ./autoconfig.xml {
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
      plugins = ["managesieve"];
      maxAttachmentSize = cfg.maxSizeMb;
      database.dbname = "roundcube";
      extraConfig = ''
        $config['username_domain'] = '${domain}';
        $config['username_domain_forced'] = true;
        # Use an lo-bound SMTP with no TLS requirement.
        $config['smtp_server'] = '127.0.0.1:588';
      '';
    };

    services.postfix = let
      commonSubmissionOptions = {
        syslog_name = "postfix/submission";
        smtp_helo_name = "smtp.${domain}";
        smtpd_sasl_auth_enable = "yes";
        smtpd_helo_restrictions = "";
        smtpd_client_restrictions = "$mua_client_restrictions";
        smtpd_sender_restrictions = "$mua_sender_restrictions";
        smtpd_recipient_restrictions = "$mua_recipient_restrictions";
        smtpd_data_restrictions = "";
      };
    in {
      enable = true;
      enableSubmission = true;
      enableSubmissions = true;

      postmasterAlias = "";

      mapFiles = {
        "sender_access" = pkgs.replaceVars ./postfix/sender_access.cf {
          inherit domain;
        };

        "recipient_access" = pkgs.replaceVars ./postfix/recipient_access.cf {
          inherit domain;
        };

        "restrict_admin" = pkgs.replaceVars ./postfix/restrict_admin.cf {
          inherit domain;
        };
      };

      submissionOptions = commonSubmissionOptions;
      submissionsOptions = commonSubmissionOptions;

      # For Roundcube, no TLS required.
      settings.master."127.0.0.1:588" = {
        type = "inet";
        private = false;
        command = "smtpd";
        args = let
          mkKeyVal = opt: val: [
            "-o"
            (opt + "=" + val)
          ];
        in
          concatLists (mapAttrsToList mkKeyVal commonSubmissionOptions);
      };

      settings.main = let
        replaceDatabase = maps:
          pkgs.replaceVars maps {
            inherit (rootCfg.accounts) database;
          };
      in {
        # Debugging
        # soft_bounce = true;

        # Core things
        myhostname = "mx.${domain}";
        mydestination = [];
        mynetworks_style = "host";
        virtual_mailbox_domains = [domain];
        alias_maps = [];
        virtual_alias_maps = ["pgsql:${replaceDatabase ./postfix/alias_maps.cf}"];
        smtpd_sender_login_maps = ["pgsql:${replaceDatabase ./postfix/login_maps.cf}"];
        virtual_mailbox_maps = ["pgsql:${replaceDatabase ./postfix/recipient_maps.cf}"];
        header_checks = ["pcre:${./postfix/header_checks.cf}"];
        virtual_transport = "lmtp:unix:/run/dovecot2/lmtp";

        # Encryption (server-side)
        smtpd_tls_mandatory_ciphers = "high";
        smtpd_tls_mandatory_protocols = ["!SSLv2" "!SSLv3"];
        smtpd_tls_chain_files = ["/var/lib/acme/mx.${domain}/full.pem"];

        smtpd_tls_session_cache_database = "btree:/var/lib/postfix/data/smtpd_tls_session_cache";
        smtpd_tls_session_cache_timeout = "3600s";

        smtpd_tls_received_header = true;

        # encryption (client-side)
        smtp_tls_mandatory_ciphers = "high";
        smtp_tls_mandatory_protocols = ["!SSLv2" "!SSLv3"];

        smtp_tls_session_cache_database = "btree:/var/lib/postfix/data/smtp_tls_session_cache";
        smtp_tls_session_cache_timeout = "600s";

        # Authentication
        smtpd_sasl_security_options = ["noanonymous"];
        smtpd_sasl_type = "dovecot";
        smtpd_sasl_path = "/run/dovecot2/auth-postfix";

        # Slow spammers down
        smtpd_helo_required = true;
        smtpd_delay_reject = true;
        disable_vrfy_command = true;

        # Sub-addressing via +
        recipient_delimiter = "+";

        # Admin-only hash
        smtpd_restriction_classes = "restrict_admin";
        restrict_admin = [
          "check_sender_access hash:/etc/postfix/restrict_admin"
          "reject"
        ];

        # Restrictions
        smtpd_client_restrictions = [
          # Check DNS PTR
          # (fails for e.g. bakabt.me)
          # "reject_unknown_client_hostname",
          # Reject pipelining
          "reject_unauth_pipelining"
        ];

        smtpd_helo_restrictions = [
          # Check hostname validity
          "reject_invalid_helo_hostname"
          "reject_non_fqdn_helo_hostname"
          # DNS check
          "reject_unknown_helo_hostname"
          # Reject pipelining
          "reject_unauth_pipelining"
        ];

        smtpd_sender_restrictions = [
          # Check hostname validity
          "reject_non_fqdn_sender"
          # Deny sending from "us"
          "check_sender_access hash:/etc/postfix/sender_access"
          # Check DNS reachability
          "reject_unknown_sender_domain"
          # Reject pipelining
          "reject_unauth_pipelining"
        ];

        smtpd_recipient_restrictions = [
          # Check hostname validity
          "reject_non_fqdn_recipient"
          # Deny if not for local for this server
          "reject_unauth_destination"
          # Deny if recipient does not exist on the server
          "reject_unknown_recipient_domain"
          "reject_unlisted_recipient"
          # Access rights check
          "check_recipient_access hash:/etc/postfix/recipient_access"
          # Reject pipelining
          "reject_unauth_pipelining"
        ];

        smtpd_data_restrictions = [
          # Reject pipelining
          "reject_unauth_pipelining"
        ];

        # For submission.
        mua_client_restrictions = [
          # Allow if authenticated
          "permit_sasl_authenticated"
          "reject"
        ];

        mua_sender_restrictions = [
          # Deny sending from not owned local address
          "reject_sender_login_mismatch"
        ];

        mua_recipient_restrictions = [
          # DNS check
          "reject_unknown_recipient_domain"
          # Check hostname validity
          "reject_non_fqdn_recipient"
          # Access rights check
          "check_recipient_access hash:/etc/postfix/recipient_access"
        ];

        # Limits
        message_size_limit = cfg.maxSizeMb * 1024 * 1024;
      };
    };

    services.postsrsd = {
      enable = true;
      settings.domains = [domain];
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
        "dkim_signing.conf".source = pkgs.replaceVars ./rspamd/dkim_signing.conf {
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
          # Restrict access to the controller.
          bindSockets = [
            {
              socket = "/run/rspamd/controller.sock";
              mode = "0660";
            }
          ];
        };
      };

      postfix.enable = true;
    };

    services.dovecot2 = {
      enable = true;
      enablePop3 = false;
      enableLmtp = true;
      protocols = ["sieve"];
      mailLocation = "mdbox:%h/mdbox";
      enablePAM = false;
      sslCACert = "/var/lib/acme/imap.${domain}/full.pem";
      sslServerCert = "/var/lib/acme/imap.${domain}/full.pem";
      sslServerKey = "/var/lib/acme/imap.${domain}/full.pem";

      mailUser = "dovecot2-mail";
      mailGroup = "dovecot2-mail";

      sieve.scripts = {
        "before" = ./dovecot/sieve-before.d;
        "system" = ./dovecot/sieve-system;
      };

      extraConfig = let
        dovecotSqlConf = pkgs.replaceVars ./dovecot/dovecot-sql.conf.ext {
          inherit (rootCfg.accounts) database;
        };
        dovecotConf = pkgs.replaceVars ./dovecot/dovecot.conf {
          inherit domain sieveBin dovecotSqlConf;
          inherit (cfg) dataDir;
        };
      in "!include ${dovecotConf}";
    };

    systemd.services."mls-init-mail-database" = {
      description = "Initialize MyLittleServer's mail database.";
      wantedBy = ["multi-user.target"];
      after = ["postgresql.service" "mls-init-basic-database.service"];
      before = ["postfix.service" "dovecot2.service"];
      path = [config.services.postgresql.package];
      serviceConfig = {
        Type = "oneshot";
        User = "postgres";
        Group = "postgres";
      };
      script = let
        script = pkgs.replaceVars ./init.sql {
          inherit domain;
        };
      in ''
        psql ${escapeShellArg rootCfg.accounts.database} < ${script}
      '';
    };

    services.postgresql = {
      ensureDatabases = ["roundcube"];
      ensureUsers = [
        {
          name = "postfix";
        }
        {
          name = "dovecot2";
        }
        {
          name = "roundcube";
          ensureDBOwnership = true;
        }
      ];
    };

    mylittleserver.ssl.nonHttpsCerts = {
      "mx.${domain}" = {};
      "smtp.${domain}" = {extraDomain = true;};
      "imap.${domain}" = {};
    };

    security.acme.certs = {
      "mx.${domain}" = {
        group = "postfix";
        extraDomainNames = ["smtp.${domain}"];
        postRun = ''
          systemctl reload postfix
        '';
      };
      "imap.${domain}" = {
        group = "dovecot2";
        postRun = ''
          systemctl reload dovecot2
        '';
      };
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 dovecot2-mail dovecot2-mail - -"
    ];

    users = {
      users = {
        dovecot2-mail = {
          group = "dovecot2-mail";
          isSystemUser = true;
          extraGroups = ["rspamd"];
        };
      };
      groups = {
        dovecot2-mail = {};
      };
    };
  };
}
