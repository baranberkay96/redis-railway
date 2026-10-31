# Deploy and Host Redis with Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/redis-8-with-redisinsight-ui-and-persist?referralCode=20H68q)

Redis is an in-memory data store used as a cache, session store, queue backend and document and vector database. This community template runs Redis 8.10 from the official image with a generated password, AOF and RDB persistence on a volume, the RedisInsight web UI behind a login, and daily backups to a Railway Bucket.

## About Hosting Redis

Running Redis well takes more than starting the server. It needs a password on every connection, persistence that survives restarts and redeploys, a memory cap below the container limit so the kernel does not kill it, and copies of the data outside the volume. This template keeps Railway's Redis service name and variables, so `${{Redis.REDIS_URL}}` references keep working, and adds those pieces: append-only file plus snapshots, a memory cap sized from the service's limit, RedisInsight preconnected to your database behind a password gateway, and a cron job that writes verified RDB backups with retention and can restore them.

## Common Use Cases

- Cache and session store for web apps, with an eviction policy you choose
- Job queues and background workers (BullMQ, Sidekiq, Celery, RQ) that need durable data
- JSON documents with secondary indexes, full-text and vector search through the Redis Query Engine
- Rate limiting, leaderboards, counters, pub/sub and streams
- Time series and probabilistic structures (Bloom, Cuckoo, Count-min, Top-K, t-digest)

## Dependencies for Redis Hosting

- Redis 8.10.3, official `redis` image with the bundled modules (included)
- RedisInsight 3.8.0, official `redis/redisinsight` image (included)
- A Caddy gateway that adds the login in front of RedisInsight (included, built from this repo)
- A Railway Bucket for backups (included, created by the template)

### Deployment Dependencies

- Redis documentation: https://redis.io/docs/latest/
- Redis Docker image: https://hub.docker.com/_/redis
- RedisInsight: https://github.com/redis/RedisInsight
- Caddy basic_auth: https://caddyserver.com/docs/caddyfile/directives/basic_auth
- Railway Storage Buckets: https://docs.railway.com/storage-buckets
- Railway cron jobs: https://docs.railway.com/cron-jobs

### Implementation Details

| Service | Image | Purpose |
|---|---|---|
| Redis | `redis:8.10.3` | Redis with Query Engine, JSON, time series and probabilistic modules plus vector sets; volume at `/data`; TCP proxy for external clients |
| RedisInsight | `redis/redisinsight:3.8.0` | Web UI, private only, preconnected to Redis; volume at `/data` for its settings |
| RedisInsight Gateway | built from `services/redisinsight-gateway` | Public HTTPS entry with a login (Caddy basic auth) |
| Redis Backup | built from `services/backup` | Daily cron (03:20 UTC): RDB snapshot, `redis-check-rdb`, upload, 14-day retention (at least 3 kept) |
| Bucket | Railway Bucket | Private storage for the backups |

**Connecting.** Other Railway services reference `${{Redis.REDIS_URL}}` (private network). `REDISHOST`, `REDISPORT`, `REDISUSER`, `REDISPASSWORD` and `REDIS_PASSWORD` exist with the same names as Railway's Redis. `REDIS_PUBLIC_URL` goes through the TCP proxy for clients outside Railway. It is password-protected but not encrypted, and the traffic is billed as egress. If you do not need it, remove the proxy under Redis → Settings → Networking.

**First login to RedisInsight**

1. Open the public URL of the RedisInsight Gateway service.
2. Log in with `BASIC_AUTH_USERNAME` (`admin`) and `BASIC_AUTH_PASSWORD` from that service's Variables tab.
3. Accept RedisInsight's terms on the first visit, or set `RI_ACCEPT_TERMS_AND_CONDITIONS=true` on the RedisInsight service (analytics and notifications then stay off).
4. Open the database "Redis on Railway". It is already configured with the private hostname and password.

**Cache or store.** By default Redis behaves as a store: `REDIS_MAXMEMORY=auto` caps memory at 75% of the service's memory limit, and `noeviction` refuses writes at the cap instead of deleting keys, which queues need. For a cache, set `REDIS_MAXMEMORY` to a fixed size such as `256mb` and `REDIS_MAXMEMORY_POLICY=allkeys-lru`. On Railway the limit Redis sees can be your plan's per-service maximum, so a cache without a fixed size can grow, and be billed, far beyond what it needs. For a pure cache, also set `REDIS_APPENDONLY=no` and `REDIS_SAVE=off`.

**Persistence.** The append-only file is written with `fsync` every second, so a crash loses at most about one second of writes. RDB snapshots follow Redis's default schedule, and on redeploy Redis writes a final snapshot (`RAILWAY_DEPLOYMENT_DRAINING_SECONDS=60`). If you switch the AOF on later, the start script loads the existing `dump.rdb` once so the data is kept.

**Commands and security.** Every connection needs the password, and protected mode is on. `DEBUG`, `MODULE LOAD` and `CONFIG SET dir/dbfilename`, which attackers use to write files or load code, are disabled. The `default` user keeps every other command, so client libraries and RedisInsight work unchanged. To give an app fewer rights, add an ACL user in `REDIS_EXTRA_CONFIG` (raw editor, one directive per line), for example `user app on >{long-password} ~* &* +@all -@admin -flushall -flushdb`, and test your client with it.

**Backups.** Each run writes `redis/{timestamp}/dump.rdb.gz` and a `MANIFEST.txt` with checksums to the Bucket. Start one now with `railway cron run --service "Redis Backup"`. Runs are listed in the Bucket's Files tab.

**Restore.** Set `BACKUP_RESTORE_RUN` on Redis Backup to a run folder name, deploy, then trigger a run. The job first backs up the current data. It then loads the chosen backup into a temporary Redis inside the job, makes your Redis a replica of it, and promotes it back once the sync is done. All data is replaced, and writes fail with READONLY during the sync. A run is restored only once; clear the variable afterwards. Any Redis 8.10 with the same modules can also load the downloaded `dump.rdb` directly.

**Scaling.** Give Redis more memory in its settings. `auto` follows the new limit at the next restart, or set `REDIS_MAXMEMORY`. Hobby volumes start at 5 GB. The AOF and snapshots together need about twice the data size on disk.

**Versions.** Images are pinned: `redis:8.10.3` and `redis/redisinsight:3.8.0`. To upgrade Redis, change the image tag and the `FROM redis:...` line in `services/backup/Dockerfile` together. Downgrading to an older Redis cannot read newer data files.

**Licenses.** Redis 8 is available under RSALv2, SSPLv1 or AGPLv3, at your choice. RedisInsight is SSPLv1. This is not legal advice: check the terms if you offer Redis to third parties as a service. This template is not affiliated with Redis Ltd.

**Cost.** Roughly $2.50 per month idle and about $10 per month with around 500 MB of data and daily backups, at Railway's usage prices. Most of the idle cost is RedisInsight; you can remove the RedisInsight and RedisInsight Gateway services and keep Redis, backups and the Bucket.

### Why Deploy Redis on Railway?

Railway runs Redis, its web UI and the backup job together on a private network, with persistent volumes and a managed bucket, so you get a protected Redis with a UI in a few minutes without managing servers. Apps in the same project connect through `${{Redis.REDIS_URL}}`, and you grow it by raising the service limits and the volume size.
