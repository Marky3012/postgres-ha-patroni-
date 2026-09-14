#!/usr/bin/env bash
# ============================================================================
# PostgreSQL 17 HA Cluster Orchestrator
# 4x PG data nodes (Patroni-managed) + 1x watcher node (etcd quorum)
# Optional: HAProxy + keepalived installed ON the 4 PG nodes (floating VIP)
# Ubuntu 24.04
#
# Run this FROM your control machine (workstation or a jump host).
# It SSHes into all 5 target nodes and does the full install/bootstrap.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

# ---------------------------------------------------------------------------
# 1. Collect input
# ---------------------------------------------------------------------------
echo "=== PostgreSQL HA Cluster Setup ==="
read -rp "SSH user (same across all nodes): " SSH_USER
read -rp "Path to SSH private key [~/.ssh/id_rsa]: " SSH_KEY
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"

read -rp "Node1 IP (initial LEADER, holds data): " NODE1_IP
read -rp "Node2 IP (replica): " NODE2_IP
read -rp "Node3 IP (replica): " NODE3_IP
read -rp "Node4 IP (replica): " NODE4_IP
read -rp "Watcher IP (etcd quorum member only, no PG): " WATCHER_IP
_ALL_HOSTS_EARLY=("$NODE1_IP" "$NODE2_IP" "$NODE3_IP" "$NODE4_IP" "$WATCHER_IP")

# No key on disk -> generate one and install it on all 5 nodes now (password
# auth, once per host, via plain ssh - no ssh-copy-id dependency). Every
# later step in this run, and every future run, then needs zero passwords.
if [[ ! -f "$SSH_KEY" ]]; then
  echo
  read -rp "No key at $SSH_KEY. Generate one and install on all 5 nodes now? [Y/n]: " GEN_KEY
  if [[ "${GEN_KEY,,}" != "n" ]]; then
    mkdir -p "$(dirname "$SSH_KEY")" && chmod 700 "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "pg-ha-deploy-$(date +%Y%m%d)" >/dev/null
    log "Generated $SSH_KEY (no passphrase - automation key, keep this control host secured)."
    log "Installing public key on all 5 nodes - password prompt once per host:"
    PUBKEY="$(cat "${SSH_KEY}.pub")"
    for ip in "${_ALL_HOSTS_EARLY[@]}"; do
      echo "  -> $ip"
      ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${ip}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$PUBKEY' ~/.ssh/authorized_keys 2>/dev/null || echo '$PUBKEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
        || { err "Could not install key on $ip - check password/connectivity, then re-run."; exit 1; }
    done
    log "Key installed everywhere. This and future runs are now passwordless."
  else
    warn "Continuing without a dedicated key - relying on password/agent/other auth (expect repeated prompts)."
  fi
fi
SSH_KEY_OPT=()
[[ -f "$SSH_KEY" ]] && SSH_KEY_OPT=(-i "$SSH_KEY")

read -rp "Patroni cluster scope name [pgcluster]: " SCOPE
SCOPE="${SCOPE:-pgcluster}"

DEFAULT_CIDR="$(echo "$NODE1_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')"
read -rp "CIDR allowed to connect to Postgres (replication + clients) [${DEFAULT_CIDR}]: " CLIENT_CIDR
CLIENT_CIDR="${CLIENT_CIDR:-$DEFAULT_CIDR}"

read -rsp "PostgreSQL superuser password: " PG_SUPERUSER_PW; echo
read -rsp "Replication user password: " PG_REPL_PW; echo
read -rsp "Patroni REST API basic-auth password [patroni]: " PATRONI_API_PW; echo
PATRONI_API_PW="${PATRONI_API_PW:-patroni}"

