"""Category: connectivity - can we reach every node's Postgres port and REST API."""
from lib import dbutil, patroni


def run(ctx):
    cfg = ctx.config
    db_cfg = cfg["database"]
    cluster = cfg["cluster"]

    for node in cluster["nodes"]:
        with ctx.new_result(f"PG connect: {node['name']} ({node['ip']})", "connectivity") as r:
            conn = dbutil.connect(
                node["ip"], cluster["pg_port"], db_cfg["dbname"], db_cfg["user"], db_cfg["password"],
                sslmode=db_cfg.get("sslmode"),
            )
            try:
                latency = dbutil.ping_latency_ms(conn)
                in_recovery = dbutil.is_in_recovery(conn)
                r.metrics = {"latency_ms": round(latency, 2), "role": "replica" if in_recovery else "primary"}
                r.details = f"Connected OK, role={'replica' if in_recovery else 'primary'}"
                warn_ms = cfg["sla"].get("connectivity_latency_warn_ms", 50)
                r.set_sla(warn_ms, latency, unit="ms")
            finally:
                conn.close()

        with ctx.new_result(f"Patroni REST reachable: {node['name']}", "connectivity") as r:
            status, body = patroni.rest_get(node["ip"], "/health", port=cluster["patroni_rest_port"])
            r.metrics = {"http_status": status}
            r.details = body[:200]
            if status not in (200, 503):  # 503 is a valid "not currently healthy" answer, still reachable
                raise RuntimeError(f"REST API unreachable or unexpected status {status}")

    vip = cluster.get("vip")
    if vip:
        with ctx.new_result(f"VIP connect: {vip}:{cluster.get('vip_port', 5000)}", "connectivity") as r:
            conn = dbutil.connect(
                vip, cluster.get("vip_port", 5000), db_cfg["dbname"], db_cfg["user"], db_cfg["password"],
                sslmode=db_cfg.get("sslmode"),
            )
            try:
                latency = dbutil.ping_latency_ms(conn)
                in_recovery = dbutil.is_in_recovery(conn)
                r.metrics = {"latency_ms": round(latency, 2)}
                if in_recovery:
                    raise RuntimeError("VIP routed to a REPLICA, not the primary - HAProxy/keepalived misconfigured")
                r.details = "VIP correctly routes to primary"
            finally:
                conn.close()
