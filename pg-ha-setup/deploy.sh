#!/usr/bin/env bash
# ============================================================================
# PostgreSQL 17 HA Cluster Orchestrator
# Flexible N PG data nodes (Patroni-managed) + M watcher node(s) (etcd
# quorum only, no PG) - M is only asked for when N is EVEN, and only as
# many as needed to make the DCS quorum ODD again.
# Optional: HAProxy + keepalived installed ON the PG nodes (floating VIP)
# Ubuntu 24.04
#
# Run this FROM your control machine (workstation or a jump host).
# It SSHes into every target node and does the full install/bootstrap.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# visuals & small helpers
# ---------------------------------------------------------------------------
log()   { echo -e "\033[1;32m[+]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[!]\033[0m $*"; }
err()   { echo -e "\033[1;31m[x]\033[0m $*" >&2; }
ok()    { echo -e "\033[1;32m✅ $*\033[0m"; }
info()  { echo -e "\033[1;36mℹ️  $*\033[0m"; }
caution() { echo -e "\033[1;33m⚠️  $*\033[0m"; }
tip()   { echo -e "\033[2m   💡 $*\033[0m"; }
divider() { echo -e "\033[2m────────────────────────────────────────────────────────────\033[0m"; }
section() { echo; divider; echo -e "\033[1;35m $1  $2\033[0m"; divider; }

banner() {
  echo -e "\033[1;36m"
  cat <<'BANNER_EOF'
   _____  _____   _    _          _____ _           _
  |  __ \|  __ \ | |  | |   /\   / ____| |         | |
  | |__) | |  \__|| |__| |  /  \ | |    | |_   _ ___| |_ ___ _ __
  |  ___/| | \  \ |  __  | / /\ \| |    | | | | / __| __/ _ \ '__|
  | |    | |__/ / | |  | |/ ____ | |____| | |_| \__ \ ||  __/ |
  |_|    |_____/  |_|  |_/_/    \_\_____|_|\__,_|___/\__\___|_|
BANNER_EOF
  echo -e "\033[0m"
  echo -e "\033[1m          🐘  PostgreSQL 17 HA Cluster — Deploy Wizard  🚀\033[0m"
  echo
  echo "  This wizard will:"
  echo "    1️⃣  Ask how many PG nodes you have (and, only if needed, watcher nodes)"
  echo "    2️⃣  Check the etcd quorum is safe for automatic failover"
  echo "    3️⃣  Collect IPs / credentials, then SSH in and install everything"
  echo "    4️⃣  Bootstrap Patroni, optionally HAProxy + keepalived for a VIP"
  echo "    5️⃣  Leave you with a validation checklist to confirm it's healthy"
}

ask_int() {   # ask_int "<prompt>" <min> <max> -> echoes validated integer
  local prompt="$1" min="$2" max="$3" val
  while true; do
    read -rp "  ❓ $prompt [$min-$max]: " val
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max )); then echo "$val"; return 0; fi
    err "Enter a whole number between $min and $max."
  done
}

ask_yn() {   # ask_yn "<prompt>" <Y|N default> -> 0=yes, 1=no
  local prompt="$1" default="${2:-Y}" val hint="y/N"
  [[ "$default" == "Y" ]] && hint="Y/n"
  while true; do
    read -rp "  ❓ $prompt [$hint]: " val; val="${val:-$default}"
    case "$val" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; *) err "Please answer y or n." ;; esac
  done
}

valid_ip() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in ${ip//./ }; do (( o <= 255 )) || return 1; done
  return 0
}

ask_ip() {   # ask_ip "<prompt>" -> validated, de-duplicated against _ALL_IPS_SEEN
  local prompt="$1" ip dup existing
  while true; do
    read -rp "  🌐 $prompt: " ip
    if ! valid_ip "$ip"; then err "Not a valid IPv4 address."; continue; fi
    dup=0
    for existing in "${_ALL_IPS_SEEN[@]:-}"; do [[ "$existing" == "$ip" ]] && dup=1; done
    if (( dup == 1 )); then err "IP $ip was already used for another node above."; continue; fi
    echo "$ip"; return 0
  done
}

banner

