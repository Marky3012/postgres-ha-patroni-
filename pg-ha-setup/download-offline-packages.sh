#!/usr/bin/env bash
# Run this on an INTERNET-CONNECTED Ubuntu 24.04 x86_64 machine
# (same OS/arch as your target VMs). Produces ./pg-ha-offline-pkgs/
# Copy that whole directory to /opt/pg-ha-offline-pkgs on each target node
# (or let deploy.sh auto-copy it if it finds this dir alongside itself).
set -euo pipefail

OUT="$(pwd)/pg-ha-offline-pkgs"
mkdir -p "$OUT/debs" "$OUT/wheels"

echo "[*] Adding PGDG repo (for postgresql-17 .debs)..."
install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update -y

# Ubuntu staggers some point-release packages via "phased updates" - a
# fraction of machines get the newer build before others. If THIS machine
# already has some packages partially upgraded and others not, apt can't
# resolve a consistent dependency set for whatever we're about to pull
# (classic symptom: "Depends: libfoo (= X) but Y is to be installed").
# Force everything to the latest candidate version, phased or not, before
# downloading - avoids exactly that class of unmet-dependency error.
echo "[*] Syncing base system to latest package versions (avoids phased-update dependency conflicts)..."
sudo apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y
sudo apt-get --fix-broken install -y

PKGS=(
  curl gnupg2 lsb-release ca-certificates python3-pip python3-venv
  postgresql-17 postgresql-client-17
  haproxy keepalived
)

echo "[*] Downloading .debs (with full dependency closure) for: ${PKGS[*]}"
# --download-only pulls the package + all its deps into /var/cache/apt/archives
if ! sudo apt-get install --download-only -y "${PKGS[@]}"; then
  echo "[!] Unmet dependencies on first attempt - retrying after apt --fix-broken install..."
  sudo apt-get --fix-broken install -y
  sudo apt-get install --download-only -y "${PKGS[@]}"
fi
sudo cp /var/cache/apt/archives/*.deb "$OUT/debs/"
sudo chown "$(id -u):$(id -g)" "$OUT"/debs/*.deb

echo "[*] Downloading etcd binary release..."
ETCD_VER="v3.5.17"
curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz" \
  -o "$OUT/etcd-${ETCD_VER}-linux-amd64.tar.gz"

echo "[*] Downloading Patroni + psycopg2-binary wheels..."
pip3 download --dest "$OUT/wheels" 'patroni[etcd]' psycopg2-binary

echo "[*] Packaging tarball..."
tar czf "pg-ha-offline-pkgs.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"

cat <<EOF

[+] Done. Output:
    $OUT/                       (raw directory)
    $(pwd)/pg-ha-offline-pkgs.tar.gz   (tarball)

Copy to each target node, e.g.:
    scp pg-ha-offline-pkgs.tar.gz user@node-ip:/tmp/
    ssh user@node-ip 'sudo mkdir -p /opt && sudo tar xzf /tmp/pg-ha-offline-pkgs.tar.gz -C /opt'

Or place the pg-ha-offline-pkgs/ directory next to deploy.sh on your control
machine - deploy.sh will auto-detect and push it to every node before install.
EOF
