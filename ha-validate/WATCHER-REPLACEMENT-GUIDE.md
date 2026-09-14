# Replacing / Relocating the Watcher Node

The watcher is an **etcd-only** member — no PostgreSQL, no Patroni. Its whole
job is to make the etcd cluster 5 members instead of 4, so a straight 2-2
network split among the 4 PG nodes can never happen (5 always breaks 3-2).
See the architecture discussion in the main chat history for why this
matters; this guide is only the **how**.

**Do NOT** just edit `/etc/default/etcd`'s `ETCD_INITIAL_CLUSTER` string on
the surviving nodes and restart them. Once etcd has bootstrapped, that file
is only read again by a node's OWN first startup — existing members learn
about membership changes through etcd's own `member add`/`member remove`
raft operations, not by rereading a config file. Skipping that and just
restarting existing members with an edited file does **nothing** (silently)
and is not how you add or remove a member.

There are two different situations. Use the matching procedure.

---

## Situation A: the current watcher is dead and needs replacing

Use this when the watcher VM is gone/corrupted and you just need a working
5th member back, same role, same site is fine.

**Precondition**: the other 4 members (all 4 PG nodes, which also run etcd)
must be healthy — you need 3 of the remaining 4 reachable to safely perform
a member remove, and that's already true if only the watcher is down.

### 1. Remove the dead member from etcd

From any healthy PG node:
```bash
etcdctl --endpoints=http://<any-healthy-pg-ip>:2379 member list
```
Find the dead watcher's `ID` in the output (first column), then:
```bash
etcdctl --endpoints=http://<any-healthy-pg-ip>:2379 member remove <dead-member-id>
```
This drops total membership to 4 (quorum temporarily becomes 3-of-4) until
you add the replacement.

### 2. Provision the replacement VM

Same OS/package baseline as everything else — Ubuntu 24.04, same as
`pg-ha-setup/remote-install.sh` installs for a non-PG node (it already
branches on `is_pg_node=false` to install etcd only, skip PG/Patroni). You
can reuse that script directly:
```bash
scp pg-ha-setup/remote-install.sh user@<new-watcher-ip>:/tmp/
ssh user@<new-watcher-ip> "sudo bash /tmp/remote-install.sh false false"
```
(second `false` = HAProxy/keepalived not applicable to a watcher)

### 3. Tell etcd about the new member BEFORE starting etcd on it

From a healthy existing member:
```bash
etcdctl --endpoints=http://<any-healthy-pg-ip>:2379 member add etcd-watcher-new \
  --peer-urls=http://<new-watcher-ip>:2380
```
This prints an `ETCD_INITIAL_CLUSTER` value and `ETCD_INITIAL_CLUSTER_STATE=existing`
— **copy these exactly**, they're specific to this join operation.

### 4. Configure and start etcd on the new node

Write `/etc/default/etcd` on the new watcher using the values from step 3:
```bash
ETCD_NAME="etcd-watcher-new"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_LISTEN_PEER_URLS="http://<new-watcher-ip>:2380"
ETCD_LISTEN_CLIENT_URLS="http://<new-watcher-ip>:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://<new-watcher-ip>:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://<new-watcher-ip>:2379"
ETCD_INITIAL_CLUSTER="<the exact string member add printed>"
ETCD_INITIAL_CLUSTER_STATE="existing"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-etcd-token"
```
Then:
```bash
sudo systemctl enable etcd && sudo systemctl start etcd
```

### 5. Verify

```bash
etcdctl --endpoints=http://<any-pg-ip>:2379 member list
etcdctl --endpoints=http://<any-pg-ip>:2379 endpoint health --cluster
```
Should show 5 healthy members again.

### 6. Point Patroni at the new watcher IP (only if the IP changed)

`/etc/patroni/patroni.yml` on all 4 PG nodes has an `etcd3.hosts` line
listing all 5 members' `ip:2379`. If the new watcher's IP differs from the
old one, update that line on each of the 4 PG nodes and do a **rolling**
restart — one node at a time, confirm it's healthy before moving to the
next:
```bash
sudo systemctl restart patroni
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list   # confirm healthy before next node
```
If you reused the same IP for the new hardware, skip this step entirely —
nothing on the Patroni side needs to change.

---

## Situation B: relocating a HEALTHY watcher on purpose

Use this when you're deliberately moving the watcher — e.g. correcting a
site-quorum imbalance (moving it from a site that already holds a PG-node
majority to the other site). This is the safer order: **add the new one
before removing the old one**, so you're never down to a fragile minimum
during the move.

1. Provision the new watcher VM at the new location (same as step 2 above).
2. `etcdctl member add` for the new node (same as step 3 above) — cluster is
   now temporarily **6** members (quorum 4-of-6) while both watchers exist.
3. Configure and start etcd on the new node (same as step 4 above).
4. Verify the new member joined and is healthy (same as step 5) — you now
   have 6 healthy members.
5. **Now** remove the old watcher:
   ```bash
   etcdctl --endpoints=http://<any-pg-ip>:2379 member list   # get old watcher's ID
   etcdctl --endpoints=http://<any-pg-ip>:2379 member remove <old-watcher-id>
   ```
   Back to 5 members, quorum 3-of-5, on the new layout.
6. Decommission the old watcher VM:
   ```bash
   ssh user@<old-watcher-ip> "sudo systemctl stop etcd && sudo systemctl disable etcd"
   ```
7. Update Patroni's `etcd3.hosts` on all 4 PG nodes and roll-restart, same
   as step 6 in Situation A.

---

## Housekeeping (optional, not functionally required)

After either procedure, the `ETCD_INITIAL_CLUSTER` string baked into
`/etc/default/etcd` on the 4 PG nodes is now stale (still lists the old
watcher). This causes **no operational problem** — that file is only
consulted by a node on its own first-ever startup, and the 4 PG nodes
already have persisted membership state on disk. But if you ever need to
fully rebuild one of those 4 nodes from scratch later, having an accurate
`ETCD_INITIAL_CLUSTER` string saves confusion. Worth updating for that
reason alone, on your own schedule — not urgent.

## Common mistakes to avoid

- **Skipping `member add`/`member remove` and just editing config files.**
  Does nothing after initial bootstrap (explained above) - silently. You'll
  think you've made the change and you haven't.
- **Starting the new node's etcd before running `member add`.** It'll never
  join - it doesn't know how to reach the existing cluster and the existing
  cluster doesn't know to expect it.
- **Removing the old watcher before the new one is confirmed healthy**
  (Situation B). Do this and you're briefly down to 4 members with no
  redundancy margin during the exact window you're making a change - use
  the add-then-remove order instead.
- **Doing this while any other member is already down.** `member remove`
  itself requires quorum among the *current* membership to execute safely.
  If you're already running on 4 out of 5, don't compound it - fix the
  other outage first.
