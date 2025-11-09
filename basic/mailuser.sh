#!/usr/bin/env bash

set -e

usage() {
  echo "Usage: $0 [-e|-d] [-s] username" >&2
  exit 1
}

is_enabled="true"
mkpasswd_opts=""

while getopts ":eds" arg; do
  case "$arg" in
    e)
      is_enabled="true"
      ;;
    d)
      is_enabled="false"
      ;;
    s)
      mkpasswd_opts="$mkpasswd_opts -s"
      ;;
    *)
      usage
      ;;
  esac
done

shift $(($OPTIND - 1))

user="$1" && shift && [ -n "$user" ] || usage
shift && usage || true

passwd="$(mkpasswd -m bcrypt $mkpasswd_opts | sed 's/^{.*}//')"

psql "$database" -c """
UPDATE users SET password='$passwd', enabled=$is_enabled WHERE name='$user';
INSERT INTO users (name, password, enabled)
  SELECT '$user', '$passwd', $is_enabled
  WHERE NOT EXISTS (SELECT 1 FROM users WHERE name='$user');
"""
