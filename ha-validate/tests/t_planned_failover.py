"""Category: planned_failover - graceful `patronictl switchover`. Safe to run on
a live cluster: Patroni drains/coordinates this, it's not a simulated crash."""
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
        with ctx.new_result("Planned failover: precondition", "planned_failover") as r:
            raise RuntimeError("No leader found before test - cannot proceed")
        return
    old_leader_host = leader["Host"]
    old_leader_name = leader["Member"]
    candidates = [m["Member"] for m in members if m["Host"] != old_leader_host]
    if not candidates:
        with ctx.new_result("Planned failover: precondition", "planned_failover") as r:
            raise RuntimeError("No replica available to switch over to")
        return
    candidate = candidates[0]

    batch_id, checksums, _ = t_data_integrity.write_markers(
        cfg, old_leader_host, "planned", cfg["tests"]["data_integrity"]["marker_rows_planned"]
    )

    with ctx.new_result(f"Planned switchover: {old_leader_name} -> {candidate}", "planned_failover") as r:
        t0 = time.time()
        # explicit --leader and --candidate: without both, patronictl prompts
        # interactively, which hangs forever over a non-interactive SSH exec.
        # NOTE: the flag is --leader, not --master (older Patroni docs/blogs
        # use --master; current patronictl rejects it with "no such option").
        ssh.run_ok(
            old_leader_host,
            f"sudo -u postgres patronictl -c {cfg_path} switchover --leader {old_leader_name} --candidate {candidate} --force",
            timeout=60,
        )
        new_leader = patroni.wait_for_new_leader(ssh, any_host, old_leader_host, timeout_s=cfg["sla"]["rto_seconds"] * 3)
        rto = time.time() - t0
        r.metrics = {"old_leader": old_leader_name, "new_leader": new_leader["Member"] if new_leader else None}
        r.set_sla(cfg["sla"]["rto_seconds"], rto, unit="s")
        if not new_leader:
            raise RuntimeError(f"No new leader elected within {cfg['sla']['rto_seconds'] * 3}s of switchover")
        r.details = f"{old_leader_name} -> {new_leader['Member']} in {round(rto, 2)}s"
        new_leader_host = new_leader["Host"]
        new_leader_name = new_leader["Member"]

    # the `with` block above swallows its own exception to keep the campaign
    # going (that's ResultBuilder's job) - but if it failed, there IS no new
    # leader to check data integrity or rejoin against, so stop here instead
    # of using unset variables.
    if r.status in (Status.ERROR, Status.FAIL):
        return

    t_data_integrity.verify_markers(
        ctx, new_leader_host, batch_id, checksums,
        f"Data integrity after planned switchover ({old_leader_name} -> {new_leader_name})",
    )

    with ctx.new_result(f"Old leader ({old_leader_name}) rejoins as healthy replica", "planned_failover") as r:
        # cross-site (DC<->DR) rejoin catch-up is inherently slower than
        # same-site - use the configured rejoin budget, not a fixed RTO-scale number
        rejoin_timeout = cfg["sla"].get("rejoin_timeout_seconds", 300)
        ok = patroni.wait_for_role_state(ssh, any_host, old_leader_host, "Replica", {"streaming", "running"}, timeout_s=rejoin_timeout)
        r.metrics = {"rejoined": ok, "timeout_used_s": rejoin_timeout}
        if not ok:
            raise RuntimeError(f"{old_leader_name} did not rejoin as a running replica within {rejoin_timeout}s")
        r.details = f"{old_leader_name} confirmed running as replica"
