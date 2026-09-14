scope: {{SCOPE}}
namespace: /db/
name: {{NODENAME}}

restapi:
  listen: {{IP}}:8008
  connect_address: {{IP}}:8008
  authentication:
    username: patroni
    password: {{API_PW}}

etcd3:
  hosts: {{ETCD_HOSTS}}

bootstrap:
  # NOTE: this bootstrap.dcs block only takes effect the FIRST time the
  # cluster forms (it seeds etcd). Once bootstrapped, Patroni reads these
  # values from etcd, not this file - re-running deploy.sh with a changed
  # value here will NOT change a running cluster. To change them later use:
  #   patronictl -c /etc/patroni/patroni.yml edit-config
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"

  initdb:
    - encoding: UTF8
    - data-checksums

  # Restricted to {{CLIENT_CIDR}} (replication traffic + client connections),
  # not 0.0.0.0/0. Widen this if your app servers/VIP sit outside that range.
  pg_hba:
    - host replication replicator 127.0.0.1/32 md5
    - host replication replicator {{CLIENT_CIDR}} md5
    - host all all {{CLIENT_CIDR}} md5

postgresql:
  listen: {{IP}}:5432
  connect_address: {{IP}}:5432
  data_dir: /var/lib/postgresql/17/main
  bin_dir: /usr/lib/postgresql/17/bin
  authentication:
    replication:
      username: replicator
      password: {{REPL_PW}}
    superuser:
      username: postgres
      password: {{SUPERUSER_PW}}
  parameters:
    unix_socket_directories: '/var/run/postgresql'

# use_pg_rewind above = automatic FAILBACK: a rejoining old leader is
# rewound to the new leader's timeline and re-attached as a replica,
# no manual re-sync/re-clone needed.

watchdog:
  # 'off' by default. Patroni's own /primary REST endpoint can keep answering
  # 200 for a short window even if PostgreSQL itself has wedged/died
  # underneath it (known upstream edge case, patroni#2756) - a real hardware
  # watchdog is the actual fix for that class of zombie-primary scenario, not
  # something HAProxy's check alone can close. Set to 'automatic' + install
  # the 'softdog' kernel module (modprobe softdog) for that protection.
  mode: off

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