# ---------------------------------------------------------------------------
# 1. Cluster sizing & quorum check (flexible N, watcher only if N is even)
# ---------------------------------------------------------------------------
section "🔧" "STEP 1 — Cluster Sizing & Quorum Check"
tip "Every PG node also runs an etcd 'voter' that helps elect the Primary."
tip "For that vote to always produce a clear winner, the TOTAL number of"
tip "voters (PG nodes + watcher nodes) needs to be ODD."

N_PG=0
N_WATCHER=0
while true; do
  echo
  N_PG=$(ask_int "How many PostgreSQL/Patroni data nodes do you have?" 2 20)

  if (( N_PG % 2 != 0 )); then
    N_WATCHER=0
    ok "PG node count is ODD ($N_PG) — quorum is already safe."
    tip "No watcher node needed — skipping that question."
    break
  fi

  echo
  caution "You entered an EVEN number of PG nodes ($N_PG)."
  tip "With an even number of voters, a network split can divide them"
  tip "exactly in half — neither side has a majority, so etcd can't elect"
  tip "a leader and the cluster loses automatic failover."
  echo
  info "That's exactly what a 👀 WATCHER node fixes: it's an etcd-only"
  info "voter (no PostgreSQL, no application traffic) added purely to"
  info "make the total voter count ODD again and restore a safe quorum."

  if ask_yn "Add watcher node(s) to fix the quorum?" Y; then
    N_WATCHER=$(ask_int "How many watcher nodes do you want to add?" 1 10)
    total=$(( N_PG + N_WATCHER ))
    if (( total % 2 != 0 )); then
      ok "Quorum is now $total (ODD) — safe for automatic failover."
      break
    else
      caution "That still leaves an EVEN quorum ($total). Let's fix that."
      continue
    fi
  fi

  if ask_yn "Proceed anyway with an EVEN quorum ($N_PG)? [not recommended]" N; then
    N_WATCHER=0
    caution "Proceeding with an EVEN quorum ($N_PG) as explicitly confirmed."
    caution "Automatic failover may not work correctly during a network split."
    break
  fi

  info "No problem — let's re-enter the node counts."
done

# ---------------------------------------------------------------------------
# 2. Collect input: SSH, per-node IPs, credentials
# ---------------------------------------------------------------------------
section "🔑" "STEP 2 — SSH Access"
read -rp "SSH user (same across all nodes): " SSH_USER
read -rp "Path to SSH private key [~/.ssh/id_rsa]: " SSH_KEY
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"

declare -a _ALL_IPS_SEEN=()
declare -a PG_HOSTS=()
declare -a WATCHER_HOSTS=()

section "🐘" "STEP 3 — PG Node Details ($N_PG node(s))"
tip "Node 1 becomes the INITIAL leader (holds/creates the data). The rest"
tip "start as replicas — after that, Patroni decides who's leader, not order."
for (( i=1; i<=N_PG; i++ )); do
  echo
  echo "--- PG node $i of $N_PG ---"
  role="replica"; (( i == 1 )) && role="initial LEADER, holds data"
  ip=$(ask_ip "Node $i IP ($role)")
  PG_HOSTS+=("$ip"); _ALL_IPS_SEEN+=("$ip")
done
NODE1_IP="${PG_HOSTS[0]}"   # kept for readable messages below

if (( N_WATCHER > 0 )); then
  section "👀" "STEP 3b — Watcher Node Details ($N_WATCHER node(s))"
  tip "Reminder: watcher nodes run ONLY the etcd voter process — no"
  tip "PostgreSQL, no application traffic, never promoted to Primary."
  for (( i=1; i<=N_WATCHER; i++ )); do
    echo
    echo "--- Watcher node $i of $N_WATCHER ---"
    ip=$(ask_ip "Watcher $i IP (etcd quorum member only, no PG)")
    WATCHER_HOSTS+=("$ip"); _ALL_IPS_SEEN+=("$ip")
  done
fi

ETCD_PROBE_IP="${PG_HOSTS[0]}"   # always exists, used for etcd health/admin ops
[[ $N_WATCHER -gt 0 ]] && ETCD_PROBE_IP="${WATCHER_HOSTS[0]}"

