"""Category: unplanned_failover - simulates a real crash by SIGKILLing postgres
and stopping patroni on the leader with no warning to Patroni. DESTRUCTIVE:
only runs when both config `enable_destructive` and CLI --confirm-destructive are set."""
import time
from lib import patroni
from lib.models import Status
from . import t_data_integrity


def run(ctx):
    cfg = ctx.config
    cluster = cfg["cluster"]
    ssh = ctx.ssh
    any_host = cluster["nodes"][0]["ip"]
    cfg_path = cluster["patroni_config_path"]

    members = patroni.cluster_state(ssh, any_host, cfg_path)
    leader = patroni.get_leader(members)
    if not leader:
        with ctx.new_result("Unplanned failover: precondition", "unplanned_failover") as r:
            raise RuntimeError("No leader found before test - cannot proceed")
        return
    old_leader_host = leader["Host"]
    old_leader_name = leader["Member"]

    batch_id, checksums, _ = t_data_integrity.write_markers(
        cfg, old_leader_host, "unplanned", cfg["tests"]["data_integrity"]["marker_rows_unplanned"]
    )

    with ctx.new_result(f"Simulated crash: kill -9 postgres + patroni on {old_leader_name}", "unplanned_failover") as r:
        t0 = time.time()
        # kill -9 the postmaster directly (not a graceful stop) then stop the
        # patroni service too, so it can't immediately restart postgres itself -
        # this is what an actual VM crash / OOM kill / power loss looks like.
        ssh.run(old_leader_host, "sudo pkill -9 -f 'postgres.*-D /var/lib/postgresql/17/main' || true")
        ssh.run(old_leader_host, "sudo systemctl stop patroni")
        new_leader = patroni.wait_for_new_leader(ssh, any_host, old_leader_host, timeout_s=cfg["sla"]["rto_seconds"] * 3)
        rto = time.time() - t0
        r.metrics = {"old_leader": old_leader_name, "new_leader": new_leader["Member"] if new_leader else None}
        r.set_sla(cfg["sla"]["rto_seconds"], rto, unit="s")
        if not new_leader:
            raise RuntimeError(
                f"No new leader elected within {cfg['sla']['rto_seconds'] * 3}s of simulated crash - "
                "cluster may be stuck without quorum, check manually before continuing"
            )
        r.details = f"{old_leader_name} crashed -> {new_leader['Member']} elected in {round(rto, 2)}s"
        new_leader_host = new_leader["Host"]
        new_leader_name = new_leader["Member"]

    if r.status in (Status.ERROR, Status.FAIL):
        return

    t_data_integrity.verify_markers(
        ctx, new_leader_host, batch_id, checksums,
        f"Data integrity after unplanned failover ({old_leader_name} crash -> {new_leader_name})",
    )

    with ctx.new_result("Cluster quorum intact post-crash (no split-brain)", "unplanned_failover") as r:
        members_after = patroni.cluster_state(ssh, new_leader_host, cfg_path)
        leaders_after = [m for m in members_after if m.get("Role") == "Leader"]
        r.metrics = {"leader_count": len(leaders_after)}
        if len(leaders_after) != 1:
            raise RuntimeError(f"Expected exactly 1 leader after crash, found {len(leaders_after)} - SPLIT BRAIN")
        r.details = f"Single leader confirmed: {leaders_after[0]['Member']}"
