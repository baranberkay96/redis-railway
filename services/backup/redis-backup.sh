#!/bin/bash
# RDB backups of the Redis service to a Railway Bucket (S3) with retention, and a
# one-shot restore through Redis replication. Runs once and exits: the
# "Redis Backup" service is a Railway cron job.
#
#   redis-backup run       restore if BACKUP_RESTORE_RUN is set and not yet restored, else backup (default)
#   redis-backup backup    snapshot -> redis-check-rdb -> Bucket -> MANIFEST.txt -> prune
#   redis-backup restore   load BACKUP_RESTORE_RUN into the Redis service
#   redis-backup list      list the runs stored in the Bucket
#
# Layout in the Bucket (one folder per run, UTC timestamp):
#   {BACKUP_PREFIX}/20261031T032000Z/dump.rdb.gz    redis-cli --rdb snapshot (gzip, or dump.rdb with compression none)
#   {BACKUP_PREFIX}/20261031T032000Z/MANIFEST.txt   written last; a run without it is incomplete
#   {BACKUP_PREFIX}/_restores/20261031T032000Z.txt  written after that run was restored (blocks a second restore)
#
# Retention: complete runs older than BACKUP_RETENTION_DAYS are deleted, but the
# newest BACKUP_KEEP_MIN complete runs are always kept. Incomplete runs older than
# two days are deleted. A failed run deletes nothing.
#
# Restore: a helper redis-server inside this job loads the backup (with the same
# bundled modules), the Redis service is made its replica (REPLICAOF), and once the
# full sync is done it is promoted back (REPLICAOF NO ONE). Everything in the
# Redis service is replaced, including other databases, functions and Search index
# definitions. Writes are refused (READONLY) while the sync runs.
set -Eeuo pipefail

PREFIX="${BACKUP_PREFIX:-redis}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
COMPRESSION="${BACKUP_COMPRESSION:-gzip}"
WAIT_SECONDS="${BACKUP_WAIT_SECONDS:-300}"
WORK_BASE="${BACKUP_WORK_DIR:-/tmp}"
RESTORE_RUN="${BACKUP_RESTORE_RUN:-}"
RESTORE_PORT="${BACKUP_RESTORE_PORT:-6390}"
RESTORE_TIMEOUT="${BACKUP_RESTORE_TIMEOUT:-1800}"
REDIS_HOST="${REDIS_HOST:-}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_USER="${REDIS_USER:-default}"
INCOMPLETE_GRACE_DAYS=2
LINK_DOWN_LIMIT=180
RUN_RE='^[0-9]{8}T[0-9]{6}Z$'
REMOTE=""
WORK=""
HELPER_PID=""
HELPER_PASSWORD=""
REPLICA_ACTIVE=0
CURRENT_RUN=""

