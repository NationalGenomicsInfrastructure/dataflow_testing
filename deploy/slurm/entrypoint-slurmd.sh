#!/bin/sh
# SLURM compute node entrypoint (deploy/Dockerfile.slurmd).
#
# 1. Wait (bounded) for the shared munge key: it lives on the
#    slurm-munge volume (mounted at /etc/munge) and is created/normalized
#    by the slurmctld entrypoint; compose starts this container only once
#    the controller is healthy.
# 2. Prepare the munged runtime layout (same requirements as the
#    controller, see deploy/slurm/entrypoint-slurm-ctld.sh) and start
#    munged (it daemonizes).
# 3. Hand over to slurmd in the foreground (PID 1), running as root so
#    it can read the root-owned munge key. It registers with the
#    controller and shows up as node "slurmd" in sinfo.

set -eu

KEY=/etc/munge/munge.key

echo "[slurmd-entrypoint] waiting for munge key at ${KEY}..."
waited=0
until [ -f "${KEY}" ]; do
    sleep 2
    waited=$((waited + 2))
    if [ "${waited}" -ge 300 ]; then
        echo "[slurmd-entrypoint] ERROR: munge key did not appear within 300s" >&2
        exit 1
    fi
done
echo "[slurmd-entrypoint] munge key found"

# Normalize the key: the volume may carry a package-generated key with a
# stale build-time owner until the first normalizing entrypoint runs.
chown root:root "${KEY}"
chmod 400 "${KEY}"

# --- munged runtime layout (same as the controller) --------------------------
install -d -o root -g root -m 755 /var/run/munge

if [ ! -f /var/lib/munge/.seed ]; then
    head -c 1024 /dev/urandom > /var/lib/munge/.seed
    chown root:munge /var/lib/munge/.seed
    chmod 440 /var/lib/munge/.seed
fi

chown root:root /etc/munge
chmod 755 /etc/munge

munged
echo "[slurmd-entrypoint] munged started"

exec slurmd -D