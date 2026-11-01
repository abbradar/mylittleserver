{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  rootCfg = config.mylittleserver;
  cfg = config.mylittleserver.turn;

  inherit (rootCfg) domain;
in {
  options = {
    mylittleserver.turn = {
      enable = mkEnableOption "MyLittleServer TURN module";

      secretFile = mkOption {
        type = types.str;
        example = "/run/secrets/turn-secret";
        description = ''
          File with the TURN static auth secret, without a trailing newline. Passed to
          services via systemd credentials, so it doesn't end up in the Nix store.
        '';
      };
    };
  };

  config = mkIf (rootCfg.enable && cfg.enable) {
    mylittleserver.dnsRecords = ''
      turn CNAME ${domain}.
    '';

    networking.firewall = {
      allowedTCPPorts = [
        3478 # STUN
        5349 # STUNS
      ];
      allowedUDPPorts = [
        3478 # STUN
        5349 # STUNS
      ];
      allowedUDPPortRanges = [
        {
          from = 49152;
          to = 65535;
        } # TURN
      ];
    };

    services.coturn = {
      enable = true;
      no-cli = true;
      use-auth-secret = true;
      static-auth-secret-file = ''"$CREDENTIALS_DIRECTORY"/turn-secret'';
      realm = "turn.${domain}";
      no-tcp-relay = true;
      cert = "/var/lib/acme/turn.${domain}/fullchain.pem";
      pkey = "/var/lib/acme/turn.${domain}/key.pem";
      # https://www.rtcsec.com/article/slack-webrtc-turn-compromise-and-bug-bounty/#how-to-fix-an-open-turn-relay-to-address-this-vulnerability
      extraConfig = ''
        denied-peer-ip=0.0.0.0-0.255.255.255
        denied-peer-ip=10.0.0.0-10.255.255.255
        denied-peer-ip=100.64.0.0-100.127.255.255
        denied-peer-ip=127.0.0.0-127.255.255.255
        denied-peer-ip=169.254.0.0-169.254.255.255
        denied-peer-ip=172.16.0.0-172.31.255.255
        denied-peer-ip=192.0.0.0-192.0.0.255
        denied-peer-ip=192.0.2.0-192.0.2.255
        denied-peer-ip=192.88.99.0-192.88.99.255
        denied-peer-ip=192.168.0.0-192.168.255.255
        denied-peer-ip=198.18.0.0-198.19.255.255
        denied-peer-ip=198.51.100.0-198.51.100.255
        denied-peer-ip=203.0.113.0-203.0.113.255
        denied-peer-ip=240.0.0.0-255.255.255.255
        no-loopback-peers
        no-multicast-peers

        no-tlsv1
        no-tlsv1_1
      '';
    };

    systemd.services.coturn.serviceConfig.LoadCredential = ["turn-secret:${cfg.secretFile}"];

    mylittleserver.ssl.nonHttpsCerts."turn.${domain}" = {};

    security.acme.certs."turn.${domain}" = {
      group = "turnserver";
      postRun = ''
        systemctl restart coturn
      '';
    };
  };
}