# No key on disk -> generate one and install it on all nodes now (password
# auth, once per host, via plain ssh - no ssh-copy-id dependency). Every
# later step in this run, and every future run, then needs zero passwords.
_ALL_HOSTS_EARLY=("${PG_HOSTS[@]}" "${WATCHER_HOSTS[@]}")
if [[ ! -f "$SSH_KEY" ]]; then
  echo
  read -rp "No key at $SSH_KEY. Generate one and install on all ${#_ALL_HOSTS_EARLY[@]} nodes now? [Y/n]: " GEN_KEY
  if [[ "${GEN_KEY,,}" != "n" ]]; then
    mkdir -p "$(dirname "$SSH_KEY")" && chmod 700 "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "pg-ha-deploy-$(date +%Y%m%d)" >/dev/null
    log "Generated $SSH_KEY (no passphrase - automation key, keep this control host secured)."
    log "Installing public key on all ${#_ALL_HOSTS_EARLY[@]} nodes - password prompt once per host:"
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

section "🏷️" "STEP 4 — Cluster Identity & Network"
read -rp "Patroni cluster scope name [pgcluster]: " SCOPE
SCOPE="${SCOPE:-pgcluster}"

DEFAULT_CIDR="$(echo "$NODE1_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')"
read -rp "CIDR allowed to connect to Postgres (replication + clients) [${DEFAULT_CIDR}]: " CLIENT_CIDR
CLIENT_CIDR="${CLIENT_CIDR:-$DEFAULT_CIDR}"

tip "The replication user is what standbys use to stream WAL from the"
tip "Primary — separate from your normal application DB user(s)."
read -rsp "PostgreSQL superuser password: " PG_SUPERUSER_PW; echo
read -rsp "Replication user password: " PG_REPL_PW; echo
read -rsp "Patroni REST API basic-auth password [patroni]: " PATRONI_API_PW; echo
PATRONI_API_PW="${PATRONI_API_PW:-patroni}"

echo
section "🌐" "STEP 5 — Load Balancing (optional)"
tip "With HAProxy+keepalived, apps connect to one floating VIP that always"
tip "follows the current Primary. Without it, apps need libpq multi-host."
read -rp "Enable HAProxy + keepalived on the PG nodes (floating VIP)? [y/N]: " ENABLE_HAPROXY_ANS
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
  PG_HOSTS_CSV="$(IFS=,; echo "${PG_HOSTS[*]}")"
  warn "  host=${PG_HOSTS_CSV} target_session_attrs=read-write"
fi

CM_DIR="$HOME/.ssh/cm"
mkdir -p "$CM_DIR" && chmod 700 "$CM_DIR"
# Connection multiplexing: first ssh/scp to a host opens (and authenticates)
# the connection once; every later call to the same host reuses that same
# socket instead of prompting again. With password auth this cuts you from
# ~4-5 prompts per host down to 1. Sockets auto-close 15min after last use.
SSH_OPTS=("${SSH_KEY_OPT[@]}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
  -o ControlMaster=auto -o ControlPersist=15m -o "ControlPath=$CM_DIR/%r@%h:%p")
ALL_HOSTS=("${PG_HOSTS[@]}" "${WATCHER_HOSTS[@]}")

remote() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "$@"; }
push()   { scp -q "${SSH_OPTS[@]}" -r "$2" "${SSH_USER}@${1}:$3"; }

# ---------------------------------------------------------------------------
# 3. Final summary before anything is touched
# ---------------------------------------------------------------------------
section "📋" "Summary — please review before anything is installed"
echo "  PG nodes ($N_PG):"
n=0
for ip in "${PG_HOSTS[@]}"; do
  n=$((n+1)); role="replica"; (( n == 1 )) && role="initial leader"
  printf "    🐘 pg%-3s %-15s (%s)\n" "$n" "$ip" "$role"
done
if (( N_WATCHER > 0 )); then
  echo "  Watcher nodes ($N_WATCHER):"
  n=0
  for ip in "${WATCHER_HOSTS[@]}"; do
    n=$((n+1)); printf "    👀 watcher%-3s %-15s (etcd-only)\n" "$n" "$ip"
  done
fi
TOTAL_QUORUM=$((N_PG + N_WATCHER))
PARITY="ODD ✅"; (( TOTAL_QUORUM % 2 == 0 )) && PARITY="EVEN ⚠️"
echo "  Quorum total: $TOTAL_QUORUM ($PARITY)"
echo "  HAProxy+keepalived: $ENABLE_HAPROXY"
[[ "$ENABLE_HAPROXY" == "true" ]] && echo "  VIP: $VIP (iface $IFACE)"
echo