log() { printf '[redis-backup] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

cleanup() {
  local status=$?
  if [ "${REPLICA_ACTIVE}" -eq 1 ]; then
    promote_redis || log "WARNING: could not promote the Redis service; run REPLICAOF NO ONE in RedisInsight's CLI"
  fi
  if [ -n "${HELPER_PID}" ]; then
    kill "${HELPER_PID}" 2>/dev/null || true
    wait "${HELPER_PID}" 2>/dev/null || true
  fi
  if [ -n "${WORK}" ]; then rm -rf "${WORK}"; fi
  exit "${status}"
}
trap cleanup EXIT

# --- settings ---------------------------------------------------------------

require_uint() {
  local name="$1" value="$2" min="$3"
  [[ "${value}" =~ ^[0-9]+$ ]] && [ "${value}" -ge "${min}" ] \
    || die "${name} must be a whole number >= ${min} (got '${value}')"
}

validate_settings() {
  require_uint BACKUP_RETENTION_DAYS "${RETENTION_DAYS}" 1
  require_uint BACKUP_KEEP_MIN "${KEEP_MIN}" 1
  require_uint BACKUP_WAIT_SECONDS "${WAIT_SECONDS}" 0
  require_uint BACKUP_RESTORE_PORT "${RESTORE_PORT}" 1024
  require_uint BACKUP_RESTORE_TIMEOUT "${RESTORE_TIMEOUT}" 60
  require_uint REDIS_PORT "${REDIS_PORT}" 1
  [[ "${PREFIX}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] && [[ "/${PREFIX}/" != */./* ]] && [[ "/${PREFIX}/" != */../* ]] \
    || die "BACKUP_PREFIX must be a folder path of letters, digits, '.', '_' and '-' (no '.' or '..' segments)"
  case "${COMPRESSION}" in gzip|none) ;; *) die "BACKUP_COMPRESSION must be gzip or none (got '${COMPRESSION}')" ;; esac
  [ -n "${REDIS_HOST}" ] || die "REDIS_HOST is not set (reference the Redis service's REDISHOST)"
  [ -n "${REDIS_PASSWORD:-}" ] || die "REDIS_PASSWORD is not set (reference the Redis service's REDIS_PASSWORD)"
  { [ -d "${WORK_BASE}" ] && [ -w "${WORK_BASE}" ]; } || die "BACKUP_WORK_DIR ${WORK_BASE} is not a writable directory"
}

configure_remote() {
  local var missing=()
  for var in BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    [ -n "${!var:-}" ] || missing+=("${var}")
  done
  [ "${#missing[@]}" -eq 0 ] || die "Bucket not configured (missing: ${missing[*]})"
  # rclone remote "bucket", configured only through the environment. Railway
  # Buckets use virtual-hosted-style URLs (path style is rejected).
  export RCLONE_CONFIG="${HOME:-/tmp}/rclone.conf"
  : > "${RCLONE_CONFIG}"
  export RCLONE_CONFIG_BUCKET_TYPE=s3
  export RCLONE_CONFIG_BUCKET_PROVIDER=Other
  export RCLONE_CONFIG_BUCKET_ENDPOINT="${BACKUP_S3_ENDPOINT}"
  export RCLONE_CONFIG_BUCKET_REGION="${BACKUP_S3_REGION:-auto}"
  export RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}"
  export RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}"
  export RCLONE_CONFIG_BUCKET_FORCE_PATH_STYLE="${BACKUP_S3_FORCE_PATH_STYLE:-false}"
  export RCLONE_CONFIG_BUCKET_NO_CHECK_BUCKET=true
  # 16 MiB parts: files up to ~150 GiB (10,000 parts).
  export RCLONE_CONFIG_BUCKET_CHUNK_SIZE=16M
  REMOTE="bucket:${BACKUP_S3_BUCKET}/${PREFIX}"
}

# --- Redis helpers ------------------------------------------------------------

# The Redis service (password passed through the environment, never on the command line).
rcli() {
  REDISCLI_AUTH="${REDIS_PASSWORD}" redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" --user "${REDIS_USER}" "$@"
}

# The restore helper server inside this container.
hcli() {
  REDISCLI_AUTH="${HELPER_PASSWORD}" redis-cli -h 127.0.0.1 -p "${RESTORE_PORT}" "$@"
}

# Make the Redis service a primary again. Retries while it is still loading a
# sync payload (it answers LOADING until then), for up to 15 minutes.
promote_redis() {
  local tries=0 reply
  while [ "${tries}" -lt 180 ]; do
    reply="$(rcli REPLICAOF NO ONE 2>&1 | tr -d '\r' || true)"
    if [ "${reply}" = "OK" ]; then
      REPLICA_ACTIVE=0
      rcli CONFIG SET masterauth "" > /dev/null 2>&1 || log "WARNING: could not clear masterauth"
      return 0
    fi
    tries=$((tries + 1))
    sleep 5
  done
  return 1
}

# info_field "<INFO output>" field -> value
info_field() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n "s/^$2:\(.*\)$/\1/p" | head -n 1
}

# keyspace_keys "<INFO keyspace output>" -> total keys over all databases
keyspace_keys() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's/^db[0-9]*:keys=\([0-9]*\),.*/\1/p' | awk '{ s += $1 } END { print s + 0 }'
}

