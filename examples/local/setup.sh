#!/usr/bin/env sh
# Finishes Fleet's setup through its API, on the host up.sh started: creates
# the admin, then sets the enroll secret osquery uses. Example values only.
set -eu
cd "$(dirname "$0")"
ssh -p "${PORT:-2305}" -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 sh -eu <<'REMOTE'
u=https://localhost:8080
ca="--cacert /etc/fleet/fleet.crt"
curl -sSf $ca -H 'Content-Type: application/json' $u/api/v1/setup -d '{
  "admin": {"name": "Admin", "email": "admin@example.com", "password": "example-Passw0rd!"},
  "org_info": {"org_name": "Example"},
  "server_url": "https://localhost:8080"
}' >/dev/null
tok=$(curl -sSf $ca -H 'Content-Type: application/json' $u/api/v1/fleet/login \
  -d '{"email": "admin@example.com", "password": "example-Passw0rd!"}' | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
[ -n "$tok" ]
curl -sSf $ca -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' $u/api/v1/fleet/spec/enroll_secret \
  -d '{"spec": {"secrets": [{"secret": "example-enroll-secret"}]}}' >/dev/null
echo "Setup done. Now run: conn3x apply -var enroll=true"
REMOTE
