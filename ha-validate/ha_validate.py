#!/usr/bin/env python3
"""End-to-end HA validation campaign runner.

Usage:
  python ha_validate.py --config config.yaml [--tests all] [--confirm-destructive]
  python ha_validate.py --config config.yaml --tests connectivity,replication,security

Non-destructive categories (safe on a live cluster, run by default):
  connectivity, replication, security, performance, planned_failover, failback, data_integrity

Destructive categories (stop real services on real nodes - require BOTH
config `tests.enable_destructive: true` AND --confirm-destructive):
  unplanned_failover, disaster_recovery
"""
import argparse
import os
import sys
import time

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lib.models import TestRunContext, Campaign
from lib.ssh_client import SSHPool
from lib import patroni as patroni_lib
from tests import (
    t_connectivity, t_security, t_replication, t_performance,
    t_planned_failover, t_unplanned_failover, t_failback,
    t_disaster_recovery, t_rto_rpo,
)
from reporting import json_report, html_report, excel_report, pdf_report

NON_DESTRUCTIVE = ["connectivity", "security", "replication", "performance", "planned_failover", "failback", "data_integrity"]
DESTRUCTIVE = ["unplanned_failover", "disaster_recovery"]
ALL_CATEGORIES = NON_DESTRUCTIVE + DESTRUCTIVE


def load_config(path: str) -> dict:
    with open(path) as f:
        cfg = yaml.safe_load(f)
    return cfg


def run_campaign(cfg: dict, selected: list[str], allow_destructive: bool) -> Campaign:
    ctx = TestRunContext(cfg)
    ctx.ssh = SSHPool(cfg["ssh"]["user"], cfg["ssh"]["key_path"], cfg["ssh"].get("port", 22))

    started = time.time()
    print(f"=== HA Validation Campaign started {time.strftime('%Y-%m-%d %H:%M:%S')} ===")

    def maybe(cat_name, fn, *args, **kwargs):
        if cat_name not in selected:
            print(f"  [skip] {cat_name}")
            return
        print(f"  [run]  {cat_name}")
        try:
            fn(ctx, *args, **kwargs)
        except Exception as e:
            print(f"  [!!]   {cat_name} raised outside a result block: {e}")

    # --- non-destructive baseline ---
    maybe("connectivity", t_connectivity.run)
    maybe("security", t_security.run)
    maybe("replication", t_replication.run)
    maybe("performance", t_performance.run, label="baseline")

    # --- planned failover + failback (data_integrity runs inline inside these) ---
    if "planned_failover" in selected:
        print("  [run]  planned_failover")
        old_leader = None
        try:
            members_before = patroni_lib.cluster_state(
                ctx.ssh, cfg["cluster"]["nodes"][0]["ip"], cfg["cluster"]["patroni_config_path"]
            )
            leader = next((m for m in members_before if m.get("Role") == "Leader"), None)
            old_leader = leader["Host"] if leader else None
        except Exception:
            pass
        t_planned_failover.run(ctx)
        # Only attempt failback if the leader ACTUALLY changed - if the
        # switchover itself failed (bad flag, timeout, etc.), old_leader is
        # still the leader and "restarting" an already-running leader then
        # waiting for it to show up as a replica just burns minutes waiting
        # for something that was never going to happen.
        leader_changed = False
        if old_leader:
            try:
                members_after = patroni_lib.cluster_state(
                    ctx.ssh, cfg["cluster"]["nodes"][0]["ip"], cfg["cluster"]["patroni_config_path"]
                )
                new_leader_after = next((m for m in members_after if m.get("Role") == "Leader"), None)
                leader_changed = bool(new_leader_after and new_leader_after["Host"] != old_leader)
            except Exception:
                pass
        if old_leader and leader_changed and "failback" in selected:
            print("  [run]  failback (planned)")
            t_failback.run_for_host(ctx, old_leader, "old-leader-after-planned-switchover")
        elif old_leader and not leader_changed:
            print("  [skip] failback (planned) - leader never actually changed, switchover did not succeed")
    else:
        print("  [skip] planned_failover")

    # --- destructive: gated ---
    if "unplanned_failover" in selected:
        if not allow_destructive:
            print("  [BLOCKED] unplanned_failover requested but destructive tests not confirmed (need config + --confirm-destructive)")
        else:
            print("  [run]  unplanned_failover (DESTRUCTIVE)")
            old_leader = None
            try:
                members_before = patroni_lib.cluster_state(
                    ctx.ssh, cfg["cluster"]["nodes"][0]["ip"], cfg["cluster"]["patroni_config_path"]
                )
                leader = next((m for m in members_before if m.get("Role") == "Leader"), None)
                old_leader = leader["Host"] if leader else None
            except Exception:
                pass
            t_unplanned_failover.run(ctx)
            leader_changed = False
            if old_leader:
                try:
                    members_after = patroni_lib.cluster_state(
                        ctx.ssh, cfg["cluster"]["nodes"][0]["ip"], cfg["cluster"]["patroni_config_path"]
                    )
                    new_leader_after = next((m for m in members_after if m.get("Role") == "Leader"), None)
                    leader_changed = bool(new_leader_after and new_leader_after["Host"] != old_leader)
                except Exception:
                    pass
            if old_leader and leader_changed and "failback" in selected:
                print("  [run]  failback (unplanned)")
                t_failback.run_for_host(ctx, old_leader, "crashed-node-after-unplanned-failover")
            elif old_leader and not leader_changed:
                print("  [skip] failback (unplanned) - leader never actually changed, crash sim did not produce a new leader")
    else:
        print("  [skip] unplanned_failover")

    if "disaster_recovery" in selected:
        if not allow_destructive:
            print("  [BLOCKED] disaster_recovery requested but destructive tests not confirmed (need config + --confirm-destructive)")
        else:
            print("  [run]  disaster_recovery (DESTRUCTIVE)")
            t_disaster_recovery.run(ctx)
    else:
        print("  [skip] disaster_recovery")

    maybe("performance", t_performance.run, label="post-failover")
    maybe("rto_rpo", t_rto_rpo.run)

    ctx.ssh.close_all()
    ended = time.time()

    campaign = Campaign(
        started_at=started, ended_at=ended, results=ctx.results,
        config_summary={"scope": cfg["cluster"]["scope"], "nodes": [n["ip"] for n in cfg["cluster"]["nodes"]]},
    )
    print(f"=== Campaign finished in {round(ended - started, 1)}s - {len(ctx.results)} tests run ===")
    return campaign


