# PostgreSQL HA Cluster - Deployment + Validation

Two independent projects, used together:

## `pg-ha-setup/`
Orchestrator that stands up the cluster itself: 4 PG data nodes (Patroni-
managed, streaming replication) + 1 watcher node (etcd quorum member only).
Optional HAProxy + keepalived on the PG nodes for a floating VIP. Run
`deploy.sh` from a control machine with SSH access to all 5 target nodes.

See `pg-ha-setup/deploy.sh` (prompts for everything interactively) and
`pg-ha-setup/test-failover-failback.sh` for a quick manual smoke test.

**`pg-ha-setup/manage-watcher.sh`** — auto-detects the current watcher from
etcd's own member list (by elimination against the 4 PG node IPs you give
it), health-checks it, and only prompts you for a new IP if it's missing or
unhealthy. Run as root on one of the 4 healthy PG nodes; needs
`remote-install.sh` in the same directory (already there).

## `ha-validate/`
End-to-end automated test framework that runs against an already-deployed
cluster: connectivity, security, replication, performance, planned/unplanned
failover, failback, data integrity, disaster recovery, and RTO/RPO
compliance. Produces JSON/HTML/Excel/PDF reports with an overall HA-readiness
score. See `ha-validate/README.md` for setup and usage.

**`ha-validate/WATCHER-REPLACEMENT-GUIDE.md`** — the manual step-by-step
version of what `manage-watcher.sh` automates, for replacing a dead watcher
node or relocating a healthy one (e.g. to fix a site-quorum imbalance),
using etcd's real `member add`/`member remove` flow. Read this before
touching the watcher node manually - editing config files and restarting
does not work the way it looks like it should.

## Order of operations for a new cluster

1. `pg-ha-setup/deploy.sh` - stand up the cluster
2. `ha-validate` with `--tests safe` - confirm non-destructive health
3. `ha-validate` with the destructive categories, one at a time, only once
   step 2 is clean and you have a confirmed maintenance window
4. `pg-ha-setup/manage-watcher.sh` whenever the watcher needs attention -
   it's the one node whose replacement procedure isn't obvious from the
   deploy scripts alone
