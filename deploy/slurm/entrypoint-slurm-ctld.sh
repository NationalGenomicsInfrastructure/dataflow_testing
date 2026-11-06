#!/bin/sh
# SLURM controller entrypoint (deploy/Dockerfile.slurm-ctld).
#
# 1. Prepare the munged runtime layout. munged 0.5.16 (Debian trixie)
#    requires: /etc/munge root:root 755, the key root:root 0400,
#    /var/log/munge root:root 700, /var/lib/munge root:root 755 with a
#    .seed of root:munge 0440, and /run/munge root:root 755.
# 2. Create the shared munge key if absent. The slurm-munge volume is
#    mounted at /etc/munge and shared with slurmd and yggdrasil; this
#    container starts first in the stack, so it is the key authority.
#    Ownership/permissions are normalized on every start (the volume is
#    seeded from the image, whose package-generated key may carry a
#    stale build-time owner).
# 3. Start munged (it daemonizes).
# 4. Hand over to slurmctld in the foreground (PID 1). The daemon runs
#    as root on purpose: like the sbatch client, it must read the
#    root-owned munge key.

set -eu

# --- munged runtime layout -------------------------------------------------
install -d -o root -g root -m 755 /var/run/munge

if [ ! -f /var/lib/munge/.seed ]; then
    head -c 1024 /dev/urandom > /var/lib/munge/.seed
    chown root:munge /var/lib/munge/.seed
    chmod 440 /var/lib/munge/.seed
fi

# --- shared munge key --------------------------------------------------------
if [ ! -f /etc/munge/munge.key ]; then
    echo "[slurm-ctld-entrypoint] generating munge key at /etc/munge/munge.key"
    head -c 2048 /dev/urandom > /etc/munge/munge.key
else
    echo "[slurm-ctld-entrypoint] using existing munge key"
fi
chown root:root /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
chown root:root /etc/munge
chmod 755 /etc/munge

munged
echo "[slurm-ctld-entrypoint] munged started"

exec slurmctld -D