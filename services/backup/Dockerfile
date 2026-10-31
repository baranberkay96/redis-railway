# Redis Backup (Railway cron job): redis-cli --rdb, redis-check-rdb and rclone.
#
# Built on the same Redis release as the Redis service (8.10.3, Alpine variant with
# the bundled modules), so redis-check-rdb understands the RDB format and the
# restore helper server can load JSON, Search, time series and probabilistic data.
# When the Redis service moves to a new release, bump this tag in the same change.
FROM rclone/rclone:1.75.2 AS rclone

FROM redis:8.10.3-alpine

RUN apk add --no-cache bash coreutils ca-certificates

# Static Go binary from the official rclone image (CGO disabled upstream).
COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --chmod=755 redis-backup.sh /usr/local/bin/redis-backup

ENV HOME=/tmp

# Fail the build early if a tool or the bundled modules are missing.
RUN redis-cli --version | grep -q ' 8\.10\.' \
 && redis-check-rdb --version >/dev/null \
 && redis-server --version >/dev/null \
 && ls /usr/local/lib/redis/modules/*.so >/dev/null \
 && rclone version >/dev/null \
 && date -u -d @0 +%Y >/dev/null \
 && sha256sum --version >/dev/null

USER redis
WORKDIR /tmp

ENTRYPOINT ["/usr/local/bin/redis-backup"]
CMD ["run"]
