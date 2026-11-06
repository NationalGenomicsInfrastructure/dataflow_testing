#!/bin/sh
# One-shot bootstrap for the slurmdbd accounting database
# (slurmdbd-bootstrap compose service).
#
# SLURM 24.11 has no AutoCreate: the cluster record and the root admin
# user (plus their association with the local partition) must be created
# explicitly. sacctmgr -i treats "already exists" as a success, so this
# script is idempotent and re-runs harmlessly on every stack (re)start.
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

sacctmgr -i add cluster name=dataflow
sacctmgr -i add account name=root cluster=dataflow
sacctmgr -i add user name=root cluster=dataflow account=root adminlevel=admin
sacctmgr -i add association cluster=dataflow account=root user=root partition=local qos=normal

echo "[slurmdbd-bootstrap] bootstrap complete"