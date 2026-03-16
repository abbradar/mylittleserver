{
  buildPythonPackage,
  setuptools,
  aiohttp,
  asyncpg,
  libpass,
  bcrypt,
  matrix-synapse-unwrapped,
}:
buildPythonPackage {
  pname = "db-auth";
  version = "1.0";
  pyproject = true;

  src = ./.;

  build-system = [setuptools];
  dependencies = [
    aiohttp
    asyncpg
    libpass
    bcrypt
    matrix-synapse-unwrapped
  ];
}
