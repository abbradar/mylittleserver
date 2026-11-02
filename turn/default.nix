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

  ip = import ../lib/ip.nix {inherit lib;};
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
          from = config.services.coturn.min-port;
          to = config.services.coturn.max-port;
        } # TURN
      ];
    };

    services.coturn = {
      enable = true;
      use-auth-secret = true;
      static-auth-secret-file = ''"$CREDENTIALS_DIRECTORY"/turn-secret'';
      realm = "turn.${domain}";
      no-tcp-relay = true;
      # The first 1024 ports of the IANA dynamic range.
      min-port = 49152;
      max-port = 50175;
      cert = "/var/lib/acme/turn.${domain}/fullchain.pem";
      pkey = "/var/lib/acme/turn.${domain}/key.pem";
      # Don't relay to internal networks:
      # https://www.enablesecurity.com/blog/slack-webrtc-turn-compromise-and-bug-bounty/
      extraConfig = ''
        ${concatMapStringsSep "\n" (cidr: let
          r = ip.cidrRange cidr;
        in "denied-peer-ip=${r.start}-${r.end}")
        ip.specialPurpose}
        no-multicast-peers
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
