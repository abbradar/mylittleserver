{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  rootCfg = config.mylittleserver;
  cfg = config.mylittleserver.xmpp;

  inherit (rootCfg) domain;

  prosodyExtra = [
    # "stanzadebug"
    "idlecompat"
    "mam_adhoc"
    "presence_cache"
    "smacks"
    "presence_dedup"
    "http_upload_external"
  ];

  xmppDomains = [
    "conference.${domain}"
    "pubsub.${domain}"
  ];

  dbAuth = pkgs.python3.pkgs.callPackage ./db-auth {};
in {
  options = {
    mylittleserver.xmpp = {
      enable = mkEnableOption "MyLittleServer XMPP module";

      upload = {
        dir = mkOption {
          type = types.path;
          default = "/var/lib/mylittleserver/xmpp-upload";
          description = ''
            XMPP files upload directory.
          '';
        };

        maxSizeMb = mkOption {
          type = types.int;
          default = 128;
          description = ''
            Maximum allowed uploaded file size.
          '';
        };

        secret = mkOption {
          type = types.str;
          description = ''
            HTTP upload static auth secret.
          '';
        };
      };
    };
  };

  config = mkIf (rootCfg.enable && cfg.enable) {
    mylittleserver = {
      nginx.pam = true;
      turn.enable = true;
      hostMeta.links = [
        {
          rel = "urn:xmpp:alt-connections:websocket";
          href = "wss://xmpp.${domain}/xmpp-websocket/";
        }
        {
          rel = "urn:xmpp:alt-connections:xbosh";
          href = "wss://xmpp.${domain}/http-bind/";
        }
      ];
      dnsRecords = ''
        proxy65 CNAME ${domain}.
        xmpp CNAME ${domain}.
        _xmpp-client._tcp SRV 0 1 5222 xmpp.${domain}.
        _xmpps-client._tcp SRV 0 1 5223 xmpp.${domain}.
        _xmpp-server._tcp SRV 0 1 5269 xmpp.${domain}.
        _xmpp-server._tcp.conference SRV 0 1 5269 xmpp.${domain}.
        _xmpp-server._tcp.pubsub SRV 0 1 5269 xmpp.${domain}.
      '';
    };

    networking.firewall = {
      allowedTCPPorts = [
        5222 # XMPP client
        5223 # XMPPS client
        5269 # XMPP server
        7777 # SOCKS5 (XMPP file transfer)
      ];
    };

    services.prosody = {
      enable = true;
      package = pkgs.prosody.override {
        withOnlyInstalledCommunityModules =
          [
            "auth_http"
            "http_muc_log"
          ]
          ++ prosodyExtra;
        withExtraLuaPackages = libs: with libs; [luadbi-postgresql];
      };
      modules = {
        legacyauth = false;
        vcard = false;
        server_contact_info = true;
        announce = true;
        welcome = true;
        bosh = true;
        websocket = true;
        cloud_notify = true;
        bookmarks = true;
        # Use as a Component.
        proxy65 = false;
      };
      extraModules =
        [
          # Official modules
          "lastactivity"
          "vcard4"
          "vcard_legacy"
          "http"
          "csi_simple"
          "turn_external"
        ]
        ++ prosodyExtra;
      admins = ["admin@${domain}"];
      # We set the necessary options by ourselves.
      xmppComplianceSuite = false;
      extraConfig = let
        luaCfg = pkgs.replaceVars ./prosody.cfg.lua {
          inherit domain;
          uploadSecret = cfg.upload.secret;
          turnSecret = config.mylittleserver.turn.secret;
        };
      in ''
        Include "${luaCfg}"
      '';
      ssl = {
        # We can't use a certificate for the xmpp. subdomain:
        # https://dev.gajim.org/gajim/gajim/-/issues/7253
        key = "/var/lib/acme/${domain}/full.pem";
        cert = "/var/lib/acme/${domain}/full.pem";
        extraOptions = {
          dhparam = "/var/lib/dhparams/prosody.pem";
        };
      };
      httpInterfaces = ["127.0.0.1"];
      httpsPorts = [];
      s2sSecureAuth = true;
      # FIXME: upstream a NixOS patch to allow this value.
      # authentication = "http";
      virtualHosts.${domain} = {
        inherit domain;
        enabled = true;
      };
    };

    services.prosody-filer = {
      enable = true;
      settings = {
        secret = cfg.upload.secret;
        storeDir = cfg.upload.dir;
      };
    };

    services.nginx.virtualHosts = mkMerge [
      {
        "xmpp.${domain}" = {
          forceSSL = true;
          enableACME = true;
          # We set Host to the XMPP server host -- it's needed for Prosody.
          locations = {
            "/".root = pkgs.replaceVarsWith {
              src = ./conversejs/index.html;
              replacements = {inherit domain;};
              dir = ".";
            };
            "/upload/" = {
              alias = "${cfg.upload.dir}/";
              extraConfig = ''
                proxy_request_buffering off;
                client_max_body_size ${toString cfg.upload.maxSizeMb}m;

                # To view text files.
                charset utf-8;

                add_header X-Content-Type-Options nosniff;
                if ( $request_filename !~* \.(txt|png|jpg|jpeg|avif|gif|webp|pdf|mp3|ogg|m4a|mp4|webm)$ ){
                  # Nested `add_header` replaces all upper-level `add_header`s.
                  add_header Content-Disposition attachment;
                  add_header X-Content-Type-Options nosniff;
                }

                limit_except GET {
                  proxy_pass http://127.0.0.1:5050;
                }
              '';
            };
            "/http-bind/" = {
              proxyPass = "http://127.0.0.1:5280";
              extraConfig = ''
                proxy_set_header Host ${domain};
                proxy_set_header X-Forwarded-For $remote_addr;
                proxy_buffering off;
                tcp_nodelay on;
              '';
            };
            "/xmpp-websocket/" = {
              proxyPass = "http://127.0.0.1:5280";
              proxyWebsockets = true;
              extraConfig = ''
                proxy_set_header Host ${domain};
                proxy_set_header X-Forwarded-For $remote_addr;
                # Workaround for Websocket Sniffer
                proxy_set_header Sec-WebSocket-Protocol "xmpp";
                proxy_buffering off;
                tcp_nodelay on;
              '';
            };
            "/muc_log/" = {
              proxyPass = "http://127.0.0.1:5280";
              extraConfig = ''
                proxy_set_header Host conference.${domain};

                auth_pam "Restricted area";
                auth_pam_service_name "mylittleserver";
              '';
            };
          };
        };
      }

      (listToAttrs (map (host:
        nameValuePair host {
          onlySSL = false;
          forceSSL = false;
          locations."^~ /.well-known/acme-challenge/".root = config.security.acme.certs.${domain}.webroot;
        })
      xmppDomains))
    ];

    systemd.services = {
      "prosody-db-auth" = {
        description = "Responds to authentication requests from Prosody.";
        wantedBy = ["multi-user.target"];
        before = ["prosody.service"];
        after = ["network.target"];
        serviceConfig = {
          User = "db-auth";
          Group = "db-auth";
          DynamicUser = true;
          ExecStart = "${dbAuth}/bin/db_auth -p 12344 ${escapeShellArg rootCfg.accounts.database}";
          Restart = "on-failure";
        };
      };

      "mls-init-xmpp-database" = {
        description = "Initialize MyLittleServer's XMPP database.";
        wantedBy = ["multi-user.target"];
        after = ["postgresql.service" "mls-init-basic-database.service"];
        before = ["db-auth.service" "prosody.service"];
        path = [config.services.postgresql.package];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          Group = "postgres";
        };
        script = ''
          psql prosody < ${./init.sql}
        '';
      };
    };

    services.postgresql = {
      ensureDatabases = ["prosody"];
      ensureUsers = [
        {
          name = "prosody";
          ensureDBOwnership = true;
        }
        {
          name = "db-auth";
        }
      ];
    };

    security.dhparams = {
      enable = true;
      params.prosody = {};
    };

    security.acme.certs.${domain} = {
      extraDomainNames = xmppDomains;
      postRun = ''
        systemctl restart prosody
      '';
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.upload.dir}' 0750 prosody-filer prosody-filer - -"
    ];

    users = {
      groups.xmpp-ssl = {};
      users = {
        nginx.extraGroups = ["prosody-filer"];
        prosody.extraGroups = ["mylittleserver-ssl"];
      };
    };
  };
}
