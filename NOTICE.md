# NOTICE

This Railway template is a community package. It is not affiliated with or endorsed by Redis Ltd., the Caddy project, the rclone project or Railway. "Redis" and "RedisInsight" are used only to name the software the template runs.

Nothing in this file is legal advice. If you offer Redis or RedisInsight to third parties as a service, or modify and distribute them, read the licenses below or ask a lawyer.

## What this template runs

| Component | Source | License |
|---|---|---|
| Redis Open Source 8.10.3 | official image `redis:8.10.3` (built from the `redis-full` 8.10.3 release tarball), used unmodified | Tri-licensed since Redis 8.0, at your choice: Redis Source Available License v2 (RSALv2), Server Side Public License v1 (SSPLv1) or GNU Affero General Public License v3 (AGPLv3) (`LICENSE.txt` at tag 8.10.3). Redis 7.2 and earlier remain BSD-3-Clause. |
| Bundled modules: Redis Query Engine (RediSearch 8.10.1), RedisJSON 8.10.0, RedisTimeSeries 8.10.1, RedisBloom 8.10.1; Vector Sets (built into the server) | inside the official image (`/usr/local/lib/redis/modules/`, pinned in `modules/modules.yaml` at tag 8.10.3) | Same RSALv2 / SSPLv1 / AGPLv3 choice for Redis 8 versions (each module's `LICENSE.txt`) |
| Official Redis image build files and `docker-entrypoint.sh` | https://github.com/redis/docker-library-redis (tag `v8.10.3`), used through the published image, not copied | BSD-3-Clause, Copyright (c) 2014 Docker, Inc. |
| RedisInsight 3.8.0 | official image `redis/redisinsight:3.8.0`, used unmodified | Server Side Public License v1 (repository `LICENSE` at tag 3.8.0). RedisInsight also shows its own terms in the UI on first use (or they are accepted through `RI_ACCEPT_TERMS_AND_CONDITIONS=true`, which the template leaves off). |
| Caddy 2.11.7 | base image `caddy:2.11.7-alpine` of the RedisInsight Gateway | Apache-2.0 (Caddy and https://github.com/caddyserver/caddy-docker) |
| rclone 1.75.2 | binary copied from the official image `rclone/rclone:1.75.2` into the backup image | MIT |
| Backup image base | `redis:8.10.3-alpine` (Alpine 3.23) with Alpine packages `bash` and `coreutils` (GPL-3.0-or-later) and `ca-certificates` (MPL-2.0 and others), installed at build time | per package |

RedisInsight sends usage analytics only if the user agrees in its first-run dialog; with `RI_ACCEPT_TERMS_AND_CONDITIONS=true` analytics and notifications are off.

## Files written for this template

- `services/redis/redis-start.sh` and `services/redis/to-start-command.py`: the Redis start command (readable source and the generator that joins it into `template.json`). The script writes a config file and then calls the image's own `docker-entrypoint.sh`; no file from the image or its repository is copied.
- `services/redisinsight-gateway/` (`Dockerfile`, `Caddyfile`, `entrypoint.sh`): the login gateway. Adapted from this project's own Redpanda Console gateway (`43-redpanda`), same author.
- `services/backup/` (`Dockerfile`, `redis-backup.sh`): the backup and restore job. The rclone setup and retention logic are adapted from this project's own pgvector backup job (`56-pgvector`), same author.
- `TEMPLATE.md`, `README.md`, `template.json`, this file.

## Reused or not reused

- The marketplace templates `redis` (Railway), `bitnami-redis`, `675ZtP` (Redis Stack) and the three RedisInsight templates (`redis-insights-redis-gui`, `redis-insight`, `redisinsight`) carry no license. They were read for their settings through Railway's public API (stored in `86-redis/_market/`); no README or description text from them is reused.
- Railway's base Redis definition (`templates/_railway-base/redis.json`): the service name `Redis` and the variable names and layout are kept for compatibility, with new descriptions.

## Upstream material checked (2026-10-31)

- `redis/redis` tag **8.10.3** (release 2026-10-26; newest stable, 8.12-rc1 is a pre-release): `LICENSE.txt`; `modules/modules.yaml` (redisbloom v8.10.1, redisearch v8.10.1, redisjson v8.10.0, redistimeseries v8.10.1); `src/Makefile` (vector-sets compiled into the server); `scripts/deploy.sh` (modules installed to `/usr/local/lib/redis/modules`, `redis-check-rdb` symlink); `src/config.c` (default `bind * -::*`, protected configs = `dir` and `dbfilename`, eviction policies incl. `allkeys-lrm`/`volatile-lrm`, `preload-file`); `src/server.c` `loadDataFromDisk` (AOF on without AOF files does not fall back to `dump.rdb`; `preload-file` does); `src/aof.c` `aofOpenIfNeededOnServerStart` (base AOF written from the loaded data); `src/redis-check-rdb.c` and `src/rdb.c` (module values checked without the modules); `src/redis-cli.c` (`--rdb`, `REDISCLI_AUTH`); `src/connection.h` `formatAddr` (IPv6 client addresses shown as `[ip]:port`); `redis.conf` (`preload-file` documentation).
- `redis/docker-library-redis` tag **v8.10.3**: `debian/Dockerfile`, `alpine/Dockerfile` (modules built on amd64 and arm64 only; protected mode default patched to off, which this template turns back on), `debian/docker-entrypoint.sh` and `alpine/docker-entrypoint.sh` (privilege drop, `SKIP_FIX_PERMS`, `--loadmodule` for every module).
- Docker Hub image configs: `redis:8.10.3` (index `sha256:298641b3…`, amd64 manifest `sha256:10b9c2c0…`, created 2026-10-28, `REDIS_VERSION=8.10.3`, no `VOLUME`), `redis:8.10.3-alpine` (`sha256:21090af9…`), `redis/redisinsight:3.8.0` (`sha256:b5e19ee2…`, amd64 + arm64, created 2026-07-20, user `node`, `RI_APP_FOLDER_ABSOLUTE_PATH=/data`, port 5540), `caddy:2.11.7-alpine` (`sha256:e70b164d…`), `rclone/rclone:1.75.2` (`sha256:2687085f…`). Bitnami template image `railwayapp/redis:8.2`: a flattened copy of Bitnami Redis 8.2.1 (debian-12, created 2025-08-18, amd64 only).
- `redis/RedisInsight` tag **3.8.0** (release 2026-07-21): `LICENSE` (SSPLv1), `Dockerfile`, `docker-entry.sh`, `redisinsight/api/config/default.ts` and `production.ts` (`RI_APP_HOST`, `RI_APP_PORT`, `RI_ENCRYPTION_KEY`, `RI_ACCEPT_TERMS_AND_CONDITIONS`, `RI_DATABASE_MANAGEMENT`, logger switches), `database-discovery/utils/pre-setup.discovery.util.ts` and `pre-setup.database-discovery.service.ts` (`RI_REDIS_HOST/PORT/USERNAME/PASSWORD/ALIAS`, re-applied at every start), `settings.service.ts` (accepting terms by variable turns analytics off), `server/health.controller.ts` (`GET /api/health`), `QueryCardCliPlugin.tsx` (plugin iframes are same-origin). RedisInsight has no login for the Docker build.
- `caddyserver/caddy` v2.11.7 `modules/caddyhttp/matchers.go` (header matcher values support placeholders, `*` matches any value).
- `rclone/rclone` v1.75.2 `Dockerfile` (static binary at `/usr/local/bin/rclone`).
- Redis security advisories on GitHub (CVE-2025-49844 fixed in 8.2.2, CVE-2025-62507 fixed in 8.2.3).
- Railway documentation: Redis (variables, public access through a TCP proxy), Volumes (mounted as root, `RAILWAY_RUN_UID=0`, `RAILWAY_VOLUME_MOUNT_PATH`), Cron Jobs (skipped runs, `railway cron run`, 5-minute minimum), Storage Buckets.
