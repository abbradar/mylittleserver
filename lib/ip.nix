{lib}:
with lib; let
  pow2 = n: foldl' (acc: _: acc * 2) 1 (range 1 n);
  lowBits = n: pow2 n - 1;

  # Splits a group of `width` bits into the first and last value of its network part.
  bounds = width: hostBits: value: let
    host = lowBits hostBits;
    start = bitAnd value (bitXor (lowBits width) host);
  in {
    inherit start;
    end = bitOr start host;
  };

  ipv4Range = cidr: let
    parts = splitString "/" cidr;
    octets = map toInt (splitString "." (elemAt parts 0));
    value = foldl' (acc: octet: acc * 256 + octet) 0 octets;
    b = bounds 32 (32 - toInt (elemAt parts 1)) value;
    format = v: concatMapStringsSep "." (i: toString (mod (v / pow2 (8 * (3 - i))) 256)) (range 0 3);
  in {
    start = format b.start;
    end = format b.end;
  };

  ipv6Range = cidr: let
    parsed = network.ipv6.fromString cidr;
    groups = imap0 (i: group:
      bounds 16 (min 16 (max 0 ((i + 1) * 16 - parsed.prefixLength))) (fromHexString group))
    (splitString ":" parsed.address);
    format = sel: concatMapStringsSep ":" (g: toLower (toHexString (sel g))) groups;
  in {
    start = format (g: g.start);
    end = format (g: g.end);
  };
in {
  # First and last address of a CIDR network.
  cidrRange = cidr:
    if hasInfix ":" cidr
    then ipv6Range cidr
    else ipv4Range cidr;

  specialPurpose = importJSON ./special-purpose-ips.json;
}
