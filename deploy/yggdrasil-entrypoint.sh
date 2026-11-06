#!/usr/bin/env bash
#
# Yggdrasil service entrypoint.
#
# Yggdrasil fails fast at startup if any of its CouchDB databases are
# missing, and the statusdb seed runs in the background after CouchDB
# answers /_up. This entrypoint therefore verifies the environment is
# actually usable before firing the daemon:
#
#   1. CouchDB answers /_up
#   2. the seeded `projects` database exists
#   3. the yggdrasil / yggdrasil_plans / yggdrasil_ops databases exist
#   4. the demux_sample_info / flowcell_status databases exist (dmx_realm)
#   4b. the daemon's configuration files exist under /app (main.json is
#       fatal; a missing dmx_realm.json is a loud warning, since the realm
#       would otherwise fall back to its built-in defaults silently)
#   5. (optional) a test scenario document is injected into the stack
#   5b. (dev data) the zip-baked flowcells are staged onto the shared
#       /work volume where the dind sidecar can see them, and the page
#       cache for that data is pre-warmed (see stage_dev_data)
#   5c. (SLURM client, dind image only) munged is started against the
#       shared munge key and the SLURM control plane is soft-waited on,
#       so batch job submissions (sbatch/sacct) can authenticate
#   6. (optional) genomics-status is reachable, when it is part of this
#       stack (it is in the default compose stack; the wait is a soft gate
#       - the daemon does not depend on the UI)
#
# It then hands over to the requested yggdrasil command (default: `--dev daemon`).
#
# Environment:
#   YGG_COUCH_URL     CouchDB base URL (default http://statusdb:5984)
#   YGG_COUCH_USER    CouchDB username (required)
#   YGG_COUCH_PASS    CouchDB password (required)
#   YGG_INJECT_TEST_SCENARIO  "true" (default) to inject the scenario seed
#   YGG_SCENARIO_ID   document id for the scenario (default test_scenario:compose-demo)

set -euo pipefail

COUCH_URL="${YGG_COUCH_URL:-http://statusdb:5984}"
COUCH_USER="${YGG_COUCH_USER:?YGG_COUCH_USER must be set}"
COUCH_PASS="${YGG_COUCH_PASS:?YGG_COUCH_PASS must be set}"
AUTH=(-u "${COUCH_USER}:${COUCH_PASS}")

log() { printf '[yggdrasil-entrypoint] %s\n' "$*"; }

wait_for_http() {
    # $1 = url, $2 = name, $3 = timeout seconds
    local url="$1" name="$2" timeout="${3:-180}" waited=0
    log "Waiting for ${name} at ${url} (timeout ${timeout}s)..."
    until curl -sf -o /dev/null "${AUTH[@]}" "${url}" 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [ "${waited}" -ge "${timeout}" ]; then
            log "ERROR: ${name} did not become ready at ${url} within ${timeout}s"
            return 1
        fi
    done
    log "${name} is ready"
}

wait_for_db() {
    # $1 = database name, $2 = timeout seconds
    local db="$1" timeout="${2:-300}" waited=0
    log "Waiting for database '${db}'..."
    until curl -sf -o /dev/null "${AUTH[@]}" "${COUCH_URL}/${db}" 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [ "${waited}" -ge "${timeout}" ]; then
            log "ERROR: database '${db}' did not appear within ${timeout}s"
            return 1
        fi
    done
    log "database '${db}' is available"
}

create_db() {
    # $1 = database name (idempotent: 201 = created, 412 = already exists)
    local db="$1" code
    code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${AUTH[@]}" "${COUCH_URL}/${db}")"
    case "${code}" in
        201 | 412) log "database '${db}' ready (HTTP ${code})" ;;
        *) log "ERROR: failed to create database '${db}' (HTTP ${code})"; return 1 ;;
    esac
}

