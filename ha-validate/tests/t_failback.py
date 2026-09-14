"""Category: failback - brings the previously-demoted/crashed node back and
confirms it rejoins cleanly as a replica with lag converging to near-zero.
Runs after planned_failover and (if enabled) unplanned_failover."""
import time
from lib import patroni, dbutil


def run_for_host(ctx, host: str, host_name: str):
    cfg = ctx.config
    cluster = cfg["cluster"]
    db_cfg = cfg["database"]
    ssh = ctx.ssh
    any_host = cluster["nodes"][0]["ip"]
    cfg_path = cluster["patroni_config_path"]

    with ctx.new_result(f"Failback: restart patroni on {host_name}", "failback") as r:
        t0 = time.time()
        # cross-site (DC<->DR) rejoin catch-up is inherently slower than
        # same-site - use the configured rejoin budget, not a fixed number
        rejoin_timeout = cfg["sla"].get("rejoin_timeout_seconds", 300)
        # "restart", not "start": after a PLANNED switchover the demoted
        # node's patroni service never stopped, so "start" on an already-
        # active unit is a no-op and never actually gives it a fresh attempt
        # at rejoining. "restart" works correctly in both the planned
        # (still-running) and unplanned (genuinely stopped) cases.
        ssh.run_ok(host, "sudo systemctl restart patroni")
        ok = patroni.wait_for_role_state(ssh, any_host, host, "Replica", {"streaming", "running"}, timeout_s=rejoin_timeout)
        elapsed = time.time() - t0
        r.metrics = {"rejoin_time_s": round(elapsed, 2), "timeout_used_s": rejoin_timeout}
        r.set_sla(rejoin_timeout, elapsed, unit="s")
        if not ok:
            raise RuntimeError(f"{host_name} did not rejoin as running replica within {rejoin_timeout}s")
        r.details = f"{host_name} rejoined as replica in {round(elapsed, 2)}s"

    with ctx.new_result(f"Failback: {host_name} lag converges to near-zero", "failback") as r:
        members = patroni.cluster_state(ssh, any_host, cfg_path)
        leader = patroni.get_leader(members)
        if not leader:
            raise RuntimeError("No leader found while checking failback lag convergence")
        leader_conn = dbutil.connect(
            leader["Host"], cluster["pg_port"], db_cfg["dbname"], db_cfg["user"], db_cfg["password"],
            sslmode=db_cfg.get("sslmode"),
        )
        try:
            lag_check_timeout = cfg["sla"].get("lag_convergence_timeout_seconds", 60)
            deadline = time.time() + lag_check_timeout
            lag_mb = None
            while time.time() < deadline:
                rows = dbutil.replication_lag_bytes(leader_conn)
                match = next((row for row in rows if row.get("client_addr") == host), None)
                if match:
                    lag_mb = round((match.get("lag_bytes") or 0) / (1024 * 1024), 3)
                    if lag_mb <= cfg["sla"]["replication_lag_warn_mb"]:
                        break
                time.sleep(3)
            r.metrics = {"final_lag_mb": lag_mb}
            if lag_mb is None:
                raise RuntimeError(f"{host_name} never appeared in pg_stat_replication on the leader within {lag_check_timeout}s")
            r.set_sla(cfg["sla"]["replication_lag_warn_mb"], lag_mb, unit="MB")
            r.details = f"{host_name} lag converged to {lag_mb}MB"
        finally:
            leader_conn.close()
