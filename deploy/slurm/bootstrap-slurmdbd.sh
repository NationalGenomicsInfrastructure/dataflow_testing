#!/bin/sh
# One-shot bootstrap for the slurmdbd accounting database
# (slurmdbd-bootstrap compose service).
#
# SLURM 24.11 has no AutoCreate, but registering a cluster with
# `sacctmgr add cluster` also creates its "root" account, the "root"
# admin user and their cluster-wide association (the DB transaction log
# shows all of it as a side effect of the single Add Clusters record) -
# so the cluster registration is the whole bootstrap. Idempotency is by
# state check, not by -i: in 24.11 `sacctmgr add cluster` (with or
# without -i) exits 1 when the cluster already exists, so the script
# checks first and re-runs harmlessly on every stack (re)start.
#
# Runs as root, so it reads the root-owned munge key like the other
# SLURM-aware processes in the stack.

set -eu

# --- munged runtime (same layout as the other SLURM entrypoints) ----------
# sacctmgr authenticates to slurmdbd with munge, so this container needs
# munged running with the shared key (slurm-munge volume, mounted at
# /etc/munge; normalized by the slurmdbd entrypoint, which starts first).
install -d -o root -g root -m 755 /var/run/munge
if [ ! -f /var/lib/munge/.seed ]; then
    head -c 1024 /dev/urandom > /var/lib/munge/.seed
    chown root:munge /var/lib/munge/.seed
    chmod 440 /var/lib/munge/.seed
fi
chown root:root /etc/munge
chmod 755 /etc/munge
if [ -f /etc/munge/munge.key ]; then
    chown root:root /etc/munge/munge.key
    chmod 400 /etc/munge/munge.key
fi
munged
echo "[slurmdbd-bootstrap] munged started"

# Wait for slurmdbd to answer its clients (sacctmgr talks to it directly,
# authenticated with munge).
i=0
until sacctmgr show clusters >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "${i}" -ge 90 ]; then
        echo "[slurmdbd-bootstrap] ERROR: slurmdbd not reachable after 180s" >&2
        exit 1
    fi
    sleep 2
done
echo "[slurmdbd-bootstrap] slurmdbd is reachable"

# Note for 24.11: `sacctmgr add association` no longer exists (the man
# page restricts the association entity to list/show; associations are
# managed through the user/account/cluster entities), so no association
# step is needed here.
if sacctmgr show clusters 2>/dev/null | grep -qw dataflow; then
    echo "[slurmdbd-bootstrap] cluster dataflow already registered"
else
    sacctmgr add cluster name=dataflow
fi

echo "[slurmdbd-bootstrap] bootstrap complete"