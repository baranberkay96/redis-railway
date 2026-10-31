# Redis 8 with RedisInsight UI and Persistence: Railway template spec

## Listing

| Field | Value |
|---|---|
| Name | **Redis 8 with RedisInsight UI and Persistence** (44 chars; `8` = Redis major of the pinned `redis:8.10.3`) |
| Description | Password-protected Redis 8 with JSON, Search, persistence and a web UI. (71 chars) |
| Category | Storage |
| Tags | redis, redisinsight, cache, key-value, redis-json, redis-search, vector-search, backups |
| Icon | `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/redis.svg` (200, image/svg+xml) |
| Template repo | `baranberkay96/redis-railway` (this folder); repo-built services from `/services/redisinsight-gateway` and `/services/backup` |

The listing is delivered as written: "password-protected" = generated `REDIS_PASSWORD` on every connection, protected mode, and a login in front of the UI; "JSON, Search" = RedisJSON and the Redis Query Engine bundled in the official Redis 8 image (verified in the image build, see below); "persistence" = AOF `everysec` + RDB snapshots on a volume; "web UI" = RedisInsight 3.8.0.

## Base market templates

Read through `template(code:)` on Railway's public GraphQL API (2026-10-31), stored in `86-redis/_market/`.

| Market template | Topology | Kept | Problems fixed |
|---|---|---|---|
| `redis` "Redis" (Railway, verified; 17,061 active, 4,685 deploys/30d) | one service `redis:8.2`, start command `redis-server --requirepass $REDIS_PASSWORD --save 60 1 --dir $RAILWAY_VOLUME_MOUNT_PATH`, volume `/data`, no TCP proxy in the template (Railway docs: public access is added by hand) | **Base**: service name `Redis`, variable names and layout, letters-only 32-char password, `rm lost+found` before start | Floating minor tag; RDB only (`save 60 1`: a fork per minute under any write load, up to 60 s lost on a crash); no `maxmemory`, so a growing dataset is OOM-killed; Docker default `protected-mode no`; no `REDIS_PUBLIC_URL` until public access is added by hand; no UI, no off-volume backups |
| `bitnami-redis` "Redis (Bitnami)" (8,976 active, 14 deploys/30d) | one service; image is now **`railwayapp/redis:8.2`**, which is a flattened copy of **Bitnami Redis 8.2.1** (debian-12, built 2025-08-18, amd64 only), volume `/bitnami`, `RAILWAY_RUN_UID=0` | Nothing beyond the base variables | Frozen since Aug 2025 after Bitnami moved its free images to `bitnamilegacy` (no updates). 8.2.1 predates the fixes for **CVE-2025-49844** (critical Lua use-after-free, fixed in 8.2.2) and CVE-2025-62507 (fixed in 8.2.3). README still says "Bitnami Redis 7.2.5"; `REDIS_AOF_ENABLED=no`; no TCP proxy, UI or backups |
| `675ZtP` "Redis Stack" (21 active) | `redis/redis-stack-server:latest`, TCP proxy, volume `/local-data`, `REDIS_ARGS` with AOF | Idea: modules + AOF + `REDIS_PUBLIC_URL` | `latest` tag; Redis Stack is the 7.x-era bundle (Redis 8 ships the modules in the core image); README lists RedisGraph and RedisAI, which are not in Redis Stack 7.4 |
| `redisinsight`, `redis-insight`, `redis-insights-redis-gui` (6, 0 and 3 active) | `redis/redisinsight:latest` on a **public domain without any login** | Port 5540, `RAILWAY_RUN_UID=0` for the `/data` volume | Anyone with the URL can open the UI and every database saved in it; `latest`; the market ones are not connected to a Redis |