wait_for_service() {
    # Wait for an optional service on the compose network.
    # If the host does not resolve, the service is not part of this
    # stack and the wait is skipped. This is a soft gate: if the
    # service never becomes ready, a warning is logged and the daemon
    # is started anyway (it does not depend on the service).
    # $1 = host, $2 = port, $3 = name, $4 = timeout seconds
    local host="$1" port="$2" name="$3" timeout="${4:-300}" waited=0 resolvable=0
    # Retry DNS resolution briefly: a freshly (re)started container may need
    # a moment before the compose DNS records for peer services resolve.
    for _ in 1 2 3 4 5 6; do
        if getent hosts "${host}" >/dev/null 2>&1; then
            resolvable=1
            break
        fi
        sleep 2
    done
    if [ "${resolvable}" -ne 1 ]; then
        log "${name} (${host}) is not part of this stack; skipping readiness wait"
        return 0
    fi
    log "Waiting for ${name} at http://${host}:${port}/ (timeout ${timeout}s)..."
    # --connect-timeout/--max-time keep every probe bounded: on networks
    # where the name resolves to an unreachable host (e.g. an org DNS
    # entry), an unbounded curl would hang forever and the deadline
    # below would never be reached.
    until curl -sf --connect-timeout 5 --max-time 10 -o /dev/null "http://${host}:${port}/" 2>/dev/null; do
        sleep 2
        waited=$((waited + 2))
        if [ "${waited}" -ge "${timeout}" ]; then
            log "WARNING: ${name} did not become ready within ${timeout}s; continuing without it"
            return 0
        fi
    done
    log "${name} is ready"
}

inject_scenario() {
    local id="${YGG_SCENARIO_ID:-test_scenario:compose-demo}"
    local code
    # The scenario doc goes into yggdrasil_testdocs: that is the DB
    # test_realm watches (connection "yggdrasil_testdocs" in
    # yggdrasil-config/main.json; start_seq=0). The `yggdrasil` DB is
    # only test_realm's read/write data_access — docs written there
    # are never seen by the watcher.
    code="$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "${COUCH_URL}/yggdrasil_testdocs/${id}")"
    if [ "${code}" = "404" ]; then
        curl -sf -X PUT "${AUTH[@]}" \
            -H 'Content-Type: application/json' \
            --data-binary @/app/scenario_seed.json \
            "${COUCH_URL}/yggdrasil_testdocs/${id}" >/dev/null
        log "Injected test scenario '${id}' into the yggdrasil_testdocs database"
    else
        log "Test scenario '${id}' already present (HTTP ${code}); skipping injection"
    fi
}

verify_configs() {
    # main.json is fatal: without it the daemon has no CouchDB connections
    # at all. dmx_realm.json is not fatal: dmx_realm falls back to built-in
    # defaults when it is missing (work_base=/work/nf-realm-work, no -c
    # common_config, no skip_tools) - make that loud instead of silent.
    local cfg_dir="/app/yggdrasil_workspace/common/configurations"
    if [ ! -f "${cfg_dir}/main.json" ]; then
        log "ERROR: ${cfg_dir}/main.json is missing; the daemon cannot run without it"
        return 1
    fi
    if [ ! -f "${cfg_dir}/dmx_realm.json" ]; then
        log "WARNING: ${cfg_dir}/dmx_realm.json is missing; dmx_realm will run with built-in defaults (work_base=/work/nf-realm-work, no -c common_config, no skip_tools). Rebuild the image (make compose-build-yggdrasil) or restore the file."
    fi
}

# 1. CouchDB must be up.
wait_for_http "${COUCH_URL}/_up" "CouchDB" 180

# 2. Seeded projects database (statusdb seeds it in the background).
wait_for_db "projects" 300

# 3. Yggdrasil's own databases. yggdrasil_testdocs is the scenario DB:
# test_realm's watcher (connection "yggdrasil_testdocs" in
# yggdrasil-config/main.json) dies with a 404 if it is missing.
create_db "yggdrasil"
create_db "yggdrasil_plans"
create_db "yggdrasil_ops"
create_db "yggdrasil_testdocs"

# 4. Databases watched by the dmx_realm realm (demux_realm package).
create_db "demux_sample_info"
create_db "flowcell_status"

# 4b. Configuration files must be in place (see verify_configs).
verify_configs

# 5. Optional test scenario.
if [ "${YGG_INJECT_TEST_SCENARIO:-true}" = "true" ]; then
    inject_scenario
else
    log "YGG_INJECT_TEST_SCENARIO=false; not injecting a test scenario"
fi

