#!/usr/bin/env bash
# Runs ON each remote node via:
#   sudo bash remote-install.sh <is_pg_node:true|false> <enable_haproxy:true|false>
set -euo pipefail
IS_PG_NODE="${1:-false}"
ENABLE_HAPROXY="${2:-false}"

OFFLINE_DIR="/opt/pg-ha-offline-pkgs"
export DEBIAN_FRONTEND=noninteractive
APT_UPDATED=""

log(){ echo "[install] $*"; }

# Self-heal: an interrupted apt/dpkg transaction from a previous failed run
# (or an unrelated system process) leaves dpkg in a half-configured state
# that silently breaks LATER unrelated package installs in this run too.
# Clear that before we touch anything.
log "Checking for leftover broken dpkg state..."
dpkg --configure -a >/tmp/dpkg_configure_a.log 2>&1 || log "dpkg --configure -a reported issues, see /tmp/dpkg_configure_a.log (continuing)"

apt_update_once() {
  if [[ -z "$APT_UPDATED" ]]; then
    apt-get update -y || log "apt-get update failed (offline? continuing to offline fallback)"
    APT_UPDATED=1
  fi
}

# Install apt packages: skip already-installed, try repo, fall back to
# offline .deb cache in $OFFLINE_DIR/debs, else fail with clear instructions.
apt_install_or_offline() {
  local pkgs=("$@") need=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" &>/dev/null || need+=("$p")
  done
  [[ ${#need[@]} -eq 0 ]] && { log "already installed: ${pkgs[*]}"; return 0; }

  apt_update_once
  if apt-get install -y "${need[@]}" 2>/tmp/apt_err.log; then
    log "installed via apt: ${need[*]}"
    return 0
  fi
  log "apt install failed for: ${need[*]} - $(tail -n1 /tmp/apt_err.log 2>/dev/null)"

  # Common cause: this node's already-installed base packages are one
  # phased-update patch behind what the repo's current candidate build
  # strictly requires (Ubuntu staggers point-release rollout). Force
  # everything to the latest candidate and retry once before giving up on
  # the online path.
  log "Retrying: syncing base packages to latest (incl. phased updates) + apt --fix-broken..."
  apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y >/tmp/apt_upgrade.log 2>&1 || true
  apt-get --fix-broken install -y >/tmp/apt_fixbroken.log 2>&1 || true
  if apt-get install -y "${need[@]}" 2>>/tmp/apt_err.log; then
    log "installed via apt after phased-update sync: ${need[*]}"
    return 0
  fi
  log "still failing after retry -- trying offline cache at $OFFLINE_DIR/debs"

  if [[ -d "$OFFLINE_DIR/debs" ]]; then
    local any=0 p debs
    for p in "${need[@]}"; do
      debs=$(find "$OFFLINE_DIR/debs" -iname "${p}_*.deb" 2>/dev/null || true)
      if [[ -n "$debs" ]]; then
        if ! dpkg -i $debs >"/tmp/dpkg_${p}.log" 2>&1; then
          log "dpkg -i failed for $p (see /tmp/dpkg_${p}.log): $(tail -n1 "/tmp/dpkg_${p}.log")"
        fi
        any=1
      fi
    done
    apt-get install -f -y || true   # resolve any dep gaps from local cache
    local still_missing=()
    for p in "${need[@]}"; do dpkg -s "$p" &>/dev/null || still_missing+=("$p"); done
    if [[ ${#still_missing[@]} -eq 0 ]]; then
      log "installed from offline cache: ${need[*]}"
      return 0
    fi
    need=("${still_missing[@]}")
  fi

  cat >&2 <<EOF
[FATAL] Could not install: ${need[*]}
  No reachable package repo, and no matching .deb in $OFFLINE_DIR/debs
  Fix: on an internet-connected Ubuntu 24.04 (same arch) machine run
  download-offline-packages.sh, copy the resulting pg-ha-offline-pkgs/
  directory to $OFFLINE_DIR on this node, then re-run this installer.
EOF
  return 1
}

apt_install_or_offline curl gnupg2 lsb-release ca-certificates python3-pip python3-venv

# Clock sync matters here: etcd's Raft timing and Patroni's DCS TTL/lease
# logic both assume reasonably synced clocks across nodes. Ubuntu ships
# systemd-timesyncd by default - just make sure it's actually on.
systemctl enable systemd-timesyncd >/dev/null 2>&1 || true
systemctl restart systemd-timesyncd >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# etcd (every node: all PG nodes + any watcher node(s))
# ---------------------------------------------------------------------------
if command -v etcd >/dev/null 2>&1; then
  log "etcd already installed"
else
  ETCD_VER="v3.5.17"
  ETCD_TARBALL="etcd-${ETCD_VER}-linux-amd64.tar.gz"
  if [[ -f "$OFFLINE_DIR/$ETCD_TARBALL" ]]; then
    log "using offline etcd tarball"
    cp "$OFFLINE_DIR/$ETCD_TARBALL" /tmp/etcd.tar.gz
  elif curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/${ETCD_TARBALL}" -o /tmp/etcd.tar.gz; then
    log "downloaded etcd online"
  else
    echo "[FATAL] etcd binary unavailable online or offline ($OFFLINE_DIR/$ETCD_TARBALL)." >&2
    echo "        Run download-offline-packages.sh and place result in $OFFLINE_DIR." >&2
    exit 1
  fi
  tar xzf /tmp/etcd.tar.gz -C /tmp
  mv /tmp/etcd-${ETCD_VER}-linux-amd64/etcd /tmp/etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
  useradd -r -s /sbin/nologin etcd || true
  mkdir -p /var/lib/etcd && chown etcd:etcd /var/lib/etcd
  cat >/etc/systemd/system/etcd.service <<'EOF'
[Unit]
Description=etcd
After=network.target

[Service]
Type=notify
TimeoutStartSec=120
EnvironmentFile=/etc/default/etcd
ExecStart=/usr/local/bin/etcd
User=etcd
Restart=on-failure
RestartSec=5
LimitNOFILE=40000

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
fi

# ---------------------------------------------------------------------------
# PG node specifics
# ---------------------------------------------------------------------------
if [[ "$IS_PG_NODE" == "true" ]]; then
  if ! dpkg -s postgresql-17 &>/dev/null && [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    install -d /usr/share/postgresql-common/pgdg
    if curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc; then
      echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
      APT_UPDATED=""   # force refresh so the new repo is picked up
    else
      log "PGDG repo unreachable (offline?) - relying on $OFFLINE_DIR/debs for postgresql-17"
    fi
  fi
  apt_install_or_offline postgresql-17 postgresql-client-17

  # Patroni owns the data dir lifecycle - stock service must not auto-start
  systemctl stop postgresql || true
  systemctl disable postgresql || true

  if python3 -c "import patroni" &>/dev/null; then
    log "patroni already installed"
  elif pip3 install --break-system-packages --upgrade patroni[etcd] psycopg2-binary 2>/tmp/pip_err.log; then
    log "patroni installed via pip (online)"
  elif [[ -d "$OFFLINE_DIR/wheels" ]]; then
    pip3 install --break-system-packages --no-index --find-links="$OFFLINE_DIR/wheels" \
      patroni[etcd] psycopg2-binary
    log "patroni installed from offline wheels"
  else
    echo "[FATAL] Could not install patroni: no internet and no $OFFLINE_DIR/wheels" >&2
    echo "        Run download-offline-packages.sh and place result in $OFFLINE_DIR." >&2
    exit 1
  fi

  cat >/etc/systemd/system/patroni.service <<'EOF'
[Unit]
Description=Patroni PostgreSQL HA
After=network.target etcd.service

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload

  # --- Optional: HAProxy + keepalived, installed locally on THIS PG node ---
  if [[ "$ENABLE_HAPROXY" == "true" ]]; then
    apt_install_or_offline haproxy keepalived
    systemctl enable haproxy keepalived 2>/dev/null || true
  fi
else
  log "watcher node: etcd only (no PG, no HAProxy here)"
fi

echo "remote-install.sh done (pg_node=$IS_PG_NODE haproxy=$ENABLE_HAPROXY)"