echo
read -rp "Enable HAProxy + keepalived on the 4 PG nodes (floating VIP)? [y/N]: " ENABLE_HAPROXY_ANS
ENABLE_HAPROXY="false"
VIP="" IFACE="" KA_AUTH_PASS=""
if [[ "${ENABLE_HAPROXY_ANS,,}" == "y" ]]; then
  ENABLE_HAPROXY="true"
  read -rp "Virtual IP (VIP) to float across PG nodes, same subnet, unused: " VIP
  while ! [[ "$VIP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; do
    echo "Invalid IPv4 format."; read -rp "Virtual IP (VIP): " VIP
  done
  if [[ "${VIP%.*}" != "${NODE1_IP%.*}" ]]; then
    warn "VIP ($VIP) is not in the same /24 as node1 ($NODE1_IP). Verify subnet/routing before relying on it."
  fi
  read -rp "Network interface name on the PG nodes [eth0]: " IFACE
  IFACE="${IFACE:-eth0}"
  # NOTE: `tr ... | head -c 8` looks harmless but isn't under `set -o pipefail`:
  # head closes the pipe once it has 8 bytes, tr gets SIGPIPE writing into a
  # closed pipe, and pipefail reports that as a pipeline failure - silently
  # killing the whole script right here under `set -e`, output be damned.
  # /dev/urandom | head -c 8 without a paired process to receive SIGPIPE
  # gracefully has the same issue. Use tr's own base64 output truncated with
  # a plain shell substring instead - no pipe-closure race.
  KA_AUTH_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8; true)"
  log "keepalived VRRP auth pass (auto-generated): $KA_AUTH_PASS"
else
  warn "HAProxy/keepalived skipped. Client apps must use libpq multi-host:"
  warn '  host=n1,n2,n3,n4 target_session_attrs=read-write'
fi

CM_DIR="$HOME/.ssh/cm"
mkdir -p "$CM_DIR" && chmod 700 "$CM_DIR"
# Connection multiplexing: first ssh/scp to a host opens (and authenticates)
# the connection once; every later call to the same host reuses that same
# socket instead of prompting again. With password auth this cuts you from
# ~4-5 prompts per host down to 1. Sockets auto-close 15min after last use.
SSH_OPTS=("${SSH_KEY_OPT[@]}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
  -o ControlMaster=auto -o ControlPersist=15m -o "ControlPath=$CM_DIR/%r@%h:%p")
ALL_HOSTS=("$NODE1_IP" "$NODE2_IP" "$NODE3_IP" "$NODE4_IP" "$WATCHER_IP")
PG_HOSTS=("$NODE1_IP" "$NODE2_IP" "$NODE3_IP" "$NODE4_IP")

remote() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "$@"; }
push()   { scp -q "${SSH_OPTS[@]}" -r "$2" "${SSH_USER}@${1}:$3"; }

# ---------------------------------------------------------------------------
# 2. Connectivity check
# ---------------------------------------------------------------------------
log "Testing SSH connectivity to all 5 nodes..."
for ip in "${ALL_HOSTS[@]}"; do
  if remote "$ip" "echo ok" >/dev/null 2>&1; then
    echo "    $ip: OK"
  else
    err "Cannot SSH to $ip as $SSH_USER. Fix access first."; exit 1
  fi
done

log "Checking passwordless sudo on all nodes..."
for ip in "${ALL_HOSTS[@]}"; do
  if remote "$ip" "sudo -n true" >/dev/null 2>&1; then
    echo "    $ip: sudo OK"
  else
    err "$ip: sudo requires a password (or $SSH_USER lacks sudo)."
    err "  Fix: on $ip, add '$SSH_USER ALL=(ALL) NOPASSWD:ALL' via visudo, then re-run."
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Poll helpers - replace fixed sleeps with retry-until-ready
# ---------------------------------------------------------------------------
wait_etcd_healthy() {
  local max=90 waited=0
  until remote "$WATCHER_IP" "etcdctl --endpoints=http://${WATCHER_IP}:2379 endpoint health" >/dev/null 2>&1; do
    sleep 5; waited=$((waited+5))
    (( waited >= max )) && { err "etcd not healthy after ${max}s"; return 1; }
  done
  log "etcd healthy (waited ${waited}s)"
}
wait_patroni_primary() {   # wait_patroni_primary <ip> - REST API binds to the node's own IP, not loopback
  local ip="$1" max=180 waited=0
  until remote "$ip" "curl -fs http://${ip}:8008/primary" >/dev/null 2>&1; do
    sleep 5; waited=$((waited+5))
    if (( waited >= max )); then
      err "Patroni on $ip never became primary within ${max}s - journal:"
      remote "$ip" "sudo journalctl -u patroni -n 40 --no-pager" | sed 's/^/      /'
      return 1
    fi
  done
  log "Patroni primary ready on $ip (waited ${waited}s)"
}
wait_patroni_healthy() {   # wait_patroni_healthy <ip>
  local ip="$1" max=180 waited=0
  until remote "$ip" "curl -fs http://${ip}:8008/health" >/dev/null 2>&1; do
    sleep 5; waited=$((waited+5))
    if (( waited >= max )); then
      warn "Patroni on $ip not confirmed healthy within ${max}s - journal (last 40 lines):"
      remote "$ip" "sudo journalctl -u patroni -n 40 --no-pager" | sed 's/^/      /'
      warn "If the journal shows a stalled/refused connection to the leader on port 5432,"
      warn "that port isn't reachable between subnets the way 2379/2380 are - check firewall/routing."
      return 1
    fi
  done
  log "Patroni healthy on $ip (waited ${waited}s)"
}

