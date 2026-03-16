#!/usr/bin/env bash

set -eE -o pipefail

: "${database:?database environment variable must be set}"

usage() {
  echo "Usage: $0 [-e|-d] [-s|-g] username" >&2
  exit 1
}

is_enabled="true"
use_pwgen=
mkpasswd_opts=()

while getopts ":edsg" arg; do
  case "$arg" in
    e)
      is_enabled="true"
      ;;
    d)
      is_enabled="false"
      ;;
    s)
      mkpasswd_opts+=("-s")
      ;;
    g)
      use_pwgen=1
      ;;
    *)
      usage
      ;;
  esac
done

shift $((OPTIND - 1))

user="$1" && shift && [ -n "$user" ] || usage
shift && usage || true

if [ -n "$use_pwgen" ]; then
  plaintext="$(pwgen -s 20 1)"
  passwd="$(mkpasswd -m bcrypt -- "$plaintext")"
  echo "$plaintext"
else
  passwd="$(mkpasswd -m bcrypt "${mkpasswd_opts[@]}")"
fi

psql "$database" \
  -v "user=$user" \
  -v "passwd=$passwd" \
  -v "is_enabled=$is_enabled" <<'EOSQL'
INSERT INTO users (name, password, enabled)
  VALUES (:'user', :'passwd', :is_enabled)
  ON CONFLICT (name) DO UPDATE SET password=EXCLUDED.password, enabled=EXCLUDED.enabled;
EOSQL