def generate_reports(campaign: Campaign, out_dir: str):
    os.makedirs(out_dir, exist_ok=True)
    paths = {}
    paths["json"] = json_report.generate(campaign, os.path.join(out_dir, "ha_report.json"))
    paths["html"] = html_report.generate(campaign, os.path.join(out_dir, "ha_report.html"))
    paths["xlsx"] = excel_report.generate(campaign, os.path.join(out_dir, "ha_report.xlsx"))
    paths["pdf"] = pdf_report.generate(campaign, os.path.join(out_dir, "ha_report.pdf"))
    return paths


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True, help="Path to config.yaml")
    ap.add_argument("--tests", default="all", help="Comma-separated categories, or 'all' / 'safe' (non-destructive only)")
    ap.add_argument("--confirm-destructive", action="store_true", help="Required (with config tests.enable_destructive: true) to run unplanned_failover / disaster_recovery")
    ap.add_argument("--output-dir", default=None, help="Override output_dir from config")
    args = ap.parse_args()

    cfg = load_config(args.config)
    out_dir = args.output_dir or cfg.get("output_dir", "./results")

    if args.tests == "all":
        selected = ALL_CATEGORIES
    elif args.tests == "safe":
        selected = NON_DESTRUCTIVE
    else:
        selected = [t.strip() for t in args.tests.split(",")]

    allow_destructive = bool(cfg["tests"].get("enable_destructive")) and args.confirm_destructive
    if any(c in DESTRUCTIVE for c in selected) and not allow_destructive:
        print("NOTE: destructive categories were requested but will be BLOCKED unless")
        print("      config has tests.enable_destructive: true AND --confirm-destructive is passed.")

    campaign = run_campaign(cfg, selected, allow_destructive)
    paths = generate_reports(campaign, out_dir)

    summary = campaign.summary()
    print()
    print(f"HA Readiness: {summary['readiness_label']}  (score: {summary['readiness_score']}%)")
    print(f"Tests: {summary['total_tests']} total, {summary['counts']['PASS']} passed, "
          f"{summary['counts']['FAIL'] + summary['counts']['ERROR']} failed, {summary['counts']['WARN']} warnings")
    print("Reports:")
    for fmt, p in paths.items():
        print(f"  {fmt}: {p}")

    sys.exit(0 if summary["readiness_label"] != "NOT READY" else 1)


if __name__ == "__main__":
    main()
