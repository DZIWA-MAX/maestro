#!/usr/bin/env bash
#
# Prepares an ephemeral container so `./gradlew build` can run the full test
# suite. The DAO tests in maestro-engine, maestro-extensions, maestro-flow,
# maestro-queue and maestro-signal all go through the Testcontainers JDBC URL
# in MaestroDatabaseHelper, so they need a working Docker environment.
#
# Safe to re-run: every step is a no-op once it has been applied.

set -euo pipefail

# --- Start the Docker daemon -------------------------------------------------
# The image ships the Docker CLI but leaves the daemon down, so Testcontainers
# aborts with "Previous attempts to find a Docker environment failed".
if docker info >/dev/null 2>&1; then
  echo "docker: daemon already running"
else
  echo "docker: starting daemon"
  nohup dockerd >/var/log/dockerd.log 2>&1 &
  for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
  docker info >/dev/null 2>&1 || { echo "docker: daemon failed to start, see /var/log/dockerd.log" >&2; exit 1; }
  echo "docker: daemon ready"
fi
