"""Category: performance (SLA rollup) - aggregates RTO from the failover tests
that already ran and RPO from data-integrity results, into one compliance
summary. Must run AFTER planned/unplanned failover and data_integrity."""
from lib.models import Status


def run(ctx):
    cfg = ctx.config
    sla = cfg["sla"]

    rto_results = [r for r in ctx.results if r.category in ("planned_failover", "unplanned_failover") and r.sla_unit == "s" and "->" in r.details]
    with ctx.new_result("RTO compliance summary", "performance") as r:
        rtos = {rr.name: rr.sla_actual for rr in rto_results if rr.sla_actual is not None}
        r.metrics = {"rto_target_s": sla["rto_seconds"], "observed": rtos}
        worst = max(rtos.values()) if rtos else None
        if worst is None:
            r.details = "No RTO-measuring tests ran this campaign"
        else:
            r.set_sla(sla["rto_seconds"], worst, unit="s")
            r.details = f"Worst observed RTO: {round(worst, 2)}s (target: {sla['rto_seconds']}s)"

    integrity_results = [r for r in ctx.results if r.category == "data_integrity"]
    with ctx.new_result("RPO compliance summary (data loss check)", "performance") as r:
        any_loss = any(r2.status in (Status.FAIL, Status.ERROR) for r2 in integrity_results)
        r.metrics = {"rpo_target_s": sla["rpo_seconds"], "integrity_checks_run": len(integrity_results), "any_data_loss_detected": any_loss}
        if any_loss:
            raise RuntimeError("Data loss detected during this campaign - RPO target violated regardless of timing")
        if not integrity_results:
            r.details = "No data-integrity tests ran this campaign - RPO not evaluated"
        else:
            r.details = f"Zero data loss across {len(integrity_results)} integrity checks - RPO target ({sla['rpo_seconds']}s) satisfied"
