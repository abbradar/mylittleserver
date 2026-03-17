{
  buildPythonPackage,
  setuptools,
  lib,
  aiohttp,
  asyncpg,
  psycopg2,
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
      asyncpg
    ]
    ++ lib.optionals withMatrix [
      psycopg2
      matrix-synapse-unwrapped
    ];
}
