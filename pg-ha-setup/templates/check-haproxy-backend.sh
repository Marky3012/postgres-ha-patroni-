#!/usr/bin/env bash
# Used by keepalived vrrp_script. Exits 0 only if THIS node's local HAProxy
# actually has a reachable UP server in the postgres_primary backend -
# i.e. it can route to a working PG leader, not merely "the process exists"
# (plain `pgrep haproxy` would stay green even if all backends are down,
# e.g. during a network partition on this node's side).
set -euo pipefail
curl -fs http://127.0.0.1:7000/\;csv 2>/dev/null | awk -F, '
  $1=="postgres_primary" && $18=="UP" { found=1 }
  END { exit !found }
'
