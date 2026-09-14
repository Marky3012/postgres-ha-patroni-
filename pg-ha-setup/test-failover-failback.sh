#!/usr/bin/env bash
# Run AFTER deploy.sh succeeds, from the same control machine.
# Exercises failover (kill leader) and failback (bring it back) and
# prints patronictl state at each stage so you can verify pass/fail.
set -euo pipefail

read -rp "SSH user: " SSH_USER
read -rp "Path to SSH key [~/.ssh/id_rsa]: " SSH_KEY; SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
read -rp "Node1 IP (current leader): " NODE1_IP
read -rp "Node2 IP (any replica, used to query cluster state): " NODE2_IP
read -rp "VIP or client connect host (blank to skip write test): " CONN_HOST
if [[ -n "$CONN_HOST" ]]; then
  if ! command -v psql >/dev/null 2>&1; then
    echo "[!] psql not found on this control machine - write test will be skipped."
    echo "    Install it here (e.g. 'sudo apt install postgresql-client') to enable it, or"
    echo "    run the psql commands manually against \$CONN_HOST from a machine that has it."
    CONN_HOST=""
  else
    read -rp "Postgres superuser password: " PGPW; echo
  fi
fi

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)
remote() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "$@"; }

status_pretty() { remote "$NODE2_IP" "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list"; }
status_json()   { remote "$NODE2_IP" "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list -f json"; }

write_test() {
  [[ -z "$CONN_HOST" ]] && return 0
  PGPASSWORD="$PGPW" psql "host=$CONN_HOST port=5432 dbname=postgres user=postgres" \
    -c "CREATE TABLE IF NOT EXISTS ha_test(t timestamptz); INSERT INTO ha_test VALUES (now());" \
    -c "SELECT count(*) FROM ha_test;" 2>&1 || echo "  [write test failed - expected during the ~10-30s failover window]"
}

# Exact-match on the JSON Host field - avoids the substring trap of grepping
# an IP against table text (e.g. 10.0.0.1 matching inside 10.0.0.11).
leader_host_now() {
  status_json | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in data:
    if m.get('Role') == 'Leader':
        print(m.get('Host', '')); break
"
}
role_state_of() {  # role_state_of <ip>
  local ip="$1"
  status_json | python3 -c "
import json, sys
ip = '$ip'
try:
    data = json.load(sys.stdin)
except Exception:
    print('UNKNOWN UNKNOWN'); sys.exit(0)
for m in data:
    if m.get('Host') == ip:
        print(m.get('Role', '?'), m.get('State', '?')); sys.exit(0)
print('MISSING MISSING')
"
}

echo "=== BEFORE ==="
status_pretty
write_test

echo
echo "=== FAILOVER: stopping patroni on leader ($NODE1_IP) ==="
remote "$NODE1_IP" "sudo systemctl stop patroni"
echo "Polling until a DIFFERENT node becomes Leader (max 60s)..."
waited=0
until [[ "$(leader_host_now)" != "" && "$(leader_host_now)" != "$NODE1_IP" ]]; do
  sleep 5; waited=$((waited+5))
  echo "--- ${waited}s --- current leader host: $(leader_host_now || echo '<none>')"
  if (( waited >= 60 )); then echo "[!] No new leader within 60s"; break; fi
done
[[ "$(leader_host_now)" != "$NODE1_IP" && "$(leader_host_now)" != "" ]] && echo "[+] New leader elected: $(leader_host_now)"
status_pretty
write_test

echo
echo "=== FAILBACK: restarting patroni on old leader ($NODE1_IP) ==="
remote "$NODE1_IP" "sudo systemctl start patroni"
echo "Polling until it rejoins as a running Replica (max 60s)..."
waited=0
until [[ "$(role_state_of "$NODE1_IP")" == "Replica running" ]]; do
  sleep 5; waited=$((waited+5))
  echo "--- ${waited}s --- node1: $(role_state_of "$NODE1_IP")"
  if (( waited >= 60 )); then echo "[!] Old leader did not rejoin as running replica within 60s"; break; fi
done
[[ "$(role_state_of "$NODE1_IP")" == "Replica running" ]] && echo "[+] Old leader rejoined as replica"
write_test

echo
echo "=== FINAL STATE ==="
status_pretty
