vrrp_script chk_haproxy {
    # checks local HAProxy actually has an UP backend, not just that the
    # process exists - see check-haproxy-backend.sh for why
    script "/usr/local/bin/check-haproxy-backend.sh"
    interval 2
    # NEGATIVE weight: keepalived only *subtracts* on script failure with a
    # negative weight (a positive weight only ever *adds* on success and does
    # nothing on failure - that combo would never trigger failover at all).
    # Magnitude (30) exceeds the 20-point priority gap between nodes so a
    # failed node always drops below every healthy backup.
    weight -30
    fall 3
    rise 2
}

vrrp_instance VI_PG {
    state {{STATE}}
    interface {{IFACE}}
    virtual_router_id 51
    priority {{PRIORITY}}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass {{AUTH_PASS}}
    }
    unicast_src_ip {{MY_IP}}
    unicast_peer {
{{PEERS}}
    }
    virtual_ipaddress {
        {{VIP}}
    }
    track_script {
        chk_haproxy
    }
}
