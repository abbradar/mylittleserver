{
  lib,
  stdenvNoCC,
  fetchurl,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "converse.js";
  version = "14.0.1";

  src = fetchurl {
    url = "https://registry.npmjs.org/converse.js/-/converse.js-${finalAttrs.version}.tgz";
    hash = "sha256-i5N/BcqKVIeeAohCk2pmAsMPsHZBrzcEaWiAVWhUfGk=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    cp -r dist $out
    runHook postInstall
  '';

  meta = {
    description = "Web-based XMPP chat client";
    homepage = "https://conversejs.org";
    license = lib.licenses.mpl20;
    platforms = lib.platforms.all;
  };
})
