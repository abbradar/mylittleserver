#!/usr/bin/env bash

set -eE -o pipefail

: "${database:?database environment variable must be set}"

usage() {
  echo "Usage: $0 [-e|-d] [-s] username" >&2
  exit 1
}

is_enabled="true"
mkpasswd_opts=()

while getopts ":eds" arg; do
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
    *)
      usage
      ;;
  esac
done

shift $((OPTIND - 1))

user="$1" && shift && [ -n "$user" ] || usage
shift && usage || true

passwd="$(mkpasswd -m bcrypt "${mkpasswd_opts[@]}")"

psql "$database" \
  -v "user=$user" \
  -v "passwd=$passwd" \
  -v "is_enabled=$is_enabled" <<'EOSQL'
INSERT INTO users (name, password, enabled)
  VALUES (:'user', :'passwd', :is_enabled)
  ON CONFLICT (name) DO UPDATE SET password=EXCLUDED.password, enabled=EXCLUDED.enabled;
EOSQL
