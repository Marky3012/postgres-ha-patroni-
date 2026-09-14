# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

Two independent projects that operate on the same kind of cluster but don't import each other:

- **`pg-ha-setup/`** — bash orchestrator that stands up the cluster: 4 PostgreSQL 17 data nodes
  (Patroni-managed, streaming replication) + 1 watcher node (etcd quorum member only, no PG).
  Optional HAProxy + keepalived on the 4 PG nodes for a floating VIP. Ubuntu 24.04 targets.
- **`ha-validate/`** — Python framework that runs end-to-end tests against an already-deployed
  cluster (connectivity, security, replication, performance, failover/failback, disaster
  recovery, RTO/RPO) and produces JSON/HTML/Excel/PDF reports with an HA-readiness score.

Order of operations: `pg-ha-setup/deploy.sh` → `ha-validate --tests safe` → destructive
`ha-validate` categories (only with a confirmed maintenance window) → `pg-ha-setup/manage-watcher.sh`
whenever the watcher node needs replacing.

## pg-ha-setup/

Pure bash, no build step. Everything runs from a control machine over SSH — nothing is installed
locally.

- `deploy.sh` — the main entry point. Fully interactive (prompts for node IPs, SSH creds,
  passwords, whether to enable HAProxy/keepalived). SSHes into all 5 target nodes and drives the
  whole install/bootstrap. Uses SSH ControlMaster multiplexing (`~/.ssh/cm/`) so a password only
  needs to be entered once per host per run. Installs etcd and Patroni **in parallel** across
  nodes deliberately — starting them sequentially deadlocks because each instance blocks on
  quorum with peers that haven't started yet.
- `remote-install.sh` — pushed to and run *on* each target node by `deploy.sh` (`sudo bash
  remote-install.sh <is_pg_node> <enable_haproxy>`); installs packages (PostgreSQL 17, Patroni,
  etcd, optionally HAProxy/keepalived).
- `manage-watcher.sh` — run standalone, as root, on one of the 4 healthy PG nodes. Auto-detects
  the current watcher by elimination against etcd's member list vs. the 4 known PG node IPs, and
  only prompts for a replacement IP if the watcher is missing/unhealthy. Requires
  `remote-install.sh` alongside it.
- `download-offline-packages.sh` — pre-fetches packages into `pg-ha-offline-pkgs/` (or a
  `.tar.gz`) next to `deploy.sh`; if present, `deploy.sh` auto-pushes this cache to all nodes as
  an install fallback for nodes without internet access.
- `test-failover-failback.sh` — quick manual smoke test (stop Patroni on the leader, confirm
  promotion, restart it, confirm rejoin).
- `templates/*.tpl` — config templates (`etcd.conf`, `patroni.yml`, `haproxy.cfg`,
  `keepalived.conf`) filled in via `sed`/`python3` placeholder substitution (`{{NAME}}`,
  `{{IP}}`, etc.) in `deploy.sh`, then pushed to nodes.

Key behaviors to preserve when editing these scripts:
- `set -euo pipefail` is load-bearing; avoid piping into `head`/`tail` without accounting for
  `SIGPIPE` + `pipefail` killing the script (see the `KA_AUTH_PASS` generation comment in
  `deploy.sh` for the exact failure mode and the workaround used).
- Patroni's REST API binds to the node's own IP, not loopback — poll helpers (`wait_patroni_*`)
  curl `http://<node-ip>:8008/...`, not `localhost`.
- The script re-bootstrap-detects: if `/var/lib/etcd/member` already exists it skips
  etcd re-deploy/restart; if Patroni is already active on node1 it asks before restarting (a
  restart can trigger a live failover). Don't remove these guards.
- `patronictl switchover` needs both `--leader` and `--candidate` passed explicitly, otherwise it
  prompts interactively and hangs over non-interactive SSH.

Running/testing: there's no test suite for this half of the repo. Validate changes by reading
through the script logic and, when possible, dry-running against real or disposable VMs — there's
no way to unit test bash against a live 5-node etcd/Patroni bootstrap.

## ha-validate/

Python 3, no framework — plain scripts plus a small internal library. Dependencies:
`pip install -r requirements.txt` (PyYAML, paramiko, psycopg2-binary, openpyxl, reportlab).

### Running

