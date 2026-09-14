# PostgreSQL HA Cluster - Deployment + Validation (Advanced)

The most scalable setup in this project line: `pg-ha-setup/` no longer assumes
a fixed 4-node cluster. It scales to **however many PostgreSQL/Patroni nodes
you actually run** and figures out, on its own, whether you need a watcher
node at all.

Two independent projects, used together:

## `pg-ha-setup/`

Orchestrator that stands up the cluster itself: a flexible number of PG data
nodes (Patroni-managed, streaming replication), plus watcher node(s) (etcd
quorum member only, no PG) - watchers are only asked for when your PG node
count is EVEN, and only as many as needed to make the etcd quorum ODD again
(an odd PG count already has a safe quorum on its own, no watcher needed).
Optional HAProxy + keepalived on the PG nodes for a floating VIP. Run
`deploy.sh` from a control machine with SSH access to every target node.

**More user-interactive than a fixed-topology script.** `deploy.sh` walks you
through cluster sizing step by step instead of assuming a shape: it asks how
many PG nodes you have, checks whether that leaves the etcd/DCS quorum ODD or
EVEN, and - only if it's EVEN - explains *why* that matters (a network split
can divide an even voter count with no majority on either side) before
offering to add watcher node(s) to fix it. Every step is labeled and
color-coded (tips, cautions, confirmations) so you understand the quorum math
behind each prompt, not just what to type next.

See `pg-ha-setup/deploy.sh` (prompts for everything interactively, explains
the quorum/watcher logic as it goes) and `pg-ha-setup/test-failover-failback.sh`
for a quick manual smoke test.

**`pg-ha-setup/manage-watcher.sh`** — asks how many PG nodes you have, then
auto-detects the current watcher(s) from etcd's own member list (by
elimination against those PG IPs), health-checks it, and only prompts you
for a new IP if it's missing or unhealthy (if more than one watcher exists,
it asks which one you mean). Run as root on one of the healthy PG nodes;
needs `remote-install.sh` in the same directory (already there).

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
touching a watcher node manually - editing config files and restarting
does not work the way it looks like it should.

## Order of operations for a new cluster

1. `pg-ha-setup/deploy.sh` - answer the sizing questions, stand up the cluster
2. `ha-validate` with `--tests safe` - confirm non-destructive health
3. `ha-validate` with the destructive categories, one at a time, only once
   step 2 is clean and you have a confirmed maintenance window
4. `pg-ha-setup/manage-watcher.sh` whenever a watcher needs attention -
   it's the node type whose replacement procedure isn't obvious from the
   deploy scripts alone
