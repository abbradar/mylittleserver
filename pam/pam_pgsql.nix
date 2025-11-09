{
  lib,
  stdenv,
  fetchFromGitHub,
  autoreconfHook,
  pkg-config,
  libpq,
  libgcrypt,
  pam,
  libxcrypt,
}:
stdenv.mkDerivation {
  pname = "pam_pgsql";
  version = "unstable-2025-06-24";

  src = fetchFromGitHub {
    owner = "pam-pgsql";
    repo = "pam-pgsql";
    rev = "7834ce21c4f633e3eadc9abe86fa02991efc43ed";
    sha256 = "sha256-hBkDEYZ8RBHav3tqDOD2uQ9m3U95wi4U9ebyQPqd5bo=";
  };

  nativeBuildInputs = [
    autoreconfHook
    pkg-config
    libpq.pg_config
  ];
  buildInputs = [
    libgcrypt
    pam
    libpq
    libxcrypt
  ];

  meta = with lib; {
    description = "Support to authenticate against PostgreSQL for PAM-enabled appliations";
    homepage = "https://github.com/pam-pgsql/pam-pgsql";
    license = licenses.gpl2Plus;
    platforms = platforms.linux;
    maintainers = [];
  };
}
