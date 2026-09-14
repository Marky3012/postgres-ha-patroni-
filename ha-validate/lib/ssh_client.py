"""Thin SSH wrapper around paramiko - one cached connection per host."""
from __future__ import annotations
import os
import paramiko


class SSHPool:
    def __init__(self, user: str, key_path: str, port: int = 22, timeout: int = 10):
        self.user = user
        self.key_path = os.path.expanduser(key_path)
        self.port = port
        self.timeout = timeout
        self._clients: dict[str, paramiko.SSHClient] = {}

    def _client_for(self, host: str) -> paramiko.SSHClient:
        if host in self._clients:
            c = self._clients[host]
            transport = c.get_transport()
            if transport is not None and transport.is_active():
                return c
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(
            hostname=host, port=self.port, username=self.user,
            key_filename=self.key_path if os.path.isfile(self.key_path) else None,
            timeout=self.timeout, banner_timeout=self.timeout, auth_timeout=self.timeout,
        )
        self._clients[host] = c
        return c

    def run(self, host: str, command: str, timeout: int = 60) -> tuple[int, str, str]:
        """Returns (exit_code, stdout, stderr)."""
        client = self._client_for(host)
        stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
        out = stdout.read().decode("utf-8", errors="replace")
        err = stderr.read().decode("utf-8", errors="replace")
        code = stdout.channel.recv_exit_status()
        return code, out, err

    def run_ok(self, host: str, command: str, timeout: int = 60) -> str:
        """Like run(), but raises if exit code is nonzero. Returns stdout."""
        code, out, err = self.run(host, command, timeout=timeout)
        if code != 0:
            raise RuntimeError(f"[{host}] command failed (exit {code}): {command}\nstderr: {err.strip()}")
        return out

    def close_all(self):
        for c in self._clients.values():
            try:
                c.close()
            except Exception:
                pass
        self._clients.clear()
