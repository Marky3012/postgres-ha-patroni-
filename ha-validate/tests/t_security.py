"""Category: security - config-level checks that don't require breaking anything."""
import socket
from lib.models import Status


def _port_open(host: str, port: int, timeout: float = 3.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False


def run(ctx):
    cfg = ctx.config
    cluster = cfg["cluster"]
    ssh = ctx.ssh

    for node in cluster["nodes"]:
        with ctx.new_result(f"pg_hba.conf not wide-open: {node['name']}", "security") as r:
            # patroni.yml's pg_hba is a YAML list ("    - host ... md5"), not
            # bare lines starting with "host" - the old pattern never matched
            # anything and passed vacuously every time. Match the list-item form.
            code, out, err = ssh.run(
                node["ip"],
                r"sudo grep -E '^\s*-\s*(host|hostssl)\b' /etc/patroni/patroni.yml || true",
                timeout=15,
            )
            r.details = out.strip() or "(no pg_hba lines found - check patroni_config_path in config.yaml)"
            if not out.strip():
                raise RuntimeError("No pg_hba lines matched - config path or format assumption is wrong, this check did not actually run")
            if "0.0.0.0/0" in out:
                raise RuntimeError("pg_hba allows 0.0.0.0/0 - unrestricted client access")

        with ctx.new_result(f"Patroni unsafe endpoints are auth-configured: {node['name']}", "security") as r:
            # NOTE: GET /config is a documented Patroni "safe" endpoint and is
            # UNAUTHENTICATED BY DESIGN (see patroni docs/security.rst) - that
            # is not a misconfiguration, so we don't test for it. Only PUT/
            # POST/PATCH/DELETE ("unsafe") endpoints are meant to require auth.
            # We deliberately do NOT fire a live unauthenticated request at an
            # unsafe endpoint here (e.g. /restart) - if auth were genuinely
            # missing, that call would actually restart postgres. Instead,
            # check the config that governs it directly.
            code, out, err = ssh.run(
                node["ip"],
                # -A2 was wrong: username/password sit under the nested
                # "authentication:" key, 4-5 lines past "restapi:", not 2.
                # Extract the whole restapi: block (until the next top-level
                # key) instead of guessing a fixed line count.
                "sudo awk '/^restapi:/{f=1;next}/^[a-zA-Z]/{f=0}f' /etc/patroni/patroni.yml "
                "| grep -E 'username|password' || true",
                timeout=15,
            )
            r.details = out.strip() or "(no restapi.authentication block found)"
            if "username" not in out or "password" not in out:
                raise RuntimeError("restapi.authentication not configured - unsafe endpoints (restart/switchover/config PATCH) are callable without credentials")

    if cluster.get("vip"):
        with ctx.new_result("HAProxy stats page not externally exposed", "security") as r:
            open_ = _port_open(cluster["nodes"][0]["ip"], 7000)
            r.metrics = {"port_7000_reachable_from_here": open_}
            if open_:
                raise RuntimeError("HAProxy stats port 7000 is reachable from outside the node - should be loopback-only")
            r.details = "Port 7000 not reachable externally, as expected"

    with ctx.new_result("etcd client port not exposed beyond cluster nodes", "security") as r:
        cluster_ips = {n["ip"] for n in cluster["nodes"]} | {cluster["watcher_ip"]}
        etcd_port = cluster.get("etcd_client_port", 2379)
        reachable_from_here = _port_open(cluster["nodes"][0]["ip"], etcd_port)
        r.metrics = {"reachable_from_test_host": reachable_from_here}
        r.details = (
            "etcd port reachable from this test host too - confirm this test host is meant to be "
            "inside the trusted network, otherwise your security group/firewall is too permissive."
            if reachable_from_here else "etcd port not reachable from this test host, as expected."
        )
        # informational only (WARN, not FAIL) - reachability from the trusted
        # subnet the tool itself runs in is expected in most deployments
        if reachable_from_here:
            r.status = Status.WARN
        _ = cluster_ips  # kept for future per-source-IP ACL checks
