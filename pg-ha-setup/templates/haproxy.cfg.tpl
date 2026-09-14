global
    maxconn 200
    log stdout format raw local0

defaults
    log global
    mode tcp
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s

listen stats
    # loopback-only: nothing outside this node needs it (check-haproxy-backend.sh
    # queries it locally); avoids exposing an unauthenticated topology/status
    # page on the public interface. SSH-tunnel to view it remotely if needed.
    mode http
    bind 127.0.0.1:7000
    stats enable
    stats uri /

# Routes to whichever node's Patroni REST API answers 200 on /primary (port 8008).
# Replicas answer non-200 there, so HAProxy marks them down for this backend.
listen postgres_primary
    bind *:5000
    option httpchk OPTIONS /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
{{SERVERS}}
