#!/bin/sh
# slurmdbd entrypoint (deploy/Dockerfile.slurmdbd).
#
# 1. Ensure the shared munge key on the slurm-munge volume exists and has
#    the ownership/permissions munged requires. Any container may mount
#    the volume first, so every entrypoint can generate the key; the key
#    is then shared unchanged with the other containers.
# 2. Prepare the munged runtime layout (same as the other SLURM images)
#    and start munged (it daemonizes).
# 3. Hand over to slurmdbd in the foreground (PID 1), running as root so
#    it can read the root-owned munge key.

set -eu

if [ ! -f /etc/munge/munge.key ]; then
    echo "[slurmdbd-entrypoint] generating munge key at /etc/munge/munge.key"
    head -c 2048 /dev/urandom > /etc/munge/munge.key
else
    echo "[slurmdbd-entrypoint] using existing munge key"
fi
chown root:root /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
chown root:root /etc/munge
chmod 755 /etc/munge

# --- munged runtime layout (same as the other SLURM images) ----------------
install -d -o root -g root -m 755 /var/run/munge

if [ ! -f /var/lib/munge/.seed ]; then
    head -c 1024 /dev/urandom > /var/lib/munge/.seed
    chown root:munge /var/lib/munge/.seed
    chmod 440 /var/lib/munge/.seed
fi

munged
echo "[slurmdbd-entrypoint] munged started"

exec slurmdbd -D