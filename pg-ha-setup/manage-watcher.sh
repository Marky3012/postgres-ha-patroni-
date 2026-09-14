#!/usr/bin/env bash
# Run this AS ROOT ON one of the 4 healthy PG nodes (it uses the local
# etcdctl + /etc/patroni/patroni.yml already on that node). Needs SSH key
# access (same as deploy.sh) to the other 3 PG nodes and to the watcher
# IP (new or existing). Needs pg-ha-setup/remote-install.sh in the same
# directory - it's reused to provision the watcher's etcd install.
#
# Flow:
#   1. Detect the current watcher (if any) from `etcd member list`, by
#      elimination against the 4 PG node IPs you provide.
#   2. Health-check it. If healthy, nothing to do (unless you want to force
#      a relocation).
#   3. If missing or unhealthy, ask for a NEW watcher IP and perform the
#      real etcdctl member add/remove flow (see WATCHER-REPLACEMENT-GUIDE.md
#      for why this can't just be a config-file edit).
#   4. If the watcher IP changed, update etcd3.hosts in patroni.yml on all
#      4 PG nodes and roll-restart Patroni one node at a time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  err "Run this as root (needs local etcdctl + systemctl + patroni.yml access)."
  exit 1
fi
if ! command -v etcdctl >/dev/null 2>&1; then
  err "etcdctl not found - this must run on a node that already has etcd installed (one of the 4 PG nodes)."
  exit 1
fi
if [[ ! -f "$SCRIPT_DIR/remote-install.sh" ]]; then
  err "remote-install.sh not found next to this script - copy it from pg-ha-setup/ first (needed to provision a new watcher)."
  exit 1
fi

LOCAL_ETCD="http://127.0.0.1:2379"
PATRONI_CFG="/etc/patroni/patroni.yml"

echo "=== Watcher Node Manager ==="
read -rp "SSH user (same across all nodes): " SSH_USER
read -rp "Path to SSH private key [~/.ssh/id_rsa]: " SSH_KEY
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
SSH_KEY_OPT=(); [[ -f "$SSH_KEY" ]] && SSH_KEY_OPT=(-i "$SSH_KEY")
SSH_OPTS=("${SSH_KEY_OPT[@]}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)
remote() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "$@"; }
push()   { scp -q "${SSH_OPTS[@]}" "$2" "${SSH_USER}@${1}:$3"; }

echo
echo "Enter the 4 PG node IPs (used to tell them apart from the watcher):"
read -rp "  PG node 1 IP: " PG1
read -rp "  PG node 2 IP: " PG2
read -rp "  PG node 3 IP: " PG3
read -rp "  PG node 4 IP: " PG4
PG_IPS=("$PG1" "$PG2" "$PG3" "$PG4")

# ---------------------------------------------------------------------------
# 1. Detect current watcher by elimination against the 4 known PG IPs
# ---------------------------------------------------------------------------
log "Reading etcd member list..."
MEMBERS_JSON="$(etcdctl --endpoints="$LOCAL_ETCD" member list -w json)"

read -r CURRENT_WATCHER_ID CURRENT_WATCHER_IP <<< "$(python3 - "$MEMBERS_JSON" "${PG_IPS[@]}" <<'PYEOF'
import sys, json
data = json.loads(sys.argv[1])
pg_ips = set(sys.argv[2:])
watcher = None
for m in data.get("members", []):
    urls = m.get("clientURLs") or []
    ip = None
    for u in urls:
        ip = u.split("//")[-1].split(":")[0]
        break
    if ip and ip not in pg_ips:
        watcher = (m.get("ID"), ip)
        break
if watcher:
    # etcd member IDs are large ints; etcdctl member remove wants hex
    print(format(watcher[0], "x"), watcher[1])
else:
    print("NONE NONE")
PYEOF
)"

NEED_NEW_WATCHER="false"
OLD_WATCHER_ID=""
OLD_WATCHER_IP=""

