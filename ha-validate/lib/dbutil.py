"""Postgres connection, latency, replication-lag and data-integrity helpers."""
from __future__ import annotations
import time
import uuid
import statistics
import psycopg2


def connect(host: str, port: int, dbname: str, user: str, password: str, connect_timeout: int = 5, sslmode: str | None = None):
    kwargs = dict(host=host, port=port, dbname=dbname, user=user, password=password, connect_timeout=connect_timeout)
    if sslmode:
        kwargs["sslmode"] = sslmode
    return psycopg2.connect(**kwargs)


def ping_latency_ms(conn) -> float:
    t0 = time.time()
    with conn.cursor() as cur:
        cur.execute("SELECT 1")
        cur.fetchone()
    return (time.time() - t0) * 1000.0


def is_in_recovery(conn) -> bool:
    with conn.cursor() as cur:
        cur.execute("SELECT pg_is_in_recovery()")
        return bool(cur.fetchone()[0])


def replication_lag_bytes(leader_conn) -> list[dict]:
    """Queries pg_stat_replication on the leader for each connected replica's lag."""
    with leader_conn.cursor() as cur:
        cur.execute("""
            SELECT application_name, client_addr, state,
                   pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
            FROM pg_stat_replication
        """)
        cols = [d.name for d in cur.description]
        return [dict(zip(cols, row)) for row in cur.fetchall()]


def ensure_test_table(conn):
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS ha_validate_integrity (
                id BIGSERIAL PRIMARY KEY,
                batch_id TEXT NOT NULL,
                seq INT NOT NULL,
                payload TEXT NOT NULL,
                written_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        """)
    conn.commit()


def write_marker_rows(conn, batch_id: str, count: int) -> list[str]:
    """Writes `count` rows with a unique payload each, commits after each row
    (so we know exactly how many were durably committed if a failover happens
    mid-write), and returns the list of payload checksums written."""
    checksums = []
    with conn.cursor() as cur:
        for i in range(count):
            payload = str(uuid.uuid4())
            cur.execute(
                "INSERT INTO ha_validate_integrity (batch_id, seq, payload) VALUES (%s, %s, %s)",
                (batch_id, i, payload),
            )
            conn.commit()
            checksums.append(payload)
    return checksums


def verify_marker_rows(conn, batch_id: str, expected_checksums: list[str]) -> dict:
    with conn.cursor() as cur:
        cur.execute("SELECT payload FROM ha_validate_integrity WHERE batch_id = %s", (batch_id,))
        found = {row[0] for row in cur.fetchall()}
    expected = set(expected_checksums)
    return {
        "expected_count": len(expected),
        "found_count": len(found),
        "missing": sorted(expected - found),
        "unexpected_extra": sorted(found - expected),
        "all_present": expected.issubset(found),
    }


def latency_percentiles(samples_ms: list[float]) -> dict:
    if not samples_ms:
        return {"p50": None, "p95": None, "p99": None, "max": None, "avg": None}
    s = sorted(samples_ms)
    def pct(p):
        idx = min(len(s) - 1, int(len(s) * p))
        return round(s[idx], 2)
    return {
        "p50": pct(0.50), "p95": pct(0.95), "p99": pct(0.99),
        "max": round(max(s), 2), "avg": round(statistics.mean(s), 2),
    }
