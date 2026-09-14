"""Category: disaster_recovery - comprehensive multi-node-down scenarios.
DESTRUCTIVE - confirmation-gated (see ha_validate.py's --confirm-destructive).

Auto-detects physical sites from each node's /24 subnet (matches a DC/DR-style
split deployment like dc=172.21.1.x / dr=172.21.5.x) and runs every scenario
that's actually meaningful for THIS cluster's real topology and quorum math,
not just an arbitrary fixed node count:

  1. Arbitrary 2-node loss (baseline quorum sanity: 2 of 5 down, 3 remain)
  2. Leader-inclusive 2-node loss (the leader is one of the 2 that go down)
  3. Full site loss, once per site (skipped for a site that IS the whole
     cluster) - asserts the CORRECT outcome for that site's size: if enough
     members survive elsewhere for quorum, a leader must still be reachable;
     if not, NO leader must appear anywhere (that's the safety property
     working, not a failure to report as one)
  4. Watcher-only loss - confirms the 4 PG nodes are completely unaffected
  5. Explicit quorum-loss safety test - stops exactly enough members (any 3
     of 5) to go below quorum and asserts no leader appears anywhere for a
     sustained window, i.e. proves split-brain protection actually holds,
     independent of whatever site layout this cluster happens to have

Every scenario restores its own state (starts etcd, then patroni, waits for
full rejoin) before the next scenario begins, so failures don't compound.
"""
import time
from lib import patroni


def _site_of(ip: str) -> str:
    """Groups by /24 - matches a DC/DR-style subnet split without needing
    the user to declare site names anywhere in config."""
    return ".".join(ip.split(".")[:3])


def _all_members(cfg) -> list[dict]:
    members = [{"name": n["name"], "host": n["ip"], "is_pg": True} for n in cfg["cluster"]["nodes"]]
    members.append({"name": "watcher", "host": cfg["cluster"]["watcher_ip"], "is_pg": False})
    return members


def _stop_members(ssh, members):
    for m in members:
        if m["is_pg"]:
            ssh.run(m["host"], "sudo systemctl stop patroni")
        ssh.run(m["host"], "sudo systemctl stop etcd")


def _recover_members(ctx, members, label):
    ssh = ctx.ssh
    cfg = ctx.config
    with ctx.new_result(f"Recover after: {label}", "disaster_recovery") as r:
        for m in members:
            ssh.run(m["host"], "sudo systemctl start etcd")
        time.sleep(5)
        for m in members:
            if m["is_pg"]:
                ssh.run(m["host"], "sudo systemctl start patroni")
        rejoin_timeout = cfg["sla"].get("rejoin_timeout_seconds", 300)
        pg_members = [m for m in members if m["is_pg"]]
        results = {}
        for m in pg_members:
            results[m["name"]] = _wait_running(ctx, m["host"], rejoin_timeout)
        r.metrics = {"rejoined": results, "timeout_used_s": rejoin_timeout}
        if pg_members and not all(results.values()):
            raise RuntimeError(f"Not all nodes recovered after {label}: {results}")
        r.details = f"All members restarted and confirmed running after {label}"


def _wait_running(ctx, host, timeout_s) -> bool:
    """True once `host` shows up in cluster_state as healthy - either State
    "running" (what a Leader reports) or "streaming" (what a healthy Replica
    reports; Replicas never report "running", so checking for that alone
    would time out even on a fully healthy node). Either ok post-recovery -
    what matters is that it's alive and participating, not which role."""
    ssh = ctx.ssh
    cfg = ctx.config
    any_host = cfg["cluster"]["nodes"][0]["ip"]
    cfg_path = cfg["cluster"]["patroni_config_path"]
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            members = patroni.cluster_state(ssh, any_host, cfg_path)
            m = patroni.get_member(members, host)
            if m and m.get("State") in ("running", "streaming"):
                return True
        except Exception:
            pass
        time.sleep(5)
    return False


def _wait_for_any_leader(ctx, survivor_pg_hosts, timeout_s):
    """Polls surviving PG nodes for any of them to report a Leader (new or
    unchanged). Returns the leader member dict, or None on timeout."""
    ssh = ctx.ssh
    cfg_path = ctx.config["cluster"]["patroni_config_path"]
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        for host in survivor_pg_hosts:
            try:
                members = patroni.cluster_state(ssh, host, cfg_path)
                leader = patroni.get_leader(members)
                if leader:
                    return leader
            except Exception:
                pass  # expected while things are still settling
        time.sleep(3)
    return None


