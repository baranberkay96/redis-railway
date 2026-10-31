# Redis start command for Railway: readable source of the "Redis" startCommand.
# to-start-command.py joins it into one line, wraps it in /bin/bash -c '...',
# and checks that template.json carries the current version.
# Rules for this file: no single quotes, no backslashes, one statement per line
# (a line ending in then/do/else is joined to the next with a space).
#
# At every boot it writes /etc/redis-railway/redis.conf from the service
# variables, then hands over to the image's own entrypoint (privilege drop to
# the redis user, --loadmodule for every bundled module). Values Redis itself
# validates (eviction policy, fsync policy, extra config) are not re-checked here:
# Redis refuses to start and logs the reason.
set -eu
D="${RAILWAY_VOLUME_MOUNT_PATH:-/data}"
D="${D%/}"
C=/etc/redis-railway
F="$C/redis.conf"
log() { echo "redis-railway: $*"; }
num() { case "$1" in ""|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
low() { echo "$1" | tr "[:upper:]" "[:lower:]"; }
w() { echo "$*" >> "$F"; }
# The password goes into redis.conf and REDIS_URL: URL-safe characters, 16 or more.
P="${REDIS_PASSWORD:-}"
R="^[A-Za-z0-9._~-]{16,}$"
if [[ ! "$P" =~ $R ]]; then log "REDIS_PASSWORD needs 16+ characters of A-Z a-z 0-9 . _ ~ -"; exit 1; fi
# Memory limit of the container (cgroup v2, then v1), never above the host RAM.
H=$(( $(num "$(grep -m 1 MemTotal /proc/meminfo | tr -s " " | cut -d " " -f 2)" 1048576) * 1024 ))
L=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo max)
L=$(num "$L" "$H")
if [ "$L" -gt "$H" ]; then L=$H; fi
MM=$(low "${REDIS_MAXMEMORY:-auto}")
PCT=$(num "${REDIS_MAXMEMORY_PERCENT:-75}" 75)
if [ "$PCT" -lt 10 ] || [ "$PCT" -gt 95 ]; then PCT=75; fi
R="^[0-9]+([kmg]b?)?$"
if [ -z "$MM" ] || [ "$MM" = auto ]; then MM=$(( L / 100 * PCT )); MS="${PCT}% of ${L}"; elif [[ "$MM" =~ $R ]]; then MS=REDIS_MAXMEMORY; else log "REDIS_MAXMEMORY must be auto, 0 or a size like 512mb"; exit 1; fi
AOF=$(low "${REDIS_APPENDONLY:-yes}")
case "$AOF" in yes|true|on|1) AOF=yes ;; *) AOF=no ;; esac
SAVE=$(low "${REDIS_SAVE-3600 1 300 100 60 10000}")
case "$SAVE" in off|none|no|false) SAVE="" ;; esac
R="^[0-9 ]*$"
if [[ ! "$SAVE" =~ $R ]]; then log "REDIS_SAVE must be seconds/changes pairs or off"; exit 1; fi
mkdir -p "$D"
rm -rf "$D/lost+found"
cd "$D"
# AOF switched on for data that so far only had dump.rdb: load the RDB once
# (preload-file) so Redis builds the new AOF from it instead of starting empty.
M="$D/.railway-appendonly"
PRE=""
if [ "$AOF" = yes ] && [ -s dump.rdb ] && { [ ! -d appendonlydir ] || [ "$(cat "$M" 2>/dev/null || true)" = no ]; }; then
if [ -d appendonlydir ]; then rm -rf appendonlydir.stale-*; mv appendonlydir "appendonlydir.stale-$(date -u +%Y%m%dT%H%M%SZ)"; fi
PRE="preload-file rdb:$D/dump.rdb"
log "AOF was off: loading dump.rdb once to build the AOF"
fi
echo "$AOF" > "$M"
chown -R redis:redis "$D"
umask 077
mkdir -p "$C"
: > "$F"
w "bind * -::*"
w "protected-mode yes"
w "requirepass $P"
w "dir $D"
w "appendonly $AOF"
w "appendfsync $(low "${REDIS_APPENDFSYNC:-everysec}")"
if [ -n "$SAVE" ]; then w "save $SAVE"; fi
if [ -n "$PRE" ]; then w "$PRE"; fi
w "maxmemory $MM"
w "maxmemory-policy $(low "${REDIS_MAXMEMORY_POLICY:-noeviction}")"
w "enable-protected-configs no"
w "enable-debug-command no"
w "enable-module-command no"
if [ -n "${REDIS_EXTRA_CONFIG:-}" ]; then echo "$REDIS_EXTRA_CONFIG" >> "$F"; fi
chown -R redis:redis "$C"
export SKIP_FIX_PERMS=1
log "maxmemory $MM ($MS), appendonly $AOF, save ${SAVE:-off}, dir $D"
if [ -z "$SAVE" ]; then exec docker-entrypoint.sh redis-server "$F" --save ""; fi
exec docker-entrypoint.sh redis-server "$F"