Template code `redis-ha` (Railway's HA conversion) is referenced by the base and Bitnami templates; it is not reproduced (see Open questions).

## Pinned versions

| Service | Image / build | Version | Released | Digest (checked 2026-10-31) |
|---|---|---|---|---|
| Redis | `redis:8.10.3` (official, Debian trixie) | Redis Open Source 8.10.3 with RediSearch 8.10.1, RedisJSON 8.10.0, RedisTimeSeries 8.10.1, RedisBloom 8.10.1, Vector Sets | release 2026-10-26, image 2026-10-28 | index `sha256:298641b35ac51aa999f9bb85707d6681fe635ce59cda51886a0b6adc1da37b8e` (amd64 `sha256:10b9c2c0…`) |
| RedisInsight | `redis/redisinsight:3.8.0` | RedisInsight 3.8.0 (commit `815499a8`) | 2026-07-21 | `sha256:b5e19ee240abef6edb435871b90ff8a210995422e8e018ab61c0339d318a1f84` (amd64 + arm64) |
| RedisInsight Gateway | repo, `FROM caddy:2.11.7-alpine` | Caddy 2.11.7 | 2026-10-03 (image rebuilt 2026-10-30) | `sha256:e70b164da81ef698b3ad19af799ea6086ce6d9e48ed4079eb9fe26f6fbf14ee5` |
| Redis Backup | repo, `FROM redis:8.10.3-alpine` + `rclone/rclone:1.75.2` binary | redis-cli / redis-check-rdb 8.10.3, rclone 1.75.2 | Alpine image 2026-10-29; rclone 2026-10-09 | `sha256:21090af9…` / `sha256:2687085f…` |

- 8.10.3 is the newest stable 8.x patch (tags 8.10.0–8.10.3, 8.8.4, 8.6.8, 8.4.8, 8.2.11 all rebuilt 2026-10-28; `8.12-rc1` is a pre-release). The tag is pinned to the patch; Docker's official images are rebuilt under the same tag for base-OS fixes.
- **Upgrade Redis:** change `redis:8.10.3` on the Redis service and `FROM redis:8.10.3-alpine` in `services/backup/Dockerfile` in the same change (the backup's `redis-check-rdb` and restore server must read the server's RDB version). Newer RDB/AOF files cannot be read by older Redis, so test a downgrade path before rolling back across minors.
- **Upgrade RedisInsight / Caddy / rclone:** change the tag; nothing else depends on them.

### What the official Redis 8 image includes

From the image build history and `redis/docker-library-redis` v8.10.3: the image downloads `redis-full.tar.gz` and builds with `BUILD_WITH_MODULES=yes` on **amd64 and arm64** (other architectures get no modules), `BUILD_TLS=yes`. `make deploy` installs `redisearch.so`, `rejson.so`, `redistimeseries.so` and `redisbloom.so` into `/usr/local/lib/redis/modules/`, and `docker-entrypoint.sh` adds `--loadmodule` for every `.so` there. Vector Sets are compiled into `redis-server`. So the image really includes:

- Redis Query Engine (search: secondary indexes, full-text, vector similarity, aggregations; the community build `search-community`)
- JSON (RedisJSON)
- Time series (RedisTimeSeries)
- Probabilistic types (RedisBloom: Bloom and Cuckoo filters, Count-min sketch, Top-K, t-digest)
- Vector Sets (core data type)

Railway runs amd64, so all of them load. The verification checklist confirms it with `MODULE LIST`.

## Architecture

```
 Apps on Railway ── ${{Redis.REDIS_URL}} ─────────────────► Redis :6379  (bind * -::*, password, protected mode)
 External clients ── REDIS_PUBLIC_URL (TCP proxy) ───────►   │  volume /data: appendonlydir/ (AOF everysec) + dump.rdb
                                                              │  config written at boot from variables
 Browser ── HTTPS ──► RedisInsight Gateway :8080 ─────────►  │
   (login: basic auth, cross-site requests refused)  │       │
                                                      ▼       │
                           RedisInsight :5540 (private, ::) ─┘  preconfigured database "Redis on Railway"
                             volume /data (settings, encrypted saved passwords)

 Redis Backup (cron 03:20 UTC) ── redis-cli --rdb ──► Redis
        │ redis-check-rdb, gzip, sha256, rclone
        ▼
 Bucket: redis/{UTC timestamp}/dump.rdb.gz + MANIFEST.txt, redis/_restores/{run}.txt
        ▲
 Restore (BACKUP_RESTORE_RUN): helper redis-server in the job ◄── REPLICAOF ── Redis, then REPLICAOF NO ONE
```

## Services

### Redis

| Setting | Value |
|---|---|
| Source | image `redis:8.10.3` |
| Start command | `/bin/bash -c '{script}'` (2,709 chars; readable source `services/redis/redis-start.sh`, regenerate with `python3 services/redis/to-start-command.py --write`, verify with `--check`) |
| Volume | `/data` |
| Networking | private `redis.railway.internal:6379` (IPv4 + IPv6); **TCP proxy on 6379** |
| Healthcheck | none (TCP service; Railway marks it live when the container runs) |
| Restart | ALWAYS (also restarts after a client's `SHUTDOWN`) |
| Draining | `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=60` for the final snapshot and AOF fsync |

At every boot the start command:

1. Refuses to start without a URL-safe `REDIS_PASSWORD` of 16+ characters (the generated one is 32 letters).
2. Reads the container memory limit (`/sys/fs/cgroup/memory.max`, cgroup v1 fallback, never above `MemTotal`) and sets `maxmemory` to `REDIS_MAXMEMORY_PERCENT` (75) of it, unless `REDIS_MAXMEMORY` is a size or `0`.
3. Removes `lost+found`, records the AOF setting in `/data/.railway-appendonly`, and handles one dangerous transition: if the AOF is being switched on for data that so far only had `dump.rdb`, it moves any stale `appendonlydir` aside and sets `preload-file rdb:/data/dump.rdb` for that boot. Redis then loads the RDB and writes a new base AOF from it. Without this, Redis 8.10 starts empty (`loadDataFromDisk` does not fall back to the RDB when AOF is on) and the next save overwrites the old `dump.rdb`.
4. Writes `/etc/redis-railway/redis.conf` (mode 0600, owned by `redis`), appends `REDIS_EXTRA_CONFIG`, logs one summary line without the password, and `exec`s the image's `docker-entrypoint.sh redis-server /etc/redis-railway/redis.conf` (privilege drop to `redis`, modules loaded). `SKIP_FIX_PERMS=1` is set because the script already owns `/data` and the config to `redis`.

Generated `redis.conf`:

```
bind * -::*
protected-mode yes
requirepass {REDIS_PASSWORD}
dir /data
appendonly yes
appendfsync everysec
save 3600 1 300 100 60 10000
maxmemory {75% of the container limit}
maxmemory-policy noeviction
enable-protected-configs no
enable-debug-command no
enable-module-command no
{REDIS_EXTRA_CONFIG}
```

| Variable | Default | Purpose |
|---|---|---|
| `REDIS_PASSWORD` | `secret(32, letters)` | Password of the `default` user |
| `REDISPASSWORD`, `REDISUSER`, `REDISHOST`, `REDISPORT`, `REDIS_URL` | as Railway's Redis | Drop-in names; `REDIS_URL` is private |
| `REDIS_PUBLIC_URL` | `redis://default:...@${{RAILWAY_TCP_PROXY_DOMAIN}}:${{RAILWAY_TCP_PROXY_PORT}}` | External clients through the TCP proxy |
| `REDIS_MAXMEMORY` | `auto` | `auto`, a size (`256mb`, `2gb`) or `0` (no cap) |
| `REDIS_MAXMEMORY_PERCENT` | `75` | Share of the limit for `auto` (10–95) |
| `REDIS_MAXMEMORY_POLICY` | `noeviction` | Any Redis 8.10 policy, incl. `allkeys-lru`, `allkeys-lfu`, `allkeys-lrm`, `volatile-*` |
| `REDIS_APPENDONLY` | `yes` | AOF on/off |
| `REDIS_APPENDFSYNC` | `everysec` | `always`, `everysec`, `no` |
| `REDIS_SAVE` | `3600 1 300 100 60 10000` | RDB save points; `off` disables them |
| `REDIS_EXTRA_CONFIG` | empty | Extra `redis.conf` lines (ACL users, `io-threads`, ...) |

**Cache vs store.** The defaults are for a store (sessions, queues, documents): `noeviction` makes Redis refuse writes with an OOM error at the cap instead of deleting data, which BullMQ and Sidekiq require. A cache should set a fixed `REDIS_MAXMEMORY` (e.g. `256mb`) and `allkeys-lru`/`allkeys-lfu`; with `auto`, the cap follows the memory limit Railway exposes, which can be the plan's per-service maximum, and a cache would grow (and be billed) up to 75% of that before evicting. Pure caches can also set `REDIS_APPENDONLY=no` and `REDIS_SAVE=off` (no disk writes). The 25% headroom covers copy-on-write during the forks for RDB saves, AOF rewrites and backups.

**Dangerous commands policy** (documented in the README):

- Every connection needs the password; `protected-mode yes` is restored (the Docker image patches the default to `no`), so clearing the password through `REDIS_EXTRA_CONFIG` would make Redis refuse non-local clients instead of opening up.
- Blocked: `DEBUG` (`enable-debug-command no`), `MODULE LOAD/UNLOAD` (`enable-module-command no`), `CONFIG SET dir` and `dbfilename` (`enable-protected-configs no`). These are the commands used to write files or load code through Redis. They are Redis 7+ defaults, written explicitly so a future default change or an extra-config typo is visible.
- Allowed for `default`: everything else, including `FLUSHALL`, `KEYS`, `CONFIG GET/SET` (non-protected), `CLIENT`, `MONITOR`, `SHUTDOWN` (restart policy ALWAYS brings Redis back). Railway's Redis and most client libraries expect a full-access default user; RedisInsight needs `INFO`, `CONFIG GET`, `MODULE LIST`, `SCAN`, `MEMORY USAGE`, `FLUSHDB` and pub/sub.
- `rename-command` is deliberately not used: renamed commands break AOF replay when the AOF contains them. Least-privilege access is done with ACL users in `REDIS_EXTRA_CONFIG`, e.g. `user app on >{password} ~* &* +@all -@admin -flushall -flushdb`. Users defined there are re-created from the variable at every boot (no `aclfile`, so `ACL SAVE` is not used).

### RedisInsight

| Setting | Value |
|---|---|
| Source | image `redis/redisinsight:3.8.0`, unmodified |
| Volume | `/data` (`RI_APP_FOLDER_ABSOLUTE_PATH`: SQLite settings, saved databases, workbench history, plugin state) |
| Networking | private only, `redisinsight.railway.internal:5540`, `RI_APP_HOST=::` (Node, dual-stack) |
| Healthcheck | `GET /api/health` (`{"status":"up"}`) on `PORT=5540`, timeout 300 s |
| Restart | ALWAYS |

- **No login of its own.** The Docker build has no user authentication (checked in the 3.8.0 source: only Redis Cloud OAuth for cloud features), so the service has no public domain and is reachable only through the gateway.
- **Preconnected** through `RI_REDIS_HOST/PORT/USERNAME/PASSWORD/ALIAS` (all references to the Redis service). RedisInsight re-applies these "pre-setup" databases at every start (upsert by id), so a changed Redis password is picked up on the next RedisInsight restart.
- `RI_ENCRYPTION_KEY` (`secret(48)`) encrypts passwords stored in `/data` (AES-256-CBC with a SHA-256 of the key). Changing it later makes saved passwords unreadable.
- `RAILWAY_RUN_UID=0`: the image runs as `node`, Railway mounts volumes as root; Railway's documented fix is to run as root.
- `RI_ACCEPT_TERMS_AND_CONDITIONS=false`: the deployer accepts RedisInsight's terms (and chooses analytics) in the UI on the first visit, behind the gateway login. `true` accepts them with analytics and notifications off.
- `RI_STDOUT_LOGGER=true`, `RI_FILES_LOGGER=false`: logs in Railway, nothing growing on the volume.
- `RI_DATABASE_MANAGEMENT=true` (upstream default): other databases can be added in the UI; `false` locks it to the preconfigured one.

### RedisInsight Gateway

| Setting | Value |
|---|---|
| Source | repo `baranberkay96/redis-railway`, root `/services/redisinsight-gateway` (`FROM caddy:2.11.7-alpine`, Caddyfile validated at build) |
| Networking | public HTTPS domain → 8080 |
| Healthcheck | `GET /healthz` (unauthenticated, returns `ok`, no data) on `PORT=8080` |
| Restart | ALWAYS |

- `BASIC_AUTH_USERNAME=admin`, `BASIC_AUTH_PASSWORD=secret(32)`; the entrypoint refuses passwords under 16 characters, hashes it with bcrypt (`caddy hash-password`) and removes the plain value from Caddy's environment.
- Requests carrying an `Origin` header that is not `https://{host}` get 403. Browsers attach cached basic-auth credentials to cross-site requests and WebSocket handshakes, and RedisInsight's socket.io endpoints (Pub/Sub, Profiler, bulk delete) do not check the origin themselves; this blocks cross-site WebSocket hijacking and CSRF. The comparison uses the request's own host, so custom domains work. RedisInsight's plugin iframes are same-origin (`sandbox="allow-same-origin allow-scripts"`), so they are not affected.
- `X-Frame-Options: SAMEORIGIN` against clickjacking; `flush_interval -1` for streaming.

### Redis Backup

| Setting | Value |
|---|---|
| Source | repo `baranberkay96/redis-railway`, root `/services/backup` (non-root `redis` user, build fails if a tool or the modules are missing) |
| Cron | `20 3 * * *` (daily 03:20 UTC; Railway skips a run while the previous one is active) |
| Restart | NEVER (failures show as failed Cron Runs) |
| Volume / networking | none; private network to Redis |

Backup run (`services/backup/redis-backup.sh`):

1. Validates settings, waits up to `BACKUP_WAIT_SECONDS` for `PING` (fails fast on wrong credentials).
2. `redis-cli --rdb` (Redis forks and streams a fresh RDB over the replication protocol, `REPLCONF rdb-only`), into `BACKUP_WORK_DIR`.
3. `redis-check-rdb` on the file: a full structural check; module values (JSON, time series, Bloom, Search aux data) are parsed generically in check mode, so no modules are needed. Logs the key count.
4. gzip, SHA-256 of both the RDB and the uploaded file, `rclone copyto` to `{BACKUP_PREFIX}/{UTC timestamp}/dump.rdb.gz`, size check in the Bucket, then `MANIFEST.txt` last (run, Redis version, sizes, checksums, keys). A run without `MANIFEST.txt` is incomplete.
5. Retention (same rules as the pgvector template): complete runs older than `BACKUP_RETENTION_DAYS` (14) are deleted, but the newest `BACKUP_KEEP_MIN` (3) are always kept; incomplete runs older than 2 days are deleted; other folders (e.g. `_restores`) are ignored. A failed run deletes nothing.

On demand: `railway cron run --service "Redis Backup"`. List: Bucket → Files, or `redis-backup list` in the job.

### Bucket

Railway Bucket `Bucket` (private, S3-compatible, virtual-hosted URLs). Referenced as `BUCKET`, `ENDPOINT`, `REGION`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`. Buckets have no lifecycle rules, so retention lives in the job.

## Restore

Railway volumes cannot be written from outside, so the restore goes through Redis replication:

1. Redis Backup → Variables: set `BACKUP_RESTORE_RUN` to a complete run folder (e.g. `20261031T032000Z`), deploy, then `railway cron run --service "Redis Backup"` (or wait for the schedule).
2. The job checks the run's `MANIFEST.txt`, takes a **safety backup of the current data** (a normal run), downloads the chosen dump, verifies both SHA-256 values and `redis-check-rdb`.
3. It starts a helper `redis-server` inside the job (same 8.10.3 build, all modules loaded through `docker-entrypoint.sh`) on `BACKUP_RESTORE_PORT` (6390) with a random password, loads the dump, and asks Redis for the job's own address (`CLIENT INFO addr=`, IPv4 or `[IPv6]`).
4. On Redis: `CONFIG SET masterauth {random}`, `REPLICAOF {job address} 6390`. Redis does a full sync (all databases, functions, module data and Search index definitions), rewrites its AOF, and refuses writes (READONLY) meanwhile. The job waits for `master_link_status:up` and `master_sync_in_progress:0`, then `REPLICAOF NO ONE` and clears `masterauth`. It compares key counts and warns if the data is above `maxmemory`.
5. It writes `{prefix}/_restores/{run}.txt`. A run with that marker is never restored again (the next runs take normal backups and log a warning), so a forgotten `BACKUP_RESTORE_RUN` cannot roll the data back every night. Clear the variable; delete the marker to restore the same run twice.

Failure handling: if Redis cannot connect to the job within 180 s (private network), the job promotes Redis back, and its data was not replaced. Any failure after `REPLICAOF` promotes Redis back too (retrying while Redis answers LOADING, up to 15 minutes). Outside Railway, any Redis 8.10 with the same modules loads the downloaded `dump.rdb` (`redis-server --dbfilename dump.rdb --dir {folder}` with the modules, AOF off at first).

## Required input

None. Passwords and keys come from `secret()`; Redis, RedisInsight, the gateway and the backup job are wired by reference; the Bucket is created by the template.

## First login

1. Open the RedisInsight Gateway's public URL; log in with `BASIC_AUTH_USERNAME` / `BASIC_AUTH_PASSWORD` from its Variables tab.
2. Accept RedisInsight's terms (privacy choices are yours).
3. Open "Redis on Railway" → Workbench: `MODULE LIST`, `JSON.SET doc $ '{"a":1}'`, `FT._LIST`.
4. From another Railway service, reference `${{Redis.REDIS_URL}}`.

## Improvements over market templates

1. **Redis 8.10.3**, pinned and current, with the Query Engine, JSON, time series, probabilistic types and Vector Sets (Railway: floating `redis:8.2`; Bitnami: frozen 8.2.1 without the CVE-2025-49844 fix; Redis Stack: `latest` of the 7.x line).
2. **Drop-in variables** of Railway's Redis (`Redis` service name, `REDIS_URL` private, `REDISHOST/PORT/USER/PASSWORD`, `REDIS_PASSWORD`) plus `REDIS_PUBLIC_URL` with a TCP proxy, so `${{Redis.REDIS_URL}}` references keep working.
3. **Durability**: AOF `everysec` + RDB (Railway: RDB every 60 s only), 60 s draining for the final snapshot, safe AOF switch-on through `preload-file`.
4. **Memory cap from the container limit** with a documented cache/store policy choice (no market template sets `maxmemory`).
5. **Hardening**: protected mode back on, password validation, `DEBUG`/`MODULE`/protected configs blocked explicitly, ACL users through a variable.
6. **RedisInsight behind a login**, preconnected, with encrypted saved passwords and no terms accepted on the user's behalf (market RedisInsight templates are public without any login).
7. **Daily verified backups** to a Railway Bucket with retention, and an **automated restore** with a safety backup and a one-shot guard (no market template backs up).
8. Dual-stack listeners everywhere, pinned images, a description on every variable, no required input.

## Resource estimate

Railway prices: RAM $10/GB-month, vCPU $20/vCPU-month, volume $0.15/GB-month, Bucket $0.015/GB-month, egress $0.05/GB (uploads to a Bucket count as service egress). Not measured (no container run this round).

| Service | Idle RAM / CPU | Typical RAM / CPU (≈500 MB data) | Notes |
|---|---|---|---|
| Redis | 0.03 GB / 0.005 | 0.7 GB / 0.03 | Data + overhead; forks for saves/backups add copy-on-write briefly |
| RedisInsight | 0.15 GB / 0.005 | 0.2 GB / 0.01 | Node.js; most of the idle cost |
| RedisInsight Gateway | 0.015 GB / ~0 | 0.02 GB / 0.002 | Caddy |
| Redis Backup | 0 between runs | ~0.1 GB for 1–2 min a day | Restore runs need RAM for a second copy of the data |
| Volumes | 0.15 GB | 1.3 GB (AOF + RDB ≈ 2× data, + RedisInsight) | Hobby volumes 5 GB |
| Bucket | ~0 | ~2.5 GB (14 × 0.17 GB gz) | + ~5 GB/month upload egress |

Estimated monthly cost: **idle ≈ $2.5** (0.2 GB × $10 + 0.01 vCPU × $20 + 0.15 GB × $0.15), **typical ≈ $10.5** (0.92 GB × $10 + 0.04 vCPU × $20 + 1.3 GB × $0.15 + 2.5 GB × $0.015 + 5 GB × $0.05), busy (4 GB data, 0.5 vCPU) ≈ $68.

Minimum plan: **Trial** boots it (1 GB RAM per service: `auto` gives Redis a 768 MB cap; 0.5 GB volumes), if Buckets are available on the account; **Hobby** recommended for real data.

## Verification checklist

Static checks done this round: see `_reports/round7/86-redis.md`. On the first Railway deploy:

- [ ] All four services deploy; both repo builds pass their build-time checks (`caddy validate`; `redis-cli 8.10`, modules present, rclone).
- [ ] Redis log: `redis-railway: maxmemory ... (75% of ...)` with a plausible limit, `Module 'search' loaded`, `ReJSON`, `timeseries`, `bf`, then `Ready to accept connections tcp`. No `Unknown file ... found in data dir` notice (perm fix skipped on purpose).
- [ ] From RedisInsight's CLI or `redis-cli -u "$REDIS_PUBLIC_URL"`: `MODULE LIST` shows search, ReJSON, timeseries, bf; `CONFIG GET maxmemory*`, `CONFIG GET appendonly`, `CONFIG GET protected-mode` → yes; `DEBUG SLEEP 0` and `MODULE LOAD /x` are refused ("command not allowed"), `MODULE LIST` still works (only LOAD/LOADEX/UNLOAD carry the protected flag in 8.10.3); `CONFIG SET dir /tmp` is refused.
- [ ] `redis-cli -h {proxy} -p {port} PING` without password → `NOAUTH`.
- [ ] Gateway URL without credentials → 401; with credentials → RedisInsight loads, "Redis on Railway" connects; Browser, Workbench and Pub/Sub (WebSocket) work. `curl -H "Origin: https://evil.example" -u admin:{pw} {url}/api/info` → 403. `/healthz` → 200.
- [ ] Persistence: `SET k v`, redeploy Redis → `GET k` still returns `v`; log shows `DB loaded from append only file`.
- [ ] AOF switch: set `REDIS_APPENDONLY=no`, redeploy, write a key, set it back to `yes`, redeploy → log `AOF was off: loading dump.rdb once`, key present.
- [ ] `railway cron run --service "Redis Backup"` → Bucket has `redis/{timestamp}/dump.rdb.gz` + `MANIFEST.txt`; log shows `redis-check-rdb` key count.
- [ ] Restore: write keys, back up, change keys, set `BACKUP_RESTORE_RUN={run}`, deploy, run → log `sync done`, the old keys are back, `_restores/{run}.txt` exists; a second run takes a normal backup with the warning.
- [ ] RedisInsight redeploy keeps settings (volume) and the database entry.

## Open questions

- **Restore connectivity (unverified):** the restore needs Redis to open a connection *to the cron job's container* on port 6390 over the private network, by IP (from `CLIENT INFO`). Railway documents service-to-service private networking but not whether cron-run containers accept inbound connections. If not, the job fails after 180 s, Redis is promoted back unchanged, and the dump must be restored manually.
- **Start command length (2,709 chars):** about 100 chars longer than the pgvector start command that deployed fine. If Railway rejects it, the fallback is a repo-built Redis image with the same script as an entrypoint.
- **cgroup values on Railway:** `memory.max` may be the plan's per-service maximum, so `auto` can be very large. Documented; a fixed `REDIS_MAXMEMORY` is the recommendation for caches.
- **Railway Data tab / HA:** whether Railway's database Data tab and the Redis HA conversion (`redis-ha`) appear for this service is unverified; HA conversion would likely replace the custom start command.
- **TCP proxy on by default:** follows the brief and Railway's older default; Railway's current docs make public access opt-in. Plain Redis protocol (no TLS) over the proxy, protected by the 32-character password.
- **Basic auth and WebSockets in Safari** (unverified): some browsers do not send cached basic-auth credentials on WebSocket upgrades; socket.io then falls back to HTTP long-polling.
- **Memory overcommit:** Railway does not let containers set `vm.overcommit_memory=1`; Redis logs a warning, and a fork can fail under memory pressure (backups and saves then fail and retry).
- **Backup scratch space:** the snapshot is written to the container's ephemeral disk before upload; its size limit on Railway is not documented.