wait_for_redis() {
  local waited=0 reply
  while :; do
    reply="$(rcli PING 2>&1 || true)"
    [ "${reply}" = "PONG" ] && return 0
    case "${reply}" in
      *WRONGPASS*|*NOAUTH*|*NOPERM*) die "Redis rejected the credentials (${reply})" ;;
    esac
    [ "${waited}" -ge "${WAIT_SECONDS}" ] && die "Redis at ${REDIS_HOST}:${REDIS_PORT} not ready after ${WAIT_SECONDS}s (last reply: ${reply})"
    log "waiting for Redis at ${REDIS_HOST}:${REDIS_PORT} (${reply:-no reply})"
    sleep 10
    waited=$((waited + 10))
  done
}

manifest_value() {  # manifest_value <file> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# --- backup -------------------------------------------------------------------

run_backup() {
  local run_id dest rdb file version source_keys keys check_out rdb_sha rdb_bytes file_sha file_bytes remote_bytes
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${REMOTE}/${run_id}"
  WORK="$(mktemp -d "${WORK_BASE%/}/redis-backup.XXXXXX")"
  rdb="${WORK}/dump.rdb"
  version="$(info_field "$(rcli INFO server 2>/dev/null || true)" redis_version)"
  source_keys="$(keyspace_keys "$(rcli INFO keyspace 2>/dev/null || true)")"
  log "starting run ${run_id}: Redis ${version:-?} at ${REDIS_HOST}:${REDIS_PORT}, ${source_keys} keys -> ${PREFIX}/${run_id}/ in bucket ${BACKUP_S3_BUCKET}"

  # REPLCONF rdb-only + SYNC: the server forks and streams a fresh RDB.
  if ! rcli --rdb "${rdb}" > "${WORK}/rdb.log" 2>&1; then
    tail -n 20 "${WORK}/rdb.log" >&2 || true
    die "redis-cli --rdb failed"
  fi
  [ -s "${rdb}" ] || die "redis-cli --rdb produced an empty file"

  # Full structural check, module values included (check mode parses them generically).
  if ! check_out="$(redis-check-rdb "${rdb}" 2>&1)"; then
    printf '%s\n' "${check_out}" | tail -n 20 >&2
    die "redis-check-rdb rejected the snapshot"
  fi
  keys="$(printf '%s\n' "${check_out}" | sed -n 's/.*\[info\] \([0-9]*\) keys read.*/\1/p' | tail -n 1)"
  rdb_sha="$(sha256sum "${rdb}" | cut -d ' ' -f 1)"
  rdb_bytes="$(stat -c %s "${rdb}")"
  log "snapshot ok: ${rdb_bytes} bytes, ${keys:-?} keys (redis-check-rdb)"

  if [ "${COMPRESSION}" = gzip ]; then
    file="dump.rdb.gz"
    gzip -6 -c "${rdb}" > "${WORK}/${file}"
    rm -f "${rdb}"
  else
    file="dump.rdb"
  fi
  file_sha="$(sha256sum "${WORK}/${file}" | cut -d ' ' -f 1)"
  file_bytes="$(stat -c %s "${WORK}/${file}")"

  rclone copyto --retries 3 "${WORK}/${file}" "${dest}/${file}" || die "upload of ${file} failed"
  remote_bytes="$(rclone size --json "${dest}/${file}" 2>/dev/null | sed -nE 's/.*"bytes":[[:space:]]*([0-9]+).*/\1/p' || true)"
  [ "${remote_bytes}" = "${file_bytes}" ] \
    || die "uploaded ${file} has ${remote_bytes:-no} bytes in the Bucket, expected ${file_bytes}"

  {
    printf 'run=%s\nredis_version=%s\nfile=%s\ncompression=%s\n' "${run_id}" "${version:-unknown}" "${file}" "${COMPRESSION}"
    printf 'file_bytes=%s\nfile_sha256=%s\nrdb_bytes=%s\nrdb_sha256=%s\n' "${file_bytes}" "${file_sha}" "${rdb_bytes}" "${rdb_sha}"
    printf 'keys=%s\nsource_keys_at_start=%s\n' "${keys:-unknown}" "${source_keys}"
  } > "${WORK}/MANIFEST.txt"
  rclone copyto --retries 3 "${WORK}/MANIFEST.txt" "${dest}/MANIFEST.txt" || die "upload of MANIFEST.txt failed"
  log "run ${run_id} complete: ${file} (${file_bytes} bytes)"
  CURRENT_RUN="${run_id}"
  rm -rf "${WORK}"
  WORK=""
}

list_runs() {
  # Folder names of every run, oldest first (other folders such as _restores are ignored).
  rclone lsf --dirs-only "${REMOTE}/" 2>/dev/null | sed 's#/$##' | grep -E "${RUN_RE}" | sort || true
}

list_complete_runs() {
  rclone lsf -R --files-only --max-depth 2 --include 'MANIFEST.txt' "${REMOTE}/" 2>/dev/null \
    | sed 's#/MANIFEST.txt$##' | grep -E "${RUN_RE}" | sort || true
}

prune() {
  local now cutoff incomplete_cutoff complete=() run keep protected=" " total
  now="$(date -u +%s)"
  cutoff="$(date -u -d "@$((now - RETENTION_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  incomplete_cutoff="$(date -u -d "@$((now - INCOMPLETE_GRACE_DAYS * 86400))" +%Y%m%dT%H%M%SZ)"
  while IFS= read -r run; do [ -n "${run}" ] && complete+=("${run}"); done < <(list_complete_runs)
  total="${#complete[@]}"
  keep=$((total - KEEP_MIN))
  for run in ${complete[@]+"${complete[@]}"}; do
    # The newest KEEP_MIN complete runs are protected regardless of age.
    if [ "${keep}" -le 0 ]; then protected="${protected}${run} "; fi
    keep=$((keep - 1))
  done
  log "retention: ${total} complete run(s), keep ${RETENTION_DAYS} days (older than ${cutoff}), at least ${KEEP_MIN}"
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    [ "${run}" = "${CURRENT_RUN}" ] && continue
    case "${protected}" in *" ${run} "*) continue ;; esac
    if printf '%s\n' ${complete[@]+"${complete[@]}"} | grep -qx "${run}"; then
      [[ "${run}" < "${cutoff}" ]] || continue
      log "deleting expired run ${run}"
    else
      [[ "${run}" < "${incomplete_cutoff}" ]] || continue
      log "deleting incomplete run ${run}"
    fi
    rclone purge "${REMOTE}/${run}" || log "WARNING: could not delete ${run}"
  done < <(list_runs)
}

show_runs() {
  local complete=" " run restored=" "
  while IFS= read -r run; do complete="${complete}${run} "; done < <(list_complete_runs)
  while IFS= read -r run; do restored="${restored}${run%.txt} "; done < <(rclone lsf --files-only "${REMOTE}/_restores/" 2>/dev/null || true)
  while IFS= read -r run; do
    [ -n "${run}" ] || continue
    local state="incomplete" note=""
    case "${complete}" in *" ${run} "*) state="complete" ;; esac
    case "${restored}" in *" ${run} "*) note=" (restored before)" ;; esac
    printf '%s %s%s\n' "${run}" "${state}" "${note}"
  done < <(list_runs)
}

