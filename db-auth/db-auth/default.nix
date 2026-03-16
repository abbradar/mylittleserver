{
  buildPythonPackage,
  setuptools,
  aiohttp,
  asyncpg,
  libpass,
  bcrypt,
  matrix-synapse-unwrapped,
  ruff,
  pyright,
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

  nativeCheckInputs = [
    pyright
    ruff
  ];

  checkPhase = ''
    ruff check .
    ruff format --check .
    pyright
  '';
}