# ---------------------------------------------------------------------------
# 2b. Offline package cache: auto-push if present next to this script
# ---------------------------------------------------------------------------
OFFLINE_LOCAL=""
if [[ -d "$SCRIPT_DIR/pg-ha-offline-pkgs" ]]; then
  OFFLINE_LOCAL="$SCRIPT_DIR/pg-ha-offline-pkgs"
elif [[ -f "$SCRIPT_DIR/pg-ha-offline-pkgs.tar.gz" ]]; then
  mkdir -p "$WORKDIR/offline"
  tar xzf "$SCRIPT_DIR/pg-ha-offline-pkgs.tar.gz" -C "$WORKDIR/offline"
  OFFLINE_LOCAL="$WORKDIR/offline/pg-ha-offline-pkgs"
fi
if [[ -n "$OFFLINE_LOCAL" ]]; then
  log "Offline package cache found ($OFFLINE_LOCAL) - pushing to all nodes as fallback..."
  for ip in "${ALL_HOSTS[@]}"; do
    remote "$ip" "sudo mkdir -p /opt/pg-ha-offline-pkgs && sudo chown \$(whoami) /opt/pg-ha-offline-pkgs"
    push "$ip" "$OFFLINE_LOCAL/." "/opt/pg-ha-offline-pkgs/"
  done
else
  log "No local offline package cache found (pg-ha-offline-pkgs/ or .tar.gz) - install will rely on internet access."
  log "If a node has no internet, run download-offline-packages.sh first and re-run this script."
fi

# Build etcd static cluster string: node=https://ip:2380
ETCD_CLUSTER=""
i=0
for ip in "${ALL_HOSTS[@]}"; do
  i=$((i+1))
  ETCD_CLUSTER+="etcd${i}=http://${ip}:2380,"
done
ETCD_CLUSTER="${ETCD_CLUSTER%,}"

# ---------------------------------------------------------------------------
# 3. Per-node install (packages) - runs on all 5
# ---------------------------------------------------------------------------
log "Installing base packages on all nodes (in parallel)..."
for ip in "${ALL_HOSTS[@]}"; do
  push "$ip" "$SCRIPT_DIR/remote-install.sh" "/tmp/remote-install.sh"
done

mkdir -p "$WORKDIR/logs"
declare -A INSTALL_PID
for ip in "${ALL_HOSTS[@]}"; do
  is_pg="false"; [[ " ${PG_HOSTS[*]} " == *" $ip "* ]] && is_pg="true"
  log "  -> $ip (pg_node=$is_pg haproxy=$ENABLE_HAPROXY) [background]"
  remote "$ip" "sudo bash /tmp/remote-install.sh $is_pg $ENABLE_HAPROXY" \
    > "$WORKDIR/logs/install_${ip}.log" 2>&1 &
  INSTALL_PID["$ip"]=$!
done

log "Waiting for all 5 installs to finish (this is the slow step - tailing as they land)..."
INSTALL_FAILED="false"
for ip in "${ALL_HOSTS[@]}"; do
  if wait "${INSTALL_PID[$ip]}"; then
    echo "    $ip: OK"
  else
    err "$ip: install FAILED - last 15 lines of $WORKDIR/logs/install_${ip}.log:"
    tail -n 15 "$WORKDIR/logs/install_${ip}.log" | sed 's/^/      /'
    INSTALL_FAILED="true"
  fi
done
[[ "$INSTALL_FAILED" == "true" ]] && {
  PERSIST_LOGS="$SCRIPT_DIR/install-logs-$(date +%Y%m%d-%H%M%S)"
  cp -r "$WORKDIR/logs" "$PERSIST_LOGS"
  err "One or more nodes failed to install - fix and re-run before continuing."
  err "Full logs saved to: $PERSIST_LOGS"
  exit 1
}

# ---------------------------------------------------------------------------
# 4. etcd config + start on all 5
# ---------------------------------------------------------------------------
ETCD_ALREADY_BOOTSTRAPPED="false"
if remote "$WATCHER_IP" "test -d /var/lib/etcd/member" >/dev/null 2>&1; then
  ETCD_ALREADY_BOOTSTRAPPED="true"
  warn "etcd data dir already exists on watcher - assuming cluster was already bootstrapped."
  warn "Skipping etcd config re-deploy/restart (mixing new/existing cluster-state across members breaks etcd)."
  warn "To fully re-bootstrap from scratch: stop etcd and 'rm -rf /var/lib/etcd' on ALL 5 nodes first, then re-run."