def _check_no_split_brain(ctx, survivor_pg_hosts, duration_s=30, poll_s=5):
    """Polls surviving PG nodes for `duration_s` and fails immediately if ANY
    of them ever reports a Leader - that would mean the cluster is acting
    without quorum, a real split-brain risk. An exception/timeout querying a
    minority-side node is EXPECTED (its local etcd can't even serve reads
    without quorum) and treated as consistent with the safety property, not
    as a test failure."""
    ssh = ctx.ssh
    cfg_path = ctx.config["cluster"]["patroni_config_path"]
    deadline = time.time() + duration_s
    while time.time() < deadline:
        for host in survivor_pg_hosts:
            try:
                members = patroni.cluster_state(ssh, host, cfg_path)
                leader = patroni.get_leader(members)
                if leader:
                    return False, f"Leader {leader['Member']} present WITHOUT quorum - split-brain risk"
            except Exception:
                pass
        time.sleep(poll_s)
    return True, "No leader observed anywhere during the quorum-loss window, as required"


def run(ctx):
    cfg = ctx.config
    cluster = cfg["cluster"]
    ssh = ctx.ssh
    any_host = cluster["nodes"][0]["ip"]
    cfg_path = cluster["patroni_config_path"]
    sla = cfg["sla"]

    all_members = _all_members(cfg)
    total = len(all_members)
    quorum = total // 2 + 1
    pg_hosts = [m["host"] for m in all_members if m["is_pg"]]

    def current_leader():
        members = patroni.cluster_state(ssh, any_host, cfg_path)
        return patroni.get_leader(members)

    # -----------------------------------------------------------------
    # Scenario 1: arbitrary 2-node loss (baseline)
    # -----------------------------------------------------------------
    leader = current_leader()
    if not leader:
        with ctx.new_result("DR test: precondition", "disaster_recovery") as r:
            raise RuntimeError("No leader found before test - cannot proceed")
        return

    victims = [m for m in all_members if m["is_pg"] and m["host"] != leader["Host"]][:2]
    with ctx.new_result(f"Scenario 1 - arbitrary 2-node loss: {[v['name'] for v in victims]}", "disaster_recovery") as r:
        _stop_members(ssh, victims)
        survivors = [h for h in pg_hosts if h not in [v["host"] for v in victims]]
        still_leader = _wait_for_any_leader(ctx, survivors, timeout_s=sla["rto_seconds"] * 3)
        r.metrics = {"stopped": [v["name"] for v in victims], "leader_survived": bool(still_leader)}
        if not still_leader:
            raise RuntimeError(f"No leader reachable after losing {[v['name'] for v in victims]} - quorum design failed for a 2-of-5 loss")
        r.details = f"Leader {still_leader['Member']} reachable with {total - len(victims)} of {total} members alive"
    _recover_members(ctx, victims, "Scenario 1 (arbitrary 2-node loss)")

    # -----------------------------------------------------------------
    # Scenario 2: leader-inclusive 2-node loss
    # -----------------------------------------------------------------
    leader = current_leader()
    if leader:
        other = next((m for m in all_members if m["is_pg"] and m["host"] != leader["Host"]), None)
        leader_member = next(m for m in all_members if m["host"] == leader["Host"])
        victims2 = [leader_member] + ([other] if other else [])
        with ctx.new_result(f"Scenario 2 - leader-inclusive loss: {[v['name'] for v in victims2]}", "disaster_recovery") as r:
            old_leader_host = leader["Host"]
            _stop_members(ssh, victims2)
            survivors = [h for h in pg_hosts if h not in [v["host"] for v in victims2]]
            new_leader = _wait_for_any_leader(ctx, survivors, timeout_s=sla["rto_seconds"] * 3)
            r.metrics = {"old_leader": leader["Member"], "stopped": [v["name"] for v in victims2], "new_leader_elected": bool(new_leader)}
            if not new_leader:
                raise RuntimeError(f"No new leader elected after losing the leader + {[v['name'] for v in victims2[1:]]}")
            if new_leader["Host"] == old_leader_host:
                raise RuntimeError("Reported leader is still the one that was just stopped - stale read, not a real election")
            r.details = f"New leader {new_leader['Member']} elected after old leader ({leader['Member']}) went down"
        _recover_members(ctx, victims2, "Scenario 2 (leader-inclusive loss)")
    else:
        with ctx.new_result("Scenario 2 - leader-inclusive loss", "disaster_recovery") as r:
            raise RuntimeError("No leader found before scenario 2 - skipping")

    # -----------------------------------------------------------------
    # Scenario 3: full site loss, once per site (skip a site that IS everything)
    # -----------------------------------------------------------------
    sites: dict[str, list[dict]] = {}
    for m in all_members:
        sites.setdefault(_site_of(m["host"]), []).append(m)

    if len(sites) < 2:
        with ctx.new_result("Scenario 3 - site loss", "disaster_recovery") as r:
            r.details = "All nodes are in a single /24 - no distinct sites to test, skipping meaningfully"
    else:
        for site_key, site_members in sites.items():
            remaining = total - len(site_members)
            expect_quorum = remaining >= quorum
            label = f"Scenario 3 - full site loss ({site_key}, {len(site_members)} members: {[m['name'] for m in site_members]})"
            with ctx.new_result(label, "disaster_recovery") as r:
                _stop_members(ssh, site_members)
                survivor_pg_hosts = [m["host"] for m in all_members if m["is_pg"] and m not in site_members]
                r.metrics = {"site": site_key, "members_stopped": [m["name"] for m in site_members], "remaining_total": remaining, "quorum_required": quorum, "expected_quorum_held": expect_quorum}
                if expect_quorum:
                    if not survivor_pg_hosts:
                        raise RuntimeError(f"Quorum math says survivable ({remaining} of {total} >= {quorum}) but no PG nodes remain to verify - check topology")
                    lead = _wait_for_any_leader(ctx, survivor_pg_hosts, timeout_s=sla["rto_seconds"] * 3)
                    if not lead:
                        raise RuntimeError(f"Quorum math said this site loss ({len(site_members)} members) should be survivable ({remaining}/{total} >= {quorum}) but NO leader became reachable - quorum design broken for this topology")
                    r.details = f"Leader {lead['Member']} reachable after losing site {site_key} ({remaining}/{total} members remain, quorum={quorum}) - as expected"
                else:
                    if not survivor_pg_hosts:
                        r.details = f"Losing site {site_key} takes down all PG nodes ({remaining}/{total} total members remain) - no writes possible by definition, correctly unsurvivable"
                    else:
                        ok, msg = _check_no_split_brain(ctx, survivor_pg_hosts, duration_s=30)
                        if not ok:
                            raise RuntimeError(f"Losing site {site_key} should break quorum ({remaining}/{total} < {quorum}) but: {msg}")
                        r.details = f"Correctly NO leader reachable after losing site {site_key} ({remaining}/{total} members remain, below quorum={quorum}) - safety property held, but this also means THIS CLUSTER CANNOT SURVIVE losing {site_key}"
            _recover_members(ctx, site_members, f"Scenario 3 (site {site_key} loss)")

    # -----------------------------------------------------------------
    # Scenario 4: watcher-only loss
    # -----------------------------------------------------------------
    watcher_member = next(m for m in all_members if not m["is_pg"])
    with ctx.new_result(f"Scenario 4 - watcher-only loss ({watcher_member['host']})", "disaster_recovery") as r:
        ssh.run(watcher_member["host"], "sudo systemctl stop etcd")
        time.sleep(5)
        members = patroni.cluster_state(ssh, any_host, cfg_path)
        leaders = [m for m in members if m.get("Role") == "Leader"]
        replicas_running = [m for m in members if m.get("Role") == "Replica" and m.get("State") == "streaming"]
        r.metrics = {"leader_count": len(leaders), "streaming_replicas": len(replicas_running), "total_pg_members": len(members)}
        if len(leaders) != 1 or len(replicas_running) != len(members) - 1:
            raise RuntimeError(f"PG cluster affected by watcher loss alone - expected 1 leader + {len(members)-1} streaming replicas, got {len(leaders)} leader(s) + {len(replicas_running)} streaming replica(s)")
        r.details = "All 4 PG nodes fully unaffected by watcher-only loss, as expected (4 of 5 members still well above quorum)"
    _recover_members(ctx, [watcher_member], "Scenario 4 (watcher-only loss)")

    # -----------------------------------------------------------------
    # Scenario 5: explicit quorum-loss safety test (any 3 of 5, regardless of site)
    # -----------------------------------------------------------------
    below_quorum_count = total - quorum + 1  # smallest loss that breaks quorum
    quorum_victims = all_members[:below_quorum_count]
    label = f"Scenario 5 - quorum-loss safety test ({below_quorum_count} of {total} members: {[m['name'] for m in quorum_victims]})"
    with ctx.new_result(label, "disaster_recovery") as r:
        _stop_members(ssh, quorum_victims)
        survivor_pg_hosts = [m["host"] for m in all_members if m["is_pg"] and m not in quorum_victims]
        r.metrics = {"stopped": [m["name"] for m in quorum_victims], "quorum_required": quorum, "remaining_total": total - below_quorum_count}
        if not survivor_pg_hosts:
            r.details = "This quorum-breaking combination also removes all PG nodes - no leader possible by definition"
        else:
            ok, msg = _check_no_split_brain(ctx, survivor_pg_hosts, duration_s=30)
            if not ok:
                raise RuntimeError(f"Quorum-loss safety violated: {msg}")
            r.details = f"Confirmed: no leader anywhere while below quorum ({total - below_quorum_count}/{total} < {quorum}) - split-brain protection is working"
    _recover_members(ctx, quorum_victims, "Scenario 5 (quorum-loss safety test)")