# --- restore ------------------------------------------------------------------

restore_marker_exists() {
  [ -n "$(rclone lsf --files-only "${REMOTE}/_restores/${RESTORE_RUN}.txt" 2>/dev/null || true)" ]
}

fetch_backup() {
  local manifest file file_sha rdb_sha got check_out
  manifest="${WORK}/MANIFEST.txt"
  rclone copyto "${REMOTE}/${RESTORE_RUN}/MANIFEST.txt" "${manifest}" 2>/dev/null \
    || die "run ${RESTORE_RUN} has no MANIFEST.txt in ${PREFIX}/ (incomplete or missing); see 'Redis Backup' logs or the Bucket's Files tab"
  file="$(manifest_value "${manifest}" file)"
  file_sha="$(manifest_value "${manifest}" file_sha256)"
  rdb_sha="$(manifest_value "${manifest}" rdb_sha256)"
  case "${file}" in dump.rdb|dump.rdb.gz) ;; *) die "unexpected file '${file}' in MANIFEST.txt" ;; esac
  log "downloading ${PREFIX}/${RESTORE_RUN}/${file}"
  rclone copyto --retries 3 "${REMOTE}/${RESTORE_RUN}/${file}" "${WORK}/${file}" || die "download of ${file} failed"
  got="$(sha256sum "${WORK}/${file}" | cut -d ' ' -f 1)"
  [ "${got}" = "${file_sha}" ] || die "checksum mismatch for ${file} (manifest ${file_sha}, downloaded ${got})"
  if [ "${file}" = dump.rdb.gz ]; then
    gzip -d -c "${WORK}/${file}" > "${WORK}/dump.rdb"
    rm -f "${WORK:?}/${file}"
  fi
  got="$(sha256sum "${WORK}/dump.rdb" | cut -d ' ' -f 1)"
  [ "${got}" = "${rdb_sha}" ] || die "checksum mismatch for dump.rdb (manifest ${rdb_sha}, got ${got})"
  if ! check_out="$(redis-check-rdb "${WORK}/dump.rdb" 2>&1)"; then
    printf '%s\n' "${check_out}" | tail -n 20 >&2
    die "redis-check-rdb rejected the downloaded snapshot"
  fi
  log "backup ${RESTORE_RUN} verified (sha256 and redis-check-rdb)"
}