fi

if [[ "$ETCD_ALREADY_BOOTSTRAPPED" == "false" ]]; then
  log "Deploying etcd config to all 5 nodes..."
  i=0
  for ip in "${ALL_HOSTS[@]}"; do
    i=$((i+1))
    sed \
      -e "s/{{NAME}}/etcd${i}/g" \
      -e "s/{{IP}}/${ip}/g" \
      -e "s#{{CLUSTER}}#${ETCD_CLUSTER}#g" \
      "$SCRIPT_DIR/templates/etcd.conf.tpl" > "$WORKDIR/etcd_${ip}.conf"
    push "$ip" "$WORKDIR/etcd_${ip}.conf" "/tmp/etcd.conf"
    remote "$ip" "sudo mv /tmp/etcd.conf /etc/default/etcd && sudo systemctl enable etcd"
  done

  # Start all 5 CONCURRENTLY, not one at a time: etcd's initial bootstrap
  # blocks "systemctl restart" until it reaches quorum with its peers, so
  # starting sequentially deadlocks - node1 waits for node2..5 while the
  # script is still stuck waiting for node1's restart to return. This is
  # exactly the same reasoning as the parallel package install above.
  log "Starting etcd on all 5 nodes in parallel..."
  mkdir -p "$WORKDIR/logs"
  declare -A ETCD_PID
  for ip in "${ALL_HOSTS[@]}"; do
    remote "$ip" "sudo systemctl restart etcd" > "$WORKDIR/logs/etcd_${ip}.log" 2>&1 &
    ETCD_PID["$ip"]=$!
  done
  ETCD_START_FAILED="false"
  for ip in "${ALL_HOSTS[@]}"; do
    if wait "${ETCD_PID[$ip]}"; then
      echo "    $ip: etcd started"
    else
      err "$ip: etcd failed to start - journal:"
      remote "$ip" "sudo journalctl -xeu etcd -n 30 --no-pager" | sed 's/^/      /'
      ETCD_START_FAILED="true"
    fi
  done
  if [[ "$ETCD_START_FAILED" == "true" ]]; then
    err "One or more nodes failed to start etcd."
    err "Common cause: this node can't reach one or more of the other 4 on ports 2379/2380"
    err "(routing/firewall between subnets, cloud security group, etc)."
    exit 1
  fi
fi

log "Waiting for etcd quorum..."
wait_etcd_healthy || exit 1

# ---------------------------------------------------------------------------
# 5. Patroni config on 4 PG nodes (node1 bootstraps, 2-4 join)
# ---------------------------------------------------------------------------
ETCD_HOSTS_CSV=""
for ip in "${ALL_HOSTS[@]}"; do ETCD_HOSTS_CSV+="${ip}:2379,"; done
ETCD_HOSTS_CSV="${ETCD_HOSTS_CSV%,}"

log "Deploying Patroni config to 4 PG nodes..."
n=0
for ip in "${PG_HOSTS[@]}"; do
  n=$((n+1))
  sed \
    -e "s/{{SCOPE}}/${SCOPE}/g" \
    -e "s/{{NODENAME}}/pg${n}/g" \
    -e "s/{{IP}}/${ip}/g" \
    -e "s#{{ETCD_HOSTS}}#${ETCD_HOSTS_CSV}#g" \
    -e "s/{{SUPERUSER_PW}}/${PG_SUPERUSER_PW}/g" \
    -e "s#{{CLIENT_CIDR}}#${CLIENT_CIDR}#g" \
    -e "s/{{REPL_PW}}/${PG_REPL_PW}/g" \
    -e "s/{{API_PW}}/${PATRONI_API_PW}/g" \
    "$SCRIPT_DIR/templates/patroni.yml.tpl" > "$WORKDIR/patroni_${ip}.yml"
  push "$ip" "$WORKDIR/patroni_${ip}.yml" "/tmp/patroni.yml"
  remote "$ip" "sudo mkdir -p /etc/patroni && sudo mv /tmp/patroni.yml /etc/patroni/patroni.yml && sudo chown -R postgres:postgres /etc/patroni && sudo mkdir -p /var/lib/postgresql/17/main && [ \"\$(stat -c '%U' /var/lib/postgresql/17/main)\" = postgres ] || sudo chown -R postgres:postgres /var/lib/postgresql/17/main"
