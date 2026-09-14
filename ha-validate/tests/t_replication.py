"""Category: replication - streaming state and lag for every replica, vs SLA thresholds."""
from lib import dbutil, patroni


def run(ctx):
    cfg = ctx.config
    cluster = cfg["cluster"]
    db_cfg = cfg["database"]
    ssh = ctx.ssh

    any_host = cluster["nodes"][0]["ip"]
    with ctx.new_result("Patroni cluster topology sane (1 leader, N replicas)", "replication") as r:
        members = patroni.cluster_state(ssh, any_host, cluster["patroni_config_path"])
        leaders = [m for m in members if m.get("Role") == "Leader"]
        r.metrics = {"member_count": len(members), "leader_count": len(leaders)}
        r.details = f"Members: {[(m['Member'], m['Role'], m['State']) for m in members]}"
        if len(leaders) != 1:
            raise RuntimeError(f"Expected exactly 1 leader, found {len(leaders)} - possible split-brain or cluster down")
        leader = leaders[0]

    leader_conn = dbutil.connect(
        leader["Host"], cluster["pg_port"], db_cfg["dbname"], db_cfg["user"], db_cfg["password"],
        sslmode=db_cfg.get("sslmode"),
    )
    try:
        with ctx.new_result("Replication slots active for all replicas", "replication") as r:
            lag_rows = dbutil.replication_lag_bytes(leader_conn)
            r.metrics = {"connected_replicas": len(lag_rows)}
            r.details = str(lag_rows)
            expected_replicas = len(cluster["nodes"]) - 1
            if len(lag_rows) < expected_replicas:
                raise RuntimeError(f"Expected {expected_replicas} streaming replicas, only {len(lag_rows)} connected")

        warn_mb = cfg["sla"]["replication_lag_warn_mb"]
        crit_mb = cfg["sla"]["replication_lag_crit_mb"]
        for row in lag_rows:
            name = row.get("application_name") or row.get("client_addr") or "unknown"
            with ctx.new_result(f"Replication lag: {name}", "replication") as r:
                lag_mb = round((row.get("lag_bytes") or 0) / (1024 * 1024), 3)
                r.metrics = {"lag_mb": lag_mb, "state": row.get("state")}
                r.set_sla(warn_mb, lag_mb, unit="MB")
                if lag_mb > crit_mb:
                    raise RuntimeError(f"Lag {lag_mb}MB exceeds critical threshold {crit_mb}MB")
                r.details = f"state={row.get('state')}, lag={lag_mb}MB"
    finally:
        leader_conn.close()