if [[ "$CURRENT_WATCHER_IP" == "NONE" ]]; then
  warn "No watcher member found in etcd (only the 4 PG nodes are present)."
  NEED_NEW_WATCHER="true"
else
  log "Current watcher detected: $CURRENT_WATCHER_IP (member id: $CURRENT_WATCHER_ID)"
  log "Health-checking it..."
  if etcdctl --endpoints="http://${CURRENT_WATCHER_IP}:2379" endpoint health --dial-timeout=5s >/dev/null 2>&1; then
    log "Watcher $CURRENT_WATCHER_IP is healthy."
    read -rp "Relocate it to a different IP anyway? [y/N]: " FORCE_RELOCATE
    if [[ "${FORCE_RELOCATE,,}" != "y" ]]; then
      log "Nothing to do."
      exit 0
    fi
    OLD_WATCHER_ID="$CURRENT_WATCHER_ID"
    OLD_WATCHER_IP="$CURRENT_WATCHER_IP"
    NEED_NEW_WATCHER="true"
  else
    warn "Watcher $CURRENT_WATCHER_IP is UNREACHABLE/unhealthy - needs replacing."
    OLD_WATCHER_ID="$CURRENT_WATCHER_ID"
    OLD_WATCHER_IP="$CURRENT_WATCHER_IP"
    NEED_NEW_WATCHER="true"
  fi
fi

[[ "$NEED_NEW_WATCHER" == "false" ]] && { log "No action needed."; exit 0; }

