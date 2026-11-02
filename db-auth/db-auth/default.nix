{
  buildPythonPackage,
  setuptools,
  lib,
  aiohttp,
  aiohttp-remotes,
  asyncpg,
  limits,
  libpass,
  bcrypt,
  matrix-synapse-unwrapped,
  withService ? true,
  withMatrix ? true,
}:
buildPythonPackage {
  pname = "db-auth";
  version = "1.0";
  pyproject = true;

  src = ./.;

  build-system = [setuptools];
  dependencies =
    [
      libpass
      bcrypt
    ]
    ++ lib.optionals withService [
      aiohttp
      (aiohttp-remotes.overridePythonAttrs (old: {
        # Its BasicAuth middleware is deprecated in aiohttp; we only use X-Forwarded-For.
        disabledTests = (old.disabledTests or []) ++ ["test_basic_auth_ok" "test_basic_auth_wrong_creds"];
      }))
      asyncpg
      limits
    ]
    ++ lib.optionals withMatrix [
      matrix-synapse-unwrapped
    ];
}