# 5b. Stage the development data onto the shared /work volume, at the paths
#     the realm config (dmx_realm.json: hpc_base_path, nextflow.*) points at:
#     - the zip-baked test flowcells (/Illumina/NextSeq, present in this
#       image) are copied to /work/Illumina/NextSeq so the dind sidecar -
#       which mounts the same volume but not /Illumina - can serve them to
#       the nested pipeline containers;
#     - the dind image ships the local Nextflow resource config at
#       /etc/demux (the base image does not; nothing to do in that case).
#     Both copies are no-clobber and re-run on every (re)start, so they
#     finish before the daemon can plan anything.
stage_dev_data() {
    if [ -d /Illumina/NextSeq ] && [ -d /work ]; then
        log "Staging test flowcells: /Illumina/NextSeq -> /work/Illumina/NextSeq"
        mkdir -p /work/Illumina/NextSeq
        cp -rn /Illumina/NextSeq/. /work/Illumina/NextSeq/
        # Pre-warm the page cache for the staged data. The first pipeline
        # after a (re)start would otherwise read all BCL files cold; under
        # that slow I/O the BCLCONVERT container exhausts Docker's default
        # 1024 open-file limit and aborts with spurious "Missing file"
        # errors on files that are present (the nofile override in
        # deploy/nf/demultiplex_local.config is the real fix; this keeps
        # the first run fast as well).
        log "Pre-warming page cache for /work/Illumina/NextSeq"
        find /work/Illumina/NextSeq -type f -exec cat {} + > /dev/null || log "WARNING: page-cache pre-warm failed; continuing"
    fi
    if [ -f /etc/demux/demultiplex_local.config ] && [ ! -e /work/demultiplex_local.config ]; then
        log "Staging Nextflow resource config to /work/demultiplex_local.config"
        cp /etc/demux/demultiplex_local.config /work/demultiplex_local.config
    fi
}

stage_dev_data

# 5c. SLURM client setup (dind image only): the daemon's job manager
#     shells out to sbatch/sacct, which authenticate to the stack's local
#     SLURM cluster (slurmctld/slurmd services) with the munge key shared
#     on the slurm-munge volume. The base image has no SLURM client and
#     no slurm.conf, so this is skipped there. Both waits are soft gates:
#     a missing/broken cluster must not block the daemon (the slurm_job
#     scenario would simply fail at submission time instead).
start_slurm_client() {
    if [ ! -f /etc/slurm/slurm.conf ]; then
        log "No /etc/slurm/slurm.conf; skipping SLURM client setup"
        return 0
    fi
    local key=/etc/munge/munge.key waited=0
    until [ -f "${key}" ]; do
        sleep 2
        waited=$((waited + 2))
        if [ "${waited}" -ge 120 ]; then
            log "WARNING: munge key did not appear within 120s; SLURM jobs cannot authenticate"
            return 0
        fi
    done
    # Normalize the key (it may carry a stale build-time owner until the
    # first normalizing entrypoint runs).
    chown root:root "${key}" 2>/dev/null || true
    chmod 400 "${key}" 2>/dev/null || true
    # munged 0.5.16 runtime layout (same as the SLURM services; see
    # deploy/slurm/entrypoint-slurm-ctld.sh).
    install -d -o root -g root -m 755 /var/run/munge
    if [ ! -f /var/lib/munge/.seed ]; then
        head -c 1024 /dev/urandom > /var/lib/munge/.seed
        chown root:munge /var/lib/munge/.seed
        chmod 440 /var/lib/munge/.seed
    fi
    if ! munged; then
        log "WARNING: munged failed to start; SLURM jobs cannot authenticate"
        return 0
    fi
    log "munged started"
    waited=0
    until scontrol ping 2>/dev/null | grep -q "is UP"; do
        sleep 2
        waited=$((waited + 2))
        if [ "${waited}" -ge 300 ]; then
            log "WARNING: slurmctld did not answer scontrol ping within 300s; continuing"
            return 0
        fi
    done
    log "SLURM control plane is ready"
}

start_slurm_client

# 6. Optional UI service (in the default stack; soft gate).
wait_for_service "genomics-status" 9761 "genomics-status" 300

# 7. Hand over to yggdrasil.
log "Starting: yggdrasil $*"
exec yggdrasil "$@"