if ! ask_yn "Everything correct? Start deployment now" Y; then
  err "Aborted before any changes were made. Re-run the script to try again."
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Connectivity check
# ---------------------------------------------------------------------------
section "🔌" "STEP 6 — Connectivity & Sudo Checks"
log "Testing SSH connectivity to all ${#ALL_HOSTS[@]} nodes..."
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
  until remote "$ETCD_PROBE_IP" "etcdctl --endpoints=http://${ETCD_PROBE_IP}:2379 endpoint health" >/dev/null 2>&1; do
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
section "📦" "STEP 7 — Package Install (all nodes, in parallel)"
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
# 3. Per-node install (packages) - runs on all nodes
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

log "Waiting for all ${#ALL_HOSTS[@]} installs to finish (this is the slow step - tailing as they land)..."
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
# 4. etcd config + start on all nodes
# ---------------------------------------------------------------------------
section "🗄️" "STEP 8 — etcd Quorum Bootstrap"
ETCD_ALREADY_BOOTSTRAPPED="false"
if remote "$ETCD_PROBE_IP" "test -d /var/lib/etcd/member" >/dev/null 2>&1; then
  ETCD_ALREADY_BOOTSTRAPPED="true"
  warn "etcd data dir already exists on $ETCD_PROBE_IP - assuming cluster was already bootstrapped."
  warn "Skipping etcd config re-deploy/restart (mixing new/existing cluster-state across members breaks etcd)."
  warn "To fully re-bootstrap from scratch: stop etcd and 'rm -rf /var/lib/etcd' on ALL nodes first, then re-run."
fi

if [[ "$ETCD_ALREADY_BOOTSTRAPPED" == "false" ]]; then
  log "Deploying etcd config to all ${#ALL_HOSTS[@]} nodes..."
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

  # Start all nodes CONCURRENTLY, not one at a time: etcd's initial bootstrap
  # blocks "systemctl restart" until it reaches quorum with its peers, so
  # starting sequentially deadlocks - node1 waits for node2..N while the
  # script is still stuck waiting for node1's restart to return. This is
  # exactly the same reasoning as the parallel package install above.
  log "Starting etcd on all ${#ALL_HOSTS[@]} nodes in parallel..."
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
    err "Common cause: this node can't reach one or more of the others on ports 2379/2380"
    err "(routing/firewall between subnets, cloud security group, etc)."
    exit 1
  fi
fi

log "Waiting for etcd quorum..."
wait_etcd_healthy || exit 1

# ---------------------------------------------------------------------------
# 5. Patroni config on PG nodes (node1 bootstraps, the rest join)
# ---------------------------------------------------------------------------
section "🐘" "STEP 9 — Patroni Bootstrap"
ETCD_HOSTS_CSV=""
for ip in "${ALL_HOSTS[@]}"; do ETCD_HOSTS_CSV+="${ip}:2379,"; done
ETCD_HOSTS_CSV="${ETCD_HOSTS_CSV%,}"

log "Deploying Patroni config to ${#PG_HOSTS[@]} PG nodes..."
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
  read -rp "Restart all ${#PG_HOSTS[@]} PG nodes anyway? This can trigger a live failover. [y/N]: " CONFIRM_RESTART
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
  # Check ALL PG nodes up front, not just node1: a replica can just as
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
    read -rp "Wipe local data dir on ALL ${#PG_HOSTS[@]} PG nodes + this scope's etcd state, for one fully clean bootstrap? [y/N]: " CONFIRM_WIPE
    if [[ "${CONFIRM_WIPE,,}" == "y" ]]; then
      for ip in "${PG_HOSTS[@]}"; do
        remote "$ip" "sudo systemctl stop patroni 2>/dev/null; sudo rm -rf /var/lib/postgresql/17/main && sudo mkdir -p /var/lib/postgresql/17/main && sudo chown postgres:postgres /var/lib/postgresql/17/main && sudo chmod 700 /var/lib/postgresql/17/main"
      done
      remote "$ETCD_PROBE_IP" "etcdctl --endpoints=http://${ETCD_PROBE_IP}:2379 del /db/${SCOPE} --prefix" >/dev/null
      log "All PG data dirs and etcd scope state cleared - Patroni will initdb fresh on the leader, replicas will clone clean."
    else
      warn "Continuing without wiping - the same crash will very likely repeat on: ${STALE_NODES[*]}"
    fi
  fi

  log "Starting Patroni on LEADER (node1: $NODE1_IP) first..."
  remote "$NODE1_IP" "sudo systemctl enable patroni && sudo systemctl restart patroni"
  wait_patroni_primary "$NODE1_IP" || exit 1

  log "Starting Patroni on replicas (${#PG_HOSTS[@]}-1 node(s))..."
  for ip in "${PG_HOSTS[@]:1}"; do
    remote "$ip" "sudo systemctl enable patroni && sudo systemctl restart patroni"
    wait_patroni_healthy "$ip"
  done
