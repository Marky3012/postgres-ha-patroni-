"""Query Patroni cluster state via patronictl (over SSH) and REST API."""
from __future__ import annotations
import json
import time
import urllib.request
import urllib.error
from .ssh_client import SSHPool


def cluster_state(ssh: SSHPool, any_pg_host: str, scope_config_path: str = "/etc/patroni/patroni.yml") -> list[dict]:
    """Returns the list of members as patronictl reports them, e.g.:
    [{"Member": "pg1", "Host": "172.21.1.90", "Role": "Leader", "State": "running", "TL": 3, "Lag in MB": 0}, ...]
    """
    code, out, err = ssh.run(any_pg_host, f"sudo -u postgres patronictl -c {scope_config_path} list -f json", timeout=30)
    if code != 0:
        raise RuntimeError(f"patronictl list failed on {any_pg_host}: {err.strip()}")
    return json.loads(out)


def get_leader(members: list[dict]) -> dict | None:
    for m in members:
        if m.get("Role") == "Leader":
            return m
    return None


def get_member(members: list[dict], host: str) -> dict | None:
    for m in members:
        if m.get("Host") == host:
            return m
    return None


def rest_get(host: str, path: str, port: int = 8008, timeout: int = 5, auth: tuple[str, str] | None = None) -> tuple[int, str]:
    """Direct HTTP call to a node's Patroni REST API (no SSH - tests real network path)."""
    url = f"http://{host}:{port}{path}"
    req = urllib.request.Request(url)
    if auth:
        import base64
        token = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        req.add_header("Authorization", f"Basic {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:
        return -1, str(e)


def wait_for_new_leader(ssh: SSHPool, any_pg_host: str, old_leader_host: str, timeout_s: int = 90, poll_s: int = 3) -> dict | None:
    """Polls until a member other than old_leader_host becomes Leader. Returns that member dict, or None on timeout."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            members = cluster_state(ssh, any_pg_host)
            leader = get_leader(members)
            if leader and leader.get("Host") != old_leader_host:
                return leader
        except Exception:
            pass
        time.sleep(poll_s)
    return None


def wait_for_role_state(ssh: SSHPool, any_pg_host: str, target_host: str, role: str, states,
                         timeout_s: int = 120, poll_s: int = 5, scope_config_path: str = "/etc/patroni/patroni.yml") -> bool:
    """Polls until target_host reports the given Role with State in `states`.
    `states` accepts a single string or an iterable of acceptable states -
    a healthy Replica reports State="streaming" (NOT "running" - that value
    is specific to Leader), so callers checking replica health must pass
    {"streaming", "running"} rather than a single exact string."""
    if isinstance(states, str):
        states = {states}
    else:
        states = set(states)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            members = cluster_state(ssh, any_pg_host, scope_config_path)
            m = get_member(members, target_host)
            if m and m.get("Role") == role and m.get("State") in states:
                return True
        except Exception:
            pass
        time.sleep(poll_s)
    return False