start_helper() {
  local waited=0 loading
  HELPER_PASSWORD="$(head -c 32 /dev/urandom | sha256sum | cut -d ' ' -f 1)"
  # docker-entrypoint.sh adds --loadmodule for every bundled module, like on the Redis service.
  docker-entrypoint.sh redis-server --port "${RESTORE_PORT}" --bind '*' '-::*' --protected-mode yes \
    --requirepass "${HELPER_PASSWORD}" --dir "${WORK}" --dbfilename dump.rdb \
    --appendonly no --save '' --maxmemory 0 \
    --repl-diskless-sync yes --repl-diskless-sync-delay 0 \
    > "${WORK}/helper.log" 2>&1 &
  HELPER_PID=$!
  until [ "$(hcli PING 2>/dev/null || true)" = "PONG" ]; do
    kill -0 "${HELPER_PID}" 2>/dev/null || { tail -n 30 "${WORK}/helper.log" >&2; die "restore helper server exited"; }
    [ "${waited}" -ge 600 ] && die "restore helper server did not load the backup within 600s"
    sleep 2
    waited=$((waited + 2))
  done
  loading="$(info_field "$(hcli INFO persistence)" loading)"
  [ "${loading}" = "0" ] || die "restore helper server is still loading"
  log "restore helper server ready on port ${RESTORE_PORT}: $(keyspace_keys "$(hcli INFO keyspace)") keys"
}

# Address of this container as the Redis service sees it (CLIENT INFO addr=ip:port or [ipv6]:port).
own_address() {
  local addr
  addr="$(rcli CLIENT INFO 2>/dev/null | tr ' ' '\n' | sed -n 's/^addr=//p' | head -n 1)"
  addr="${addr%:*}"
  addr="${addr#"["}"
  addr="${addr%"]"}"
  printf '%s' "${addr}"
}