done

SKIP_PATRONI_RESTART="false"
if remote "$NODE1_IP" "systemctl is-active --quiet patroni" >/dev/null 2>&1; then
  warn "Patroni already active on node1 - cluster appears already bootstrapped."
  read -rp "Restart all 4 PG nodes anyway? This can trigger a live failover. [y/N]: " CONFIRM_RESTART
  if [[ "${CONFIRM_RESTART,,}" != "y" ]]; then
    log "Skipping Patroni restart. Updated config is staged at /etc/patroni/patroni.yml on each node -"
    log "apply later, one node at a time, with: sudo systemctl restart patroni"
    SKIP_PATRONI_RESTART="true"
  fi
fi

if [[ "$SKIP_PATRONI_RESTART" == "false" ]]; then
  # Self-heal: check the EXACT file Patroni's own code path dies on
  # (postgresql.conf), not PG_VERSION - a dir can have PG_VERSION (partially
  # initialized by a prior failed attempt) while still missing the actual
  # config, which is what causes "Lock owner: None" + "starting as a
  # secondary" + FileNotFoundError on postgresql.conf. Confirm before wiping
  # anything, since a real cluster's data dir must never be touched blind.
  #
  # Check ALL 4 PG nodes up front, not just node1: a replica can just as
  # easily be carrying real leftover PG data (own system ID) from an earlier
  # interrupted attempt, which fails as "system ID mismatch" the moment it
  # tries to join the freshly-bootstrapped leader. One combined prompt here
  # avoids hitting this same wall one node at a time.
  STALE_NODES=()
  for ip in "${PG_HOSTS[@]}"; do
    remote "$ip" "test -f /var/lib/postgresql/17/main/postgresql.conf" >/dev/null 2>&1 || STALE_NODES+=("$ip")
  done
  if [[ ${#STALE_NODES[@]} -gt 0 ]]; then
    warn "These nodes have incomplete/mismatched local PG data (likely from earlier interrupted attempts): ${STALE_NODES[*]}"
    read -rp "Wipe local data dir on ALL 4 PG nodes + this scope's etcd state, for one fully clean bootstrap? [y/N]: " CONFIRM_WIPE
    if [[ "${CONFIRM_WIPE,,}" == "y" ]]; then
      for ip in "${PG_HOSTS[@]}"; do
        remote "$ip" "sudo systemctl stop patroni 2>/dev/null; sudo rm -rf /var/lib/postgresql/17/main && sudo mkdir -p /var/lib/postgresql/17/main && sudo chown postgres:postgres /var/lib/postgresql/17/main && sudo chmod 700 /var/lib/postgresql/17/main"
      done
      remote "$WATCHER_IP" "etcdctl --endpoints=http://${WATCHER_IP}:2379 del /db/${SCOPE} --prefix" >/dev/null
      log "All 4 PG data dirs and etcd scope state cleared - Patroni will initdb fresh on the leader, replicas will clone clean."
    else
      warn "Continuing without wiping - the same crash will very likely repeat on: ${STALE_NODES[*]}"
    fi
  fi

  log "Starting Patroni on LEADER (node1: $NODE1_IP) first..."
  remote "$NODE1_IP" "sudo systemctl enable patroni && sudo systemctl restart patroni"
  wait_patroni_primary "$NODE1_IP" || exit 1

  log "Starting Patroni on replicas (node2-4)..."
  for ip in "$NODE2_IP" "$NODE3_IP" "$NODE4_IP"; do
    remote "$ip" "sudo systemctl enable patroni && sudo systemctl restart patroni"
    wait_patroni_healthy "$ip"
  done
fi

# ---------------------------------------------------------------------------
# 6. Optional: HAProxy + keepalived on all 4 PG nodes
# ---------------------------------------------------------------------------
if [[ "$ENABLE_HAPROXY" == "true" ]]; then
  log "Deploying HAProxy (local, per PG node) - each checks all 4 nodes' /primary..."
  {
    n=0
    for ip in "${PG_HOSTS[@]}"; do
      n=$((n+1))
      echo "    server pg${n} ${ip}:5432 maxconn 100 check port 8008"
    done
  } > "$WORKDIR/haproxy_servers.txt"

  python3 - "$SCRIPT_DIR/templates/haproxy.cfg.tpl" "$WORKDIR/haproxy_servers.txt" "$WORKDIR/haproxy.cfg" <<'PYEOF'
import sys
tpl, servers, out = sys.argv[1:4]
with open(tpl) as f: content = f.read()
with open(servers) as f: srv = f.read()
content = content.replace("{{SERVERS}}", srv)
with open(out, "w") as f: f.write(content)
PYEOF

  for ip in "${PG_HOSTS[@]}"; do
    push "$ip" "$WORKDIR/haproxy.cfg" "/tmp/haproxy.cfg"
    push "$ip" "$SCRIPT_DIR/templates/check-haproxy-backend.sh" "/tmp/check-haproxy-backend.sh"
    remote "$ip" "sudo mv /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg && sudo mv /tmp/check-haproxy-backend.sh /usr/local/bin/check-haproxy-backend.sh && sudo chmod +x /usr/local/bin/check-haproxy-backend.sh && sudo systemctl restart haproxy"
  done

  log "Deploying keepalived (VIP $VIP on $IFACE, unicast between 4 PG nodes)..."
  n=0
  for ip in "${PG_HOSTS[@]}"; do
    n=$((n+1))
    STATE="BACKUP"; [[ $n -eq 1 ]] && STATE="MASTER"
    PRIORITY=$((140 - n*20))   # node1=100, node2=80, node3=60, node4=40 - gap must exceed |weight| in keepalived.conf.tpl (30)
    PEERS=""
    for peer_ip in "${PG_HOSTS[@]}"; do
      [[ "$peer_ip" == "$ip" ]] && continue
      PEERS+="        ${peer_ip}"$'\n'
    done
    sed \
      -e "s/{{STATE}}/${STATE}/g" \
      -e "s/{{IFACE}}/${IFACE}/g" \
      -e "s/{{PRIORITY}}/${PRIORITY}/g" \
      -e "s/{{AUTH_PASS}}/${KA_AUTH_PASS}/g" \
      -e "s/{{MY_IP}}/${ip}/g" \
      -e "s/{{VIP}}/${VIP}/g" \
      "$SCRIPT_DIR/templates/keepalived.conf.tpl" > "$WORKDIR/keepalived_${ip}.conf"
    # inject multi-line PEERS block (sed-unfriendly with newlines, use python)
    python3 - "$WORKDIR/keepalived_${ip}.conf" "$PEERS" <<'PYEOF'
import sys
path, peers = sys.argv[1], sys.argv[2]
with open(path) as f: content = f.read()
content = content.replace("{{PEERS}}", peers.rstrip("\n"))
with open(path, "w") as f: f.write(content)
PYEOF
    push "$ip" "$WORKDIR/keepalived_${ip}.conf" "/tmp/keepalived.conf"
    remote "$ip" "sudo mv /tmp/keepalived.conf /etc/keepalived/keepalived.conf && sudo systemctl restart keepalived"
  done
fi

# ---------------------------------------------------------------------------
# 7. Validate
# ---------------------------------------------------------------------------
log "Cluster status:"
STATUS_OK="false"
for ip in "${PG_HOSTS[@]}"; do
  if remote "$ip" "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list"; then
    STATUS_OK="true"; break
  else
    warn "Could not query patronictl via $ip, trying next node..."
  fi
done
[[ "$STATUS_OK" == "false" ]] && warn "Could not fetch patronictl status from any PG node - check manually"

echo
echo "=== DONE ==="
if [[ "$ENABLE_HAPROXY" == "true" ]]; then
  cat <<EOF
Client connection point (VIP, auto-follows current leader via HAProxy+keepalived): ${VIP}:5000
  psql "host=${VIP} port=5000 dbname=postgres user=postgres password=****"
Per-node HAProxy stats: http://<pg-node-ip>:7000/
keepalived VRRP auth pass: ${KA_AUTH_PASS}  (save this)
EOF
else
  cat <<EOF
No HAProxy/keepalived deployed. Connect using libpq multi-host failover:
  psql "host=${NODE1_IP},${NODE2_IP},${NODE3_IP},${NODE4_IP} port=5432 target_session_attrs=read-write dbname=postgres user=postgres"
EOF
fi

cat <<EOF

Patroni REST API (per node): http://<node-ip>:8008/  (GET /primary, /replica)

Test failover:
  ssh ${SSH_USER}@${NODE1_IP} 'sudo systemctl stop patroni'
  ssh ${SSH_USER}@${NODE2_IP} "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list"

Test failback (bring old leader back):
  ssh ${SSH_USER}@${NODE1_IP} 'sudo systemctl start patroni'
  # patroni + pg_rewind auto-rejoins it as replica
EOF
