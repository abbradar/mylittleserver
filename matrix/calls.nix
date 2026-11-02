{
  lib,
  config,
  ...
}:
with lib; let
  rootCfg = config.mylittleserver;
  cfg = config.mylittleserver.matrix.calls;

  inherit (rootCfg) domain;

  livekit = config.services.livekit.settings;
  jwtPort = config.services.lk-jwt-service.port;

  rtcTransport = {
    type = "livekit";
    livekit_service_url = "https://matrix-rtc.${domain}/livekit/jwt";
  };
in {
  options = {
    mylittleserver.matrix.calls = {
      enable = mkEnableOption "group calls (Element Call) via LiveKit";

      keyFile = mkOption {
        type = types.path;
        example = "/run/secrets/livekit-keys";
        description = ''
          LiveKit API key file in `<key>: <secret>` format; the secret must be at least
          32 characters long. Generate one with `livekit-server generate-keys`.
        '';
      };
    };
  };

  config = mkIf (rootCfg.enable && rootCfg.matrix.enable && cfg.enable) {
    mylittleserver = {
      dnsRecords = ''
        matrix-rtc CNAME ${domain}.
      '';
      matrix.clientWellKnown."org.matrix.msc4143.rtc_foci" = [rtcTransport];
      nginx.hstsHosts = ["matrix-rtc.${domain}"];
    };

    services.livekit = {
      enable = true;
      inherit (cfg) keyFile;
      settings = {
        rtc = {
          tcp_port = 7881;
          # Right after the TURN relay ports.
          port_range_start = 50176;
          port_range_end = 51199;
        };
        # Rooms are created by lk-jwt-service for authorized Matrix users only.
        room.auto_create = false;
      };
    };

    services.lk-jwt-service = {
      enable = true;
      inherit (cfg) keyFile;
      livekitUrl = "wss://matrix-rtc.${domain}/livekit/sfu";
    };

    systemd.services.lk-jwt-service.environment = {
      LIVEKIT_JWT_BIND = mkForce "127.0.0.1:${toString jwtPort}";
      # Only our users may start calls; others can join them.
      LIVEKIT_FULL_ACCESS_HOMESERVERS = domain;
    };

    networking.firewall = {
      allowedTCPPorts = [livekit.rtc.tcp_port];
      allowedUDPPortRanges = [
        {
          from = livekit.rtc.port_range_start;
          to = livekit.rtc.port_range_end;
        }
      ];
    };

    services.nginx.virtualHosts."matrix-rtc.${domain}" = {
      forceSSL = true;
      enableACME = true;
      locations = {
        "^~ /livekit/jwt/" = {
          proxyPass = "http://127.0.0.1:${toString jwtPort}/";
          recommendedProxySettings = true;
        };
        "^~ /livekit/sfu/" = {
          proxyPass = "http://127.0.0.1:${toString livekit.port}/";
          recommendedProxySettings = true;
          proxyWebsockets = true;
          extraConfig = ''
            proxy_buffering off;
            proxy_read_timeout 120s;
            proxy_send_timeout 120s;
          '';
        };
      };
    };

    services.matrix-synapse.settings = {
      experimental_features = {
        # MatrixRTC transport discovery, used by Element X.
        msc4143_enabled = true;
        # `state_after` in sync, for reliable call membership.
        msc4222_enabled = true;
      };
      matrix_rtc.transports = [rtcTransport];
      # Lets clients schedule "left the call" in case they drop off.
      max_event_delay_duration = "24h";
      rc_message = {
        per_second = 0.5;
        burst_count = 30;
      };
      rc_delayed_event_mgmt = {
        per_second = 1;
        burst_count = 20;
      };
    };
  };
}
