# PostgreSQL HA Validation Framework

End-to-end automated testing for a Patroni/etcd/HAProxy PostgreSQL HA cluster
(built to match the 4-node + watcher setup from the deploy scripts, but works
against any Patroni-managed cluster with the same config shape).

Runs real checks against real nodes over SSH + direct Postgres/HTTP
connections - nothing here is simulated locally. Produces JSON, HTML, Excel,
and PDF reports with an overall HA-readiness score.

## What it tests

| Category | What it does | Destructive? |
|---|---|---|
| `connectivity` | Direct PG connect to every node + VIP, Patroni REST reachability | No |
| `security` | pg_hba exposure, unauthenticated admin endpoints, port exposure | No |
| `replication` | Topology sanity (1 leader), per-replica lag vs SLA | No |
| `performance` | Write/read latency percentiles, baseline + post-failover | No |
| `planned_failover` | `patronictl switchover`, measures RTO, verifies old leader rejoins | No (graceful) |
| `failback` | Restarts a demoted/crashed node, confirms clean replica rejoin + lag convergence | No |
| `data_integrity` | Marker rows written before an event, verified after - catches any data loss | No (runs inline with failover tests) |
| `unplanned_failover` | `kill -9` postgres + stop patroni on the leader, no warning - simulates a real crash | **Yes** |
| `disaster_recovery` | Stops etcd+patroni on 2 of 4 PG nodes simultaneously - validates quorum survives a site loss | **Yes** |
| `rto_rpo` | Aggregates RTO/RPO from the above into one SLA compliance summary | No |

## Setup

```bash
pip install -r requirements.txt
cp config.example.yaml config.yaml
# edit config.yaml: node IPs, SSH key, DB credentials, SLA targets
```

The SSH user needs passwordless sudo on every node (same requirement as
`deploy.sh`) and `sudo -u postgres patronictl` access.

## Running

Non-destructive only (safe against a live cluster, including production):
```bash
python ha_validate.py --config config.yaml --tests safe
```

Everything, including destructive crash/DR simulation - **only ever run this
against a cluster you're prepared to have disrupted**, and set
`tests.enable_destructive: true` in config.yaml first:
```bash
python ha_validate.py --config config.yaml --tests all --confirm-destructive
```

Specific categories:
```bash
python ha_validate.py --config config.yaml --tests connectivity,replication,security
```

## Safety model

`unplanned_failover` and `disaster_recovery` require **both**:
1. `tests.enable_destructive: true` in config.yaml
2. `--confirm-destructive` on the command line

Missing either one blocks those categories with a clear message - they don't
silently downgrade to a no-op, and they don't run partially.

## Output

Reports land in `output_dir` (default `./results/`):
- `ha_report.json` - source of truth, everything else is generated from this
- `ha_report.html` - dashboard with category chart + full results table
- `ha_report.xlsx` - Summary / Category Status / Test Results / SLA Compliance sheets
- `ha_report.pdf` - executive summary, category breakdown, failure analysis, SLA table, full appendix

Exit code is `1` if overall readiness is `NOT READY`, `0` otherwise - safe to
wire into CI/scheduled health checks.

## HA readiness scoring

Each category is weighted (see `CATEGORY_WEIGHTS` in `lib/models.py`).
`data_integrity`, `unplanned_failover`, and `failback` are marked critical:
a FAIL in any of those caps overall readiness at **NOT READY** regardless of
the numeric score - a cluster that loses data or can't recover from a crash
isn't "mostly ready."

## Extending

Each test module's `run(ctx)` uses `ctx.new_result(name, category)` as a
context manager - it times itself and records PASS/ERROR automatically based
on whether the block raises. Add a new check by adding a `with` block; add a
new category by dropping a new `tests/t_*.py` module and wiring it into
`ha_validate.py`'s `run_campaign()`.
