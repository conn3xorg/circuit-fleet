#!/usr/bin/env sh
# Checks Fleet on the host up.sh started: setup is closed, a wrong enroll
# secret is refused, the host enrolled through osquery is listed and online,
# and it answers a live query. Example values only.
set -eu
cd "$(dirname "$0")"
ssh -p "${PORT:-2305}" -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 sh -eu <<'REMOTE'
u=https://localhost:8080
ca="--cacert /etc/fleet/fleet.crt"
systemctl is-active fleet osqueryd
# stdin is this script, so the two binaries below mustn't read it.
/opt/fleet/fleet_v4.94.0_linux/fleet version </dev/null | grep -qx 'fleet version 4.94.0'

code=$(curl -s $ca -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' $u/api/osquery/enroll \
  -d '{"enroll_secret": "wrong", "host_identifier": "nope"}')
[ "$code" = 401 ] || { echo "A wrong enroll secret got $code"; exit 1; }

code=$(curl -s $ca -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' $u/api/v1/setup \
  -d '{"admin": {"name": "x", "email": "x@example.com", "password": "another-Passw0rd!"}, "org_info": {"org_name": "x"}}')
case $code in 2*) echo "Setup was still open: $code"; exit 1;; esac

tok=$(curl -sSf $ca -H 'Content-Type: application/json' $u/api/v1/fleet/login \
  -d '{"email": "admin@example.com", "password": "example-Passw0rd!"}' | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
[ -n "$tok" ]
api() { curl -sSf $ca -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' "$@"; }

api $u/api/v1/fleet/config | grep -q '"tier": *"free"'

for i in $(seq 90); do
  hosts=$(api $u/api/v1/fleet/hosts)
  printf '%s' "$hosts" | grep -q '"status": *"online"' && break
  [ "$i" != 90 ] || { echo "No online host: $hosts"; exit 1; }
  sleep 2
done
id=$(printf '%s' "$hosts" | grep -o '"id": *[0-9]*' | head -n 1 | grep -o '[0-9]*$')
[ -n "$id" ]
echo "Host $id is listed and online: $(printf '%s' "$hosts" | grep -o '"hostname": *"[^"]*"' | head -n 1)"

want=$(osqueryi --version </dev/null | awk '{print $NF}')
for i in $(seq 30); do
  res=$(api -X POST $u/api/v1/fleet/hosts/"$id"/query -d '{"query": "SELECT version FROM osquery_info;"}' || true)
  printf '%s' "$res" | grep -q "\"version\": *\"$want\"" && { echo "Live query answered: $want"; echo "All checks passed."; exit 0; }
  sleep 2
done
echo "No live query answer: $res"
exit 1
REMOTE
