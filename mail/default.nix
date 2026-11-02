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

  # DNS blocklists like Spamhaus refuse queries from large public
  # resolvers. Resolve the blocklist zones ourselves instead.
  dnsBlocklistPolicy =
    pkgs.runCommand "kresd-dns-blocklists.lua" {
      nativeBuildInputs = [config.services.rspamd.package pkgs.jq];
    } ''
      rspamadm --var=DBDIR="$TMPDIR" --var=RUNDIR="$TMPDIR" \
        --var=LOCAL_CONFDIR=${config.environment.etc.rspamd.source} \
        configdump -j -c ${config.services.rspamd.package}/etc/rspamd/rspamd.conf rbl > rbl.json
      jq -r '
        [.rbls[] | select(.enabled != false) | .rbl | strings] | unique
        | "policy.add(policy.suffix(policy.PASS, policy.todnames({\(map("\u0027\(.)\u0027") | join(", "))})))"
      ' rbl.json > $out
    '';

  mtaStsPolicyText = ''
    version: STSv1
    mode: enforce
    mx: mx.${domain}
    max_age: 604800
  '';

  mtaStsPolicy = pkgs.writeText "mta-sts.txt" mtaStsPolicyText;

  mtaStsId = substring 0 16 (builtins.hashString "sha256" mtaStsPolicyText);

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
        default = "/var/lib/mylittleserver/dovecot";
        description = ''
          Mail (Dovecot) data directory.
        '';
      };

      rspamdDataDir = mkOption {
        type = types.path;
        default = "/var/lib/mylittleserver/redis-rspamd";
        description = ''
          rspamd Redis data directory, which holds the learned Bayes statistics.
        '';
      };

      purgeAt = mkOption {
        type = types.str;
        default = "12:00";
        description = ''
          When to purge expunged mails, in {manpage}`systemd.time(7)` format.
          Should not overlap with backups.
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
        selector = mkOption {
          type = types.str;
          default = "mail";
          description = ''
            DKIM selector.
          '';
        };

        publicKey = mkOption {
          type = types.str;
          description = ''
            DKIM public key.
          '';
        };

        privateKeyPath = mkOption {
          type = types.path;
          description = ''
            DKIM private key file path. Needs to be accessible by `rspamd` user.
          '';
        };
      };
    };
  };

  config = mkIf (rootCfg.enable && cfg.enable) {
    mylittleserver.backup = {
      paths = [cfg.dataDir cfg.rspamdDataDir];
      databases = ["roundcube"];
      after = ["dovecot-purge.service"];
    };

    mylittleserver.dnsRecords = ''
      ;; "mx" needs A and/or AAAA records.
      smtp CNAME ${domain}.
      imap CNAME ${domain}.
      mail CNAME ${domain}.
      mta-sts CNAME ${domain}.
      @ MX 10 mx.${domain}.
      @ TXT "v=spf1 mx -all"
      ${cfg.dkim.selector}._domainkey TXT "v=DKIM1; h=sha256; s=email; p=${dkimPublicKey}; t=s"
      _dmarc TXT "v=DMARC1; p=reject; rua=mailto:dmarc@${domain}"
      _mta-sts TXT "v=STSv1; id=${mtaStsId}"
      _smtp._tls TXT "v=TLSRPTv1; rua=mailto:tlsrpt@${domain}"
      _submissions._tcp SRV 0 1 465 smtp.${domain}.
      _submission._tcp SRV 0 1 587 smtp.${domain}.
      _imaps._tcp SRV 0 1 993 imap.${domain}.
      _imap._tcp SRV 0 1 143 imap.${domain}.
      _sieve._tcp SRV 0 1 4190 imap.${domain}.
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
      config.services.dovecot2.package.passthru.dovecot_pigeonhole
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
      "mta-sts.${domain}" = {
        forceSSL = true;
        enableACME = true;
        locations."= /.well-known/mta-sts.txt" = {
          alias = mtaStsPolicy;
          extraConfig = ''
            types { } default_type "text/plain; charset=utf-8";
          '';
        };
      };
    };

    services.roundcube = {
      enable = true;
      hostName = "mail.${domain}";
      plugins = ["managesieve" "markasjunk"];
      maxAttachmentSize = cfg.maxSizeMb;
      database.dbname = "roundcube";
      extraConfig = ''
        $config['username_domain'] = '${domain}';
        $config['username_domain_forced'] = true;
        # Use an lo-bound SMTP with no TLS requirement.
        $config['smtp_host'] = '127.0.0.1:588';
        $config['junk_mbox'] = 'Spam';
      '';
    };

    services.postfix = let
      commonSubmissionOptions = {
        syslog_name = "postfix/submission";
        cleanup_service_name = "submission-cleanup";
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

      submissionOptions =
        commonSubmissionOptions
        // {
          smtpd_tls_security_level = "encrypt";
        };
      submissionsOptions = commonSubmissionOptions;

      # Strips the sender's client details from submitted mail.
      settings.master.submission-cleanup = {
        type = "unix";
        private = false;
        maxproc = 0;
        command = "cleanup";
        args = ["-o" "header_checks=pcre:${./postfix/header_checks.cf}"];
      };

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
            inherit domain;
            inherit (rootCfg.accounts) database;
          };
      in {
        # Debugging
        # soft_bounce = true;

        # Core things
        myhostname = "mx.${domain}";
        # Matches the PTR record.
        smtp_helo_name = domain;
        mydestination = [];
        mynetworks_style = "host";
        virtual_mailbox_domains = [domain];
        alias_maps = [];
        virtual_alias_maps = ["pgsql:${replaceDatabase ./postfix/alias_maps.cf}"];
        smtpd_sender_login_maps = ["pgsql:${replaceDatabase ./postfix/login_maps.cf}"];
        virtual_mailbox_maps = ["pgsql:${replaceDatabase ./postfix/recipient_maps.cf}"];
        virtual_transport = "lmtp:unix:/run/dovecot2/lmtp";

        # Encryption (server-side)
        smtpd_tls_mandatory_ciphers = "high";
        smtpd_tls_mandatory_protocols = ">=TLSv1.2";
        smtpd_tls_chain_files = ["/var/lib/acme/mx.${domain}/full.pem"];

        smtpd_tls_session_cache_database = "btree:/var/lib/postfix/data/smtpd_tls_session_cache";
        smtpd_tls_session_cache_timeout = "3600s";

        smtpd_tls_received_header = true;

        # encryption (client-side)
        smtp_tls_mandatory_ciphers = "high";
        smtp_tls_mandatory_protocols = ">=TLSv1.2";
        smtp_dns_support_level = "dnssec";
        smtp_tls_security_level = "dane";
        smtp_tls_loglevel = mkDefault 1;

        smtp_tls_session_cache_database = "btree:/var/lib/postfix/data/smtp_tls_session_cache";
        smtp_tls_session_cache_timeout = "600s";

        # Authentication
        smtpd_sasl_security_options = ["noanonymous"];
        smtpd_sasl_type = "dovecot";
        smtpd_sasl_path = "/run/dovecot2/auth-postfix";

        # Slow spammers down
        smtpd_helo_required = true;
        smtpd_client_auth_rate_limit = mkDefault 10;
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
          # Check hostname validity
          "reject_non_fqdn_recipient"
          # Access rights check
          "check_recipient_access hash:/etc/postfix/recipient_access"
        ];

        # Limits
        message_size_limit = cfg.maxSizeMb * 1024 * 1024;
      };
    };

    # Force our DNS proxy.
    systemd.services.postfix.serviceConfig.BindReadOnlyPaths = let
      resolvConf = pkgs.writeText "postfix-resolv.conf" ''
        nameserver ${config.mylittleserver.dns-proxy.address}
        options trust-ad edns0
      '';
    in ["${resolvConf}:/etc/resolv.conf"];

    services.postsrsd = {
      enable = true;
      settings.domains = [domain];
    };

    mylittleserver.nginx.hstsHosts = ["mail.${domain}" "mta-sts.${domain}"];

    # Local validating resolver, for DNS blocklists and DANE.
    mylittleserver.dns-proxy = {
      enable = true;
      extraConfig = ''
        dofile('${dnsBlocklistPolicy}')
      '';
    };

    services.redis.servers.rspamd = {
      enable = true;
      port = 0;
      bind = null;
      user = "rspamd";
      settings = {
        dir = mkForce cfg.rspamdDataDir;
        maxmemory = "128mb";
        maxmemory-policy = "volatile-ttl";
      };
    };

    systemd.services.redis-rspamd.serviceConfig.ReadWritePaths = [cfg.rspamdDataDir];

    services.rspamd = {
      enable = true;
      # debug = true;
      locals = {
        "dkim_signing.conf".source = pkgs.replaceVars ./rspamd/dkim_signing.conf {
          inherit domain;
          dkimSelector = cfg.dkim.selector;
          dkimPrivateKeyPath = cfg.dkim.privateKeyPath;
        };
        "milter_headers.conf".source = ./rspamd/milter_headers.conf;
        "replies.conf".source = ./rspamd/replies.conf;
        "neural.conf".source = ./rspamd/neural.conf;
        "neural_group.conf".source = ./rspamd/neural_group.conf;
        "redis.conf".source = ./rspamd/redis.conf;
        "classifier-bayes.conf".source = ./rspamd/classifier-bayes.conf;
        "greylist.conf".source = ./rspamd/greylist.conf;
        "force_actions.conf".source = ./rspamd/force_actions.conf;
        "dmarc.conf".source = ./rspamd/dmarc.conf;
        "options.inc".text = ''
          dns {
            nameserver = ["${config.mylittleserver.dns-proxy.address}"];
          }
        '';
      };
      localLuaRules = ./rspamd/rspamd.local.lua;

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
      enablePAM = false;

      settings = {
        dovecot_config_version = "2.4.5";
        dovecot_storage_version = "2.4.0";

        protocols = {
          imap = true;
          lmtp = true;
          sieve = true;
        };

        # Users and paths
        mail_driver = "mdbox";
        mail_home = "${cfg.dataDir}/%{user | username}";
        mail_path = "%{home}/mdbox";
        mail_uid = "dovecot2-mail";
        mail_gid = "dovecot2-mail";
        # `postdrop` lets Sieve redirects and vacation replies queue mail.
        mail_access_groups = ["rspamd" "postdrop"];
        sendmail_path = "${config.services.postfix.package}/bin/sendmail";
        hostname = "imap.${domain}";
        postmaster_address = "postmaster@${domain}";
        # Start of "user-defined system IDs" on NixOS
        first_valid_uid = 400;

        # Pass user name unchanged to SQL.
        auth_username_format = "%{user}";

        # Limits
        mail_max_userip_connections = 100;

        # Plugins
        mail_plugins = {
          mail_compress = true;
          fts = true;
          fts_flatcurve = true;
        };
        mail_compress_write_method = "zstd";

        # Encryption
        ssl_server_cert_file = "/var/lib/acme/imap.${domain}/full.pem";
        ssl_server_key_file = "/var/lib/acme/imap.${domain}/full.pem";
        ssl_min_protocol = "TLSv1.2";
        ssl_server_prefer_ciphers = "server";

        # Authentication
        # We use database instead of PAM because we need to get full users list.
        sql_driver = "pgsql";
        "pgsql /run/postgresql".parameters.dbname = rootCfg.accounts.database;

        "passdb sql" = {
          default_password_scheme = "CRYPT";
          query = "SELECT name AS user, password FROM users WHERE name = '%{user | username}' AND enabled";
        };

        # Notice that we don't use "enabled"! All users, even disabled, should continue
        # to receive mail.
        "userdb sql" = {
          query = "SELECT name AS username FROM users WHERE name = '%{user | username}'";
          iterate_query = "SELECT name AS username FROM users";
        };

        # Services
        service = [
          {
            _section.name = "lmtp";
            "unix_listener lmtp" = {
              mode = "0600";
              user = "postfix";
              group = "postfix";
            };
          }
          {
            _section.name = "auth";
            user = "$SET:default_internal_user";
            "unix_listener auth-postfix" = {
              mode = "0600";
              user = "postfix";
              group = "postfix";
            };
          }
          {
            _section.name = "auth-worker";
            user = "$SET:default_internal_user";
          }
        ];

        # Protocols
        "protocol lmtp" = {
          mail_plugins.sieve = true;

          "sieve_script before" = {
            type = "before";
            path = ./dovecot/sieve-before.d;
          };
        };

        "protocol imap" = {
          mail_plugins.imap_sieve = true;

          # https://peterkieser.com/2011/03/25/androids-k-9-mail-battery-life-and-dovecots-push-imap/
          # https://joshdata.wordpress.com/2014/08/09/how-bad-is-imap-idle/
          imap_idle_notify_interval = "4 mins";
        };

        # Mail boxes
        "namespace inbox" = {
          separator = "/";
          inbox = true;

          "mailbox Trash" = {
            auto = "create";
            special_use = "\\Trash";
            autoexpunge = "30d";
          };
          "mailbox Drafts" = {
            auto = "create";
            special_use = "\\Drafts";
          };
          "mailbox Sent" = {
            auto = "create";
            special_use = "\\Sent";
          };
          "mailbox Archive" = {
            auto = "create";
            special_use = "\\Archive";
          };
          "mailbox Spam" = {
            auto = "create";
            special_use = "\\Junk";
            autoexpunge = "30d";
          };
        };

        # Sieve
        sieve_plugins = {
          sieve_imapsieve = true;
          sieve_extprograms = true;
        };
        sieve_global_extensions = {
          "vnd.dovecot.pipe" = true;
          "vnd.dovecot.environment" = true;
        };
        sieve_pipe_bin_dir = "${sieveBin}/bin";

        "sieve_script personal" = {
          driver = "file";
          path = "~/sieve";
          active_path = "~/.dovecot.sieve";
        };

        # From elsewhere to Spam folder
        "mailbox Spam"."sieve_script report-spam" = {
          type = "before";
          cause = "copy";
          path = ./dovecot/sieve-system/report-spam.sieve;
        };

        # From Spam folder to elsewhere
        "imapsieve_from Spam"."sieve_script report-ham" = {
          type = "before";
          cause = "copy";
          path = ./dovecot/sieve-system/report-ham.sieve;
        };

        # FTS
        "fts flatcurve" = {};
        fts_autoindex = true;
        "language en" = {
          default = true;
          tokenizers = ["generic" "email-address"];
          filters = ["lowercase"];
        };
      };
    };

    services.fail2ban = {
      enable = true;
      jails = let
        mailPorts = "smtp,submission,submissions,imap,imaps,sieve";
      in {
        postfix-sasl.settings = {
          filter = "postfix[mode=auth]";
          port = mailPorts;
        };
        dovecot.settings = {
          filter = "dovecot";
          port = mailPorts;
        };
        roundcube-auth.settings = {
          filter = "roundcube-auth";
          port = "http,https";
        };
      };
    };

    systemd.services.dovecot-purge = {
      description = "Purge expunged Dovecot mails";
      requires = ["dovecot.service"];
      after = ["dovecot.service"];
      startAt = cfg.purgeAt;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${getExe' config.services.dovecot2.package "doveadm"} purge -A";
      };
    };

    systemd.services."mls-init-mail-database" = {
      description = "Initialize MyLittleServer's mail database.";
      wantedBy = ["multi-user.target"];
      after = ["postgresql.service" "mls-init-basic-database.service"];
      before = ["postfix.service" "dovecot.service"];
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
          systemctl reload dovecot
        '';
      };
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 dovecot2-mail dovecot2-mail - -"
      "d '${cfg.rspamdDataDir}' 0700 rspamd rspamd - -"
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
