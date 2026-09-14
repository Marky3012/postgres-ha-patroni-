"""Category: data_integrity - shared helper used by planned/unplanned failover
tests to write marker rows before the event and verify them after."""
import time
import uuid
from lib import dbutil


def write_markers(cfg, leader_host: str, batch_label: str, count: int) -> tuple[str, list[str], float]:
    """Returns (batch_id, checksums_written, last_commit_timestamp)."""
    db_cfg = cfg["database"]
    cluster = cfg["cluster"]
    conn = dbutil.connect(
        leader_host, cluster["pg_port"], db_cfg["dbname"], db_cfg["user"], db_cfg["password"],
        sslmode=db_cfg.get("sslmode"),
    )
    try:
        dbutil.ensure_test_table(conn)
        batch_id = f"{batch_label}-{uuid.uuid4().hex[:8]}"
        checksums = dbutil.write_marker_rows(conn, batch_id, count)
        return batch_id, checksums, time.time()
    finally:
        conn.close()


def verify_markers(ctx, new_leader_host: str, batch_id: str, checksums: list[str], test_name: str):
    cfg = ctx.config
    db_cfg = cfg["database"]
    cluster = cfg["cluster"]
    with ctx.new_result(test_name, "data_integrity") as r:
        conn = dbutil.connect(
            new_leader_host, cluster["pg_port"], db_cfg["dbname"], db_cfg["user"], db_cfg["password"],
            sslmode=db_cfg.get("sslmode"),
        )
        try:
            result = dbutil.verify_marker_rows(conn, batch_id, checksums)
            r.metrics = result
            r.details = (
                f"{result['found_count']}/{result['expected_count']} committed rows found on {new_leader_host}"
            )
            if not result["all_present"]:
                raise RuntimeError(
                    f"DATA LOSS: {len(result['missing'])} committed rows missing after failover "
                    f"(batch {batch_id})"
                )
            if result["unexpected_extra"]:
                r.details += f" | WARNING: {len(result['unexpected_extra'])} unexpected extra rows found"
        finally:
            conn.close()