fi

# ---------------------------------------------------------------------------
# 6. Optional: HAProxy + keepalived on all PG nodes
# ---------------------------------------------------------------------------
if [[ "$ENABLE_HAPROXY" == "true" ]]; then
  section "🌐" "STEP 10 — HAProxy + keepalived"
  log "Deploying HAProxy (local, per PG node) - each checks all PG nodes' /primary..."
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

  log "Deploying keepalived (VIP $VIP on $IFACE, unicast between ${#PG_HOSTS[@]} PG nodes)..."
  n=0
  for ip in "${PG_HOSTS[@]}"; do
    n=$((n+1))
    STATE="BACKUP"; [[ $n -eq 1 ]] && STATE="MASTER"
    # Gap (40) intentionally exceeds the vrrp_script weight magnitude (30) in
    # keepalived.conf.tpl so one failed health check always drops a node
    # below every remaining healthy backup, regardless of node count. Never
    # goes below 1 even with many nodes.
    PRIORITY=$(( 200 - (n-1)*40 )); (( PRIORITY < 1 )) && PRIORITY=1
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
section "🎉" "Deployment Complete"
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
PG_HOSTS_CSV="$(IFS=,; echo "${PG_HOSTS[*]}")"
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
  psql "host=${PG_HOSTS_CSV} port=5432 target_session_attrs=read-write dbname=postgres user=postgres"
EOF
fi

cat <<EOF

Patroni REST API (per node): http://<node-ip>:8008/  (GET /primary, /replica)

Test failover:
  ssh ${SSH_USER}@${PG_HOSTS[0]} 'sudo systemctl stop patroni'
  ssh ${SSH_USER}@${PG_HOSTS[1]} "sudo -u postgres patronictl -c /etc/patroni/patroni.yml list"

Test failback (bring old leader back):
  ssh ${SSH_USER}@${PG_HOSTS[0]} 'sudo systemctl start patroni'
  # patroni + pg_rewind auto-rejoins it as replica
EOF

section "🧪" "Validation & Testing — do these next"
cat <<EOF
  1️⃣  patronictl -c /etc/patroni/patroni.yml list
      👉 Expect exactly ONE "Leader" and the rest "Sync Standby"/"Replica", all "running".
  2️⃣  etcdctl --endpoints=http://${ETCD_PROBE_IP}:2379 endpoint health --cluster
      👉 All ${TOTAL_QUORUM} member(s) should report "healthy".
  3️⃣  ./test-failover-failback.sh
      👉 Automated kill-leader / bring-it-back smoke test (this directory).
  4️⃣  cd ../ha-validate && run with --tests safe first
      👉 Full non-destructive HA-readiness report (connectivity, replication,
         security, performance) before trying any destructive test category.
EOF

section "🔁" "Good to know — Watcher vs. Switchover vs. Failover"
cat <<EOF
  👀 Watcher node = a permanent etcd-only voter that just keeps the quorum
                    odd. It never runs PostgreSQL and is never promoted.
  🔀 Switchover   = a DELIBERATE, planned role change you trigger yourself:
                    patronictl -c /etc/patroni/patroni.yml switchover
  ⚡ Failover     = an AUTOMATIC role change Patroni performs on its own
                    when the current Primary becomes unreachable — this is
                    what the watcher node's odd quorum protects.

  Need to replace/relocate a watcher later? Use manage-watcher.sh in this
  same directory rather than editing config files by hand.
EOF
