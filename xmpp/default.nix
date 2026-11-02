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
    "limit_auth"
    "sasl2"
    "sasl2_bind2"
    "sasl2_sm"
    "anti_spam"
    "spam_reporting"
    "report_forward"
  ];

  conversejs = pkgs.callPackage ./conversejs/package.nix {};
  # Changes with every package update, so the assets can be cached forever.
  conversejsPath = "/converse/${baseNameOf (builtins.unsafeDiscardStringContext conversejs.outPath)}";

  xmppSubdomains = [
    "conference"
    "pubsub"
    "upload"
  ];

  xmppDomains = map (name: "${name}.${domain}") xmppSubdomains;
in {
  options = {
    mylittleserver.xmpp = {
      enable = mkEnableOption "MyLittleServer XMPP module";

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/mylittleserver/prosody";
        description = ''
          Prosody data directory. Uploaded files are stored here.
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
      backup = {
        paths = [cfg.dataDir];
        databases = ["prosody"];
      };
      nginx = {
        authDomains = ["xmpp.${domain}"];
        hstsHosts = ["xmpp.${domain}"];
      };
      turn.enable = true;
      db-auth.allowedUnsafeUsers = ["prosody"];
      hostMeta.links = [
        {
          rel = "urn:xmpp:alt-connections:websocket";
          href = "wss://xmpp.${domain}/xmpp-websocket/";
        }
        {
          rel = "urn:xmpp:alt-connections:xbosh";
          href = "https://xmpp.${domain}/http-bind/";
        }
      ];
      dnsRecords = ''
        proxy65 CNAME ${domain}.
        xmpp CNAME ${domain}.
        ${concatMapStringsSep "\n" (subdomain: ''
            ${subdomain} CNAME xmpp.${domain}.
          '')
          xmppSubdomains}
        _xmpp-client._tcp SRV 0 1 5222 xmpp.${domain}.
        _xmpps-client._tcp SRV 0 1 5223 xmpp.${domain}.
        _xmpp-server._tcp SRV 0 1 5269 xmpp.${domain}.
        ${concatMapStringsSep "\n" (subdomain: ''
            _xmpp-server._tcp.${subdomain} SRV 0 1 5269 xmpp.${domain}.
          '')
          xmppSubdomains}
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
      inherit (cfg) dataDir;
      package = pkgs.prosody.override {
        withOnlyInstalledCommunityModules =
          [
            "auth_http"
            "http_muc_log"
            "pubsub_subscription"
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
          # Local modules
          "limit_auth_sasl2"
        ]
        ++ prosodyExtra;
      extraPluginPaths = [./prosody-modules];
      admins = ["admin@${domain}"];
      # We set the necessary options by ourselves.
      xmppComplianceSuite = false;
      extraConfig = let
        luaCfg = pkgs.replaceVars ./prosody.cfg.lua {
          inherit domain;
          dnsRootKey = "${pkgs.dns-root-data}/root.key";
        };
      in ''
        Include "${luaCfg}"
      '';
      ssl = {
        # We can't use a certificate for the xmpp. subdomain:
        # https://dev.gajim.org/gajim/gajim/-/issues/7253
        key = "/var/lib/acme/${domain}/full.pem";
        cert = "/var/lib/acme/${domain}/full.pem";
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
      httpFileShare = {
        domain = "upload.${domain}";
        http_host = domain;
        http_external_url = "https://xmpp.${domain}/";
        size_limit = cfg.upload.maxSizeMb * 1024 * 1024;
        expires_after = "never";
      };
    };

    systemd.services.prosody.serviceConfig.LoadCredential = ["turn-secret:${config.mylittleserver.turn.secretFile}"];

    services.nginx.virtualHosts."xmpp.${domain}" = {
      forceSSL = true;
      enableACME = true;
      # We set Host to the XMPP server host -- it's needed for Prosody.
      locations = {
        "/" = {
          root = pkgs.replaceVarsWith {
            src = ./conversejs/index.html;
            replacements = {
              inherit domain;
              assets = conversejsPath;
            };
            dir = ".";
          };
          extraConfig = ''
            add_header Cache-Control "no-cache";
          '';
        };
        "^~ ${conversejsPath}/" = {
          alias = "${conversejs}/";
          extraConfig = ''
            add_header Cache-Control "public, max-age=31536000, immutable";
          '';
        };
        "/upload/" = {
          proxyPass = "http://127.0.0.1:5280";
          extraConfig = ''
            proxy_set_header Host ${domain};
            proxy_set_header X-Forwarded-For $remote_addr;
            proxy_request_buffering off;
            proxy_buffering off;
            client_max_body_size ${toString cfg.upload.maxSizeMb}m;
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

            auth_request /internal/auth;
          '';
        };
      };
    };

    services.postgresql = {
      ensureDatabases = ["prosody"];
      ensureUsers = [
        {
          name = "prosody";
          ensureDBOwnership = true;
        }
      ];
    };

    mylittleserver.ssl.nonHttpsCerts = listToAttrs (map (domain: nameValuePair domain {extraDomain = true;}) xmppDomains);

    security.acme.certs.${domain} = {
      extraDomainNames = xmppDomains;
      postRun = ''
        systemctl restart prosody
      '';
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 prosody prosody - -"
    ];

    users = {
      groups.xmpp-ssl = {};
      users = {
        prosody.extraGroups = ["mylittleserver-ssl"];
      };
    };
  };
}
