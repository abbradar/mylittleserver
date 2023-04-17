{ poetry2nix, aiohttp, asyncpg }:

poetry2nix.mkPoetryApplication {
  projectDir = ./.;
  overrides = poetry2nix.defaultPoetryOverrides.extend (final: prev: {
    inherit aiohttp asyncpg;
  });
}