run_restore() {
  local addr waited=0 contact=0 repl link sync helper_keys target_keys mem used limit
  WORK="$(mktemp -d "${WORK_BASE%/}/redis-restore.XXXXXX")"
  log "RESTORE requested: ${PREFIX}/${RESTORE_RUN} will REPLACE all data in ${REDIS_HOST}:${REDIS_PORT}"
  fetch_backup
  start_helper
  helper_keys="$(keyspace_keys "$(hcli INFO keyspace)")"
  addr="$(own_address)"
  [ -n "${addr}" ] || die "could not determine this container's address from CLIENT INFO"
  log "making the Redis service a replica of ${addr}:${RESTORE_PORT} (writes are refused until the sync is done)"
  rcli CONFIG SET masterauth "${HELPER_PASSWORD}" > /dev/null || die "CONFIG SET masterauth failed"
  REPLICA_ACTIVE=1
  [ "$(rcli REPLICAOF "${addr}" "${RESTORE_PORT}" 2>&1 | tr -d '\r')" = "OK" ] || die "REPLICAOF was refused"
  while :; do
    sleep 5
    waited=$((waited + 5))
    repl="$(rcli INFO replication 2>&1 || true)"
    link="$(info_field "${repl}" master_link_status)"
    sync="$(info_field "${repl}" master_sync_in_progress)"
    if [ "${link}" = "up" ] && [ "${sync}" = "0" ]; then break; fi
    # Any sign of a sync (transfer running, link up, or LOADING) counts as contact.
    case "${sync}:${link}:${repl}" in 1:*|*:up:*|*LOADING*) contact=1 ;; esac
    if [ "${contact}" -eq 0 ] && [ "${waited}" -ge "${LINK_DOWN_LIMIT}" ]; then
      die "the Redis service could not connect to ${addr}:${RESTORE_PORT} within ${LINK_DOWN_LIMIT}s (private network); its data was not replaced"
    fi
    [ "${waited}" -ge "${RESTORE_TIMEOUT}" ] && die "sync not finished after ${RESTORE_TIMEOUT}s (BACKUP_RESTORE_TIMEOUT)"
    if [ $((waited % 30)) -eq 0 ]; then log "waiting for the sync (link ${link:-?}, in progress ${sync:-?})"; fi
  done
  promote_redis || die "the sync finished but REPLICAOF NO ONE kept failing"
  target_keys="$(keyspace_keys "$(rcli INFO keyspace 2>/dev/null || true)")"
  log "sync done: the Redis service is a primary again with ${target_keys} keys (backup had ${helper_keys})"
  if [ "${target_keys}" != "${helper_keys}" ]; then
    log "WARNING: key counts differ (expired keys or writes right after promotion can explain small differences)"
  fi
  mem="$(rcli INFO memory 2>/dev/null || true)"
  used="$(info_field "${mem}" used_memory)"
  limit="$(info_field "${mem}" maxmemory)"
  if [ -n "${used}" ] && [ -n "${limit}" ] && [ "${limit}" != "0" ] && [ "${used}" -gt "${limit}" ]; then
    log "WARNING: the restored data (${used} bytes) is above maxmemory (${limit}); raise REDIS_MAXMEMORY or the service's memory"
  fi
  hcli SHUTDOWN NOSAVE > /dev/null 2>&1 || true
  kill "${HELPER_PID}" 2>/dev/null || true
  wait "${HELPER_PID}" 2>/dev/null || true
  HELPER_PID=""
  printf 'restored=%s\nrun=%s\nkeys_in_backup=%s\nkeys_after_restore=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RESTORE_RUN}" "${helper_keys}" "${target_keys}" > "${WORK}/marker.txt"
  rclone copyto "${WORK}/marker.txt" "${REMOTE}/_restores/${RESTORE_RUN}.txt" \
    || log "WARNING: could not write the restore marker; clear BACKUP_RESTORE_RUN now so the next run does not restore again"
  log "restore of ${RESTORE_RUN} complete. Clear BACKUP_RESTORE_RUN; daily backups continue either way."
  rm -rf "${WORK}"
  WORK=""
}

# --- main ---------------------------------------------------------------------

main() {
  local cmd="${1:-run}"
  case "${cmd}" in
    run|backup|restore)
      validate_settings
      configure_remote
      if [ "${cmd}" != backup ] && [ -n "${RESTORE_RUN}" ]; then
        [[ "${RESTORE_RUN}" =~ ${RUN_RE} ]] || die "BACKUP_RESTORE_RUN must be a run folder name such as 20261031T032000Z (got '${RESTORE_RUN}')"
        if restore_marker_exists; then
          log "WARNING: ${RESTORE_RUN} was already restored (${PREFIX}/_restores/${RESTORE_RUN}.txt); skipping the restore and taking a normal backup. Clear BACKUP_RESTORE_RUN, or delete that marker to restore it again."
        else
          [ -n "$(rclone lsf --files-only "${REMOTE}/${RESTORE_RUN}/MANIFEST.txt" 2>/dev/null || true)" ] \
            || die "${PREFIX}/${RESTORE_RUN}/MANIFEST.txt not found: not a complete backup run (redis-backup list shows them)"
          wait_for_redis
          log "taking a safety backup of the current data before the restore"
          run_backup
          run_restore
          return 0
        fi
      elif [ "${cmd}" = restore ]; then
        die "set BACKUP_RESTORE_RUN to the run folder to restore"
      fi
      wait_for_redis
      run_backup
      prune
      log "done"
      ;;
    list)
      configure_remote
      show_runs
      ;;
    *)
      die "unknown command '${cmd}' (use: run, backup, restore, list)"
      ;;
  esac
}

main "$@"
