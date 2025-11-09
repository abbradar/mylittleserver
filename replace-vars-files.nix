{
  lib,
  stdenvNoCC,
}: path: attrs: let
  subst-var-by = name: value:
    lib.optionals (value != null) [
      "--subst-var-by"
      (lib.escapeShellArg "@${name}@")
      (lib.escapeShellArg value)
    ];

  replacements = lib.concatLists (lib.mapAttrsToList subst-var-by attrs);

  left-overs = map ({name, ...}: name) (
    builtins.filter ({value, ...}: value == null) (lib.attrsToList attrs)
  );
in
  stdenvNoCC.mkDerivation {
    name = baseNameOf (toString path);
    src = path;
    doCheck = true;
    dontUnpack = true;
    preferLocalBuild = true;
    allowSubstitutes = false;

    buildPhase = ''
      runHook preBuild
      cd "$src"
      while read -r -d "" line; do
        dir=$(dirname "$line")
        mkdir -p "$out/$dir"
        substitute "$src/$line" "$out/$line" --subst-var out ${lib.concatStringsSep " " replacements}
      done < <(find -type f -print0)
      runHook postBuild
    '';

    # Look for Nix identifiers surrounded by `@` that aren't substituted.
    checkPhase = let
      lookahead =
        if builtins.length left-overs == 0
        then ""
        else "(?!${builtins.concatStringsSep "|" left-overs}@)";
      regex = lib.escapeShellArg "@${lookahead}[a-zA-Z_][0-9A-Za-z_'-]*@";
    in ''
      runHook preCheck
      if grep -Pqer ${regex} "$out"; then
        echo The following look like unsubstituted Nix identifiers that remain in "$out":
        grep -Poer ${regex} "$out"
        echo Use the more precise '`substitute`' function if this check is in error.
        exit 1
      fi
      runHook postCheck
    '';
  }