```bash
cp config.example.yaml config.yaml   # edit node IPs, SSH key, DB creds, SLA targets
python ha_validate.py --config config.yaml --tests safe        # non-destructive only
python ha_validate.py --config config.yaml --tests all --confirm-destructive   # everything
python ha_validate.py --config config.yaml --tests connectivity,replication,security  # specific categories
```

No `pytest`/unit-test suite exists in this directory — `tests/t_*.py` are HA validation
*categories*, not unit tests, and every run is a live campaign against real nodes over
SSH/Postgres/HTTP. There is nothing here to run without a target cluster.

### Architecture

- `ha_validate.py` — CLI entry point and campaign orchestration (`run_campaign()`). Owns the
  ordering logic between categories, e.g. failback only runs after a failover category if the
  leader actually changed (checked by diffing `patroni.cluster_state()` before/after — a
  switchover that silently no-ops must not trigger a pointless failback wait).
- `lib/models.py` — shared result types. `TestRunContext` is threaded through every test module's
  `run(ctx)`; `ctx.new_result(name, category)` returns a `ResultBuilder` context manager that
  times itself and auto-records PASS/ERROR based on whether the `with` block raised (it swallows
  the exception itself — callers must check `r.status` afterward if they need to stop early, see
  `tests/t_planned_failover.py`). `CATEGORY_WEIGHTS` (must sum to 100) and `CRITICAL_CATEGORIES`
  drive `Campaign.readiness_score()`/`readiness_label()` — a FAIL in `data_integrity`,
  `unplanned_failover`, or `failback` caps overall readiness at `NOT READY` regardless of score.
- `lib/patroni.py` — queries cluster state via `patronictl ... list -f json` over SSH, plus direct
  REST calls to each node's Patroni API (bypassing SSH, to test the real network path). Polling
  helpers (`wait_for_new_leader`, `wait_for_role_state`) are used by every failover/failback test.
  Note: a healthy replica reports `State: "streaming"`, not `"running"` (that value is
  Leader-specific) — callers must check both.
- `lib/ssh_client.py` — thin paramiko wrapper (`SSHPool`), one cached connection per host.
- `lib/dbutil.py` — direct psycopg2 connections for data-integrity/performance checks.
- `tests/t_*.py` — one module per category, each exposing `run(ctx)` (some, like
  `t_failback.py`, also expose a targeted `run_for_host()` called directly by
  `ha_validate.py` after a failover). Non-destructive: `t_connectivity`, `t_security`,
  `t_replication`, `t_performance`, `t_planned_failover`, `t_failback`, `t_data_integrity`
  (runs inline inside the failover/failback tests, not standalone). Destructive (gated, see
  below): `t_unplanned_failover`, `t_disaster_recovery`. `t_rto_rpo` aggregates RTO/RPO from
  the other results into one SLA summary and must run last.
- `reporting/{json,html,excel,pdf}_report.py` — each takes a `Campaign` and an output path;
  `json_report` is the source of truth, the other three are generated from the same `Campaign`
  object independently.

### Extending

Add a check inside an existing category by adding a `with ctx.new_result(name, category):` block
in the relevant `tests/t_*.py`. Add a new category by creating `tests/t_<name>.py` with a
`run(ctx)` function and wiring it into `ha_validate.py` (`NON_DESTRUCTIVE`/`DESTRUCTIVE` lists,
`run_campaign()`, and `CATEGORY_WEIGHTS` in `lib/models.py`).

### Safety model

`unplanned_failover` and `disaster_recovery` stop real services on real nodes (`kill -9` postgres,
stop etcd+patroni on 2 of 4 nodes). They require **both** `tests.enable_destructive: true` in
config.yaml **and** `--confirm-destructive` on the command line — missing either blocks the
category with a clear message rather than silently downgrading or partially running. Never relax
this to a single gate.

## Documentation to read before touching the watcher node

`ha-validate/WATCHER-REPLACEMENT-GUIDE.md` is the manual step-by-step version of what
`manage-watcher.sh` automates. Editing config files and restarting etcd does **not** work the way
it looks like it should for replacing a dead/relocated watcher — real `etcdctl member
add`/`member remove` calls are required. Read it (or defer to `manage-watcher.sh`) before making
manual changes to the watcher.
