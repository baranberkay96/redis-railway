# Basic-auth reverse proxy for RedisInsight (RedisInsight has no login of its own).
FROM caddy:2.11.7-alpine

COPY Caddyfile /etc/caddy/Caddyfile
COPY --chmod=0755 entrypoint.sh /usr/local/bin/redisinsight-gateway-entrypoint.sh

# Validate with placeholder values (the real ones come from the environment at start).
RUN BASIC_AUTH_USERNAME=check BASIC_AUTH_HASH='$2a$14$abcdefghijklmnopqrstuuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0' REDISINSIGHT_UPSTREAM=localhost:5540 \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/redisinsight-gateway-entrypoint.sh"]
