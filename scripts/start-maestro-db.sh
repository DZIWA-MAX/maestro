#!/usr/bin/env bash
#
# Provisions the persistent Postgres that the "local-db" Spring profile points
# at, replacing the throwaway database `./gradlew bootRun` gets by default.
#
# The default `jdbc:tc:postgresql:17:///maestro_local` asks Testcontainers for a
# fresh container on every boot, so everything created through the API dies with
# the process -- a workflow created in one run answers 404 in the next. This
# container instead keeps its data in a named Docker volume, which outlives both
# the server process and the container it runs in.
#
# Safe to re-run: creates the container when missing, starts it when stopped,
# and does nothing when it is already up.

set -euo pipefail

CONTAINER=${MAESTRO_DB_CONTAINER:-maestro-postgres}
VOLUME=${MAESTRO_DB_VOLUME:-maestro-pgdata}
PORT=${MAESTRO_DB_PORT:-5432}
IMAGE=postgres:17          # matches the version the default JDBC URL asks for
DB_USER=maestro
DB_PASSWORD=password       # throwaway local credential, never leaves this host
DB_NAME=maestro

docker info >/dev/null 2>&1 || {
  echo "db: no Docker daemon -- run scripts/setup-build-env.sh first" >&2
  exit 1
}

# `docker inspect` on a missing container still emits a blank line on stdout, so
# ask the container list instead and treat an empty answer as absent.
state=$(docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.State}}' 2>/dev/null || true)
state=${state:-absent}
case "$state" in
  running)
    echo "db: $CONTAINER already running"
    ;;
  absent)
    echo "db: creating $CONTAINER (volume $VOLUME)"
    # Bound to the loopback so the database is never reachable off this host.
    docker run -d \
      --name "$CONTAINER" \
      -e POSTGRES_USER="$DB_USER" \
      -e POSTGRES_PASSWORD="$DB_PASSWORD" \
      -e POSTGRES_DB="$DB_NAME" \
      -p "127.0.0.1:$PORT:5432" \
      -v "$VOLUME:/var/lib/postgresql/data" \
      "$IMAGE" >/dev/null
    ;;
  *)
    echo "db: starting $CONTAINER (was $state)"
    docker start "$CONTAINER" >/dev/null
    ;;
esac

# Flyway runs on the first connection, so the server must not race the database.
for _ in $(seq 1 30); do
  docker exec "$CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 || {
  echo "db: $CONTAINER did not become ready" >&2
  exit 1
}
echo "db: ready on 127.0.0.1:$PORT (database $DB_NAME, user $DB_USER)"
