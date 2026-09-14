"""Category: performance - simple write/read latency percentiles, run before and after
failover so the campaign can compare (see reporting for the before/after diff)."""
import time
from lib import dbutil, patroni


def _run_write_bench(conn, iterations: int) -> list[float]:
    samples = []
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS ha_validate_perf (
                id BIGSERIAL PRIMARY KEY, val TEXT, ts TIMESTAMPTZ DEFAULT now()
            )
        """)
    conn.commit()
    for i in range(iterations):
        t0 = time.time()
        with conn.cursor() as cur:
            cur.execute("INSERT INTO ha_validate_perf (val) VALUES (%s)", (f"v{i}",))
        conn.commit()
        samples.append((time.time() - t0) * 1000.0)
    return samples


def _run_read_bench(conn, iterations: int) -> list[float]:
    samples = []
    for _ in range(iterations):
        t0 = time.time()
        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM ha_validate_perf")
            cur.fetchone()
        samples.append((time.time() - t0) * 1000.0)
    return samples


def run(ctx, label: str = "baseline"):
    cfg = ctx.config
    cluster = cfg["cluster"]
    db_cfg = cfg["database"]
    perf_cfg = cfg["tests"].get("performance", {})
    write_n = perf_cfg.get("write_iterations", 200)
    read_n = perf_cfg.get("read_iterations", 200)

    members = patroni.cluster_state(ctx.ssh, cluster["nodes"][0]["ip"], cluster["patroni_config_path"])
    leader = patroni.get_leader(members)
    if not leader:
        with ctx.new_result(f"Performance ({label}): no leader found", "performance") as r:
            raise RuntimeError("No current leader - cannot run performance benchmark")
        return

    conn = dbutil.connect(
        leader["Host"], cluster["pg_port"], db_cfg["dbname"], db_cfg["user"], db_cfg["password"],
        sslmode=db_cfg.get("sslmode"),
    )
    try:
        with ctx.new_result(f"Write latency ({label}), n={write_n}", "performance") as r:
            samples = _run_write_bench(conn, write_n)
            r.metrics = dbutil.latency_percentiles(samples)
            r.details = f"Against leader {leader['Host']}"

        with ctx.new_result(f"Read latency ({label}), n={read_n}", "performance") as r:
            samples = _run_read_bench(conn, read_n)
            r.metrics = dbutil.latency_percentiles(samples)
            r.details = f"Against leader {leader['Host']}"
    finally:
        conn.close()