# ---------------------------------------------------------------------------
# 2. Ask for the new watcher IP
# ---------------------------------------------------------------------------
echo
read -rp "New watcher IP: " NEW_WATCHER_IP
until [[ "$NEW_WATCHER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; do
  echo "Invalid IPv4 format."; read -rp "New watcher IP: " NEW_WATCHER_IP
done
if [[ "$NEW_WATCHER_IP" == "$OLD_WATCHER_IP" ]]; then
  err "New IP is the same as the old one - if you're rebuilding the same box, just re-run remote-install.sh on it directly, this script is for a real IP change."
  exit 1
fi
for ip in "${PG_IPS[@]}"; do
  [[ "$NEW_WATCHER_IP" == "$ip" ]] && { err "That IP belongs to a PG node - pick something else."; exit 1; }
done

if ! remote "$NEW_WATCHER_IP" "echo ok" >/dev/null 2>&1; then
  err "Cannot SSH to $NEW_WATCHER_IP as $SSH_USER. Fix access first."
  exit 1
fi
if ! remote "$NEW_WATCHER_IP" "sudo -n true" >/dev/null 2>&1; then
  err "$NEW_WATCHER_IP: sudo requires a password (or $SSH_USER lacks sudo). Fix before continuing."
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Add-before-remove: bring the new watcher up first (safer - never below
#    5 healthy members during the swap), remove the old one only after.
# ---------------------------------------------------------------------------
log "Installing etcd on the new watcher ($NEW_WATCHER_IP)..."
push "$NEW_WATCHER_IP" "$SCRIPT_DIR/remote-install.sh" "/tmp/remote-install.sh"
remote "$NEW_WATCHER_IP" "sudo bash /tmp/remote-install.sh false false"

WATCHER_NAME="etcd-watcher-$(date +%s)"
log "Registering $WATCHER_NAME with the existing etcd cluster..."
ADD_OUTPUT="$(etcdctl --endpoints="$LOCAL_ETCD" member add "$WATCHER_NAME" --peer-urls="http://${NEW_WATCHER_IP}:2380")"
echo "$ADD_OUTPUT"

# etcdctl member add prints an ETCD_INITIAL_CLUSTER= line meant for exactly
# this kind of scripted consumption - extract it rather than re-deriving it.
NEW_INITIAL_CLUSTER="$(echo "$ADD_OUTPUT" | grep '^ETCD_INITIAL_CLUSTER=' | cut -d= -f2- | tr -d '"')"
if [[ -z "$NEW_INITIAL_CLUSTER" ]]; then
  err "Could not parse ETCD_INITIAL_CLUSTER from 'member add' output - inspect it above and finish manually per WATCHER-REPLACEMENT-GUIDE.md."
  exit 1
fi

cat > "$WORKDIR/etcd.default" <<EOF
ETCD_NAME="${WATCHER_NAME}"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_LISTEN_PEER_URLS="http://${NEW_WATCHER_IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${NEW_WATCHER_IP}:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${NEW_WATCHER_IP}:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://${NEW_WATCHER_IP}:2379"
ETCD_INITIAL_CLUSTER="${NEW_INITIAL_CLUSTER}"
ETCD_INITIAL_CLUSTER_STATE="existing"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-etcd-token"
EOF
push "$NEW_WATCHER_IP" "$WORKDIR/etcd.default" "/tmp/etcd.default"
remote "$NEW_WATCHER_IP" "sudo mv /tmp/etcd.default /etc/default/etcd && sudo systemctl enable etcd && sudo systemctl start etcd"

log "Waiting for the new watcher to come up healthy..."
sleep 5
if ! etcdctl --endpoints="http://${NEW_WATCHER_IP}:2379" endpoint health --dial-timeout=5s >/dev/null 2>&1; then
  err "New watcher did not come up healthy. Check: ssh ${SSH_USER}@${NEW_WATCHER_IP} 'sudo journalctl -u etcd -n 50'"
  exit 1
fi
log "New watcher $NEW_WATCHER_IP is healthy."

if [[ -n "$OLD_WATCHER_ID" ]]; then
  log "Removing old watcher (id: $OLD_WATCHER_ID, ip: $OLD_WATCHER_IP)..."
  etcdctl --endpoints="$LOCAL_ETCD" member remove "$OLD_WATCHER_ID"
  remote "$OLD_WATCHER_IP" "sudo systemctl stop etcd && sudo systemctl disable etcd" 2>/dev/null || \
    warn "Could not reach $OLD_WATCHER_IP to stop its etcd service - if it's genuinely dead this is expected, just decommission the VM."
fi

log "Cluster membership now:"
etcdctl --endpoints="$LOCAL_ETCD" member list

# ---------------------------------------------------------------------------
# 4. Point Patroni at the new watcher IP on all 4 PG nodes, rolling restart
# ---------------------------------------------------------------------------
if [[ "$NEW_WATCHER_IP" != "$OLD_WATCHER_IP" ]]; then
  log "Updating etcd3.hosts in patroni.yml on all 4 PG nodes (rolling restart)..."
  NEW_ETCD_HOSTS=""
  for ip in "${PG_IPS[@]}" "$NEW_WATCHER_IP"; do
    NEW_ETCD_HOSTS+="${ip}:2379,"
  done
  NEW_ETCD_HOSTS="${NEW_ETCD_HOSTS%,}"

  for ip in "${PG_IPS[@]}"; do
    log "  -> $ip"
    remote "$ip" "sudo sed -i -E 's#^(\s*hosts:).*#\1 ${NEW_ETCD_HOSTS}#' ${PATRONI_CFG}"
    remote "$ip" "sudo systemctl restart patroni"
    sleep 5
    remote "$ip" "sudo -u postgres patronictl -c ${PATRONI_CFG} list" || warn "Could not confirm health on $ip yet, check manually before moving to the next node"
    read -rp "  $ip restarted - looks healthy above? Press enter to continue to the next node (Ctrl+C to stop here): "
  done
  log "All 4 PG nodes updated and restarted."
else
  log "Watcher IP unchanged - no Patroni config update needed."
fi

echo
log "Done. New watcher: $NEW_WATCHER_IP"
warn "Housekeeping (not urgent, see WATCHER-REPLACEMENT-GUIDE.md): the ETCD_INITIAL_CLUSTER"
warn "string in /etc/default/etcd on the 4 PG nodes is now stale - harmless, but worth"
warn "refreshing next time you touch those files, in case one ever needs a from-scratch rebuild."
