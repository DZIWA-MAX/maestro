#!/usr/bin/env bash
#
# Prepares an ephemeral container so `./gradlew build` can run the full test
# suite. The DAO tests in maestro-engine, maestro-extensions, maestro-flow,
# maestro-queue and maestro-signal all go through the Testcontainers JDBC URL
# in MaestroDatabaseHelper, so they need a working Docker environment.
#
# Safe to re-run: every step is a no-op once it has been applied.

# Only tighten the shell when run directly -- these options would leak into the
# caller's session when the script is sourced, which bootRun needs (see below).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
fi

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

# --- Pull postgres:17 through a reachable mirror -----------------------------
# MaestroDatabaseHelper asks for "jdbc:tc:postgresql:17:///maestro", but this
# network policy answers 403 to CONNECT for production.cloudfront.docker.com,
# where Docker Hub serves its blobs -- so `docker pull postgres:17` cannot
# finish. mirror.gcr.io carries the same image and is reachable. Testcontainers
# skips the pull when the image is already present under its canonical name,
# so retag the mirrored copy rather than rewriting the JDBC URL.
mirror_pull() {
  local canonical=$1 mirrored=$2
  if docker image inspect "$canonical" >/dev/null 2>&1; then
    echo "image: $canonical already present"
    return
  fi
  echo "image: pulling $canonical via $mirrored"
  docker pull "$mirrored"
  docker tag "$mirrored" "$canonical"
}

mirror_pull postgres:17 mirror.gcr.io/library/postgres:17

# Testcontainers starts its own Ryuk sidecar to reap the containers it creates,
# and pulls that from Docker Hub too, so it needs the same treatment. The tag
# has to match exactly, otherwise Testcontainers pulls the one it wants and
# fails anyway -- so read it off the constant in RyukContainer.class instead of
# guessing, and fall back to the tag current at the time of writing when the
# dependency has not been resolved into the Gradle cache yet.
ryuk_image() {
  local jar found
  jar=$(find "${GRADLE_USER_HOME:-$HOME/.gradle}/caches" -name 'testcontainers-[0-9]*.jar' 2>/dev/null | head -1)
  if [ -n "$jar" ]; then
    found=$(unzip -p "$jar" org/testcontainers/utility/RyukContainer.class 2>/dev/null \
      | grep -ao 'testcontainers/ryuk:[0-9.]*' | head -1)
    if [ -n "$found" ]; then
      echo "$found"
      return
    fi
  fi
  echo "testcontainers/ryuk:0.12.0"
}

ryuk=$(ryuk_image)
mirror_pull "$ryuk" "mirror.gcr.io/$ryuk"


# --- Drop wildcard entries from NO_PROXY -------------------------------------
# bootRun builds a fabric8 KubernetesClient bean unconditionally, and that
# client parses NO_PROXY strictly: the '*.svc.cluster.local' entry this sandbox
# exports fails with "NO_PROXY URL contains invalid entry", which cascades up
# through kubernetesRuntimeExecutor -> maestroTask -> executionContext and kills
# the Spring context before Tomcat ever binds. The same suffix is already listed
# in its plain '.svc.cluster.local' form, so dropping the wildcard form costs no
# coverage.
#
# An exported variable only survives when this script is sourced, so a server
# run wants:  source scripts/setup-build-env.sh && ./gradlew bootRun
if [ -n "${NO_PROXY:-}${no_proxy:-}" ]; then
  NO_PROXY=$(printf '%s' "${NO_PROXY:-$no_proxy}" | tr ',' '\n' | grep -v '^\*' | paste -sd, || true)
  no_proxy=$NO_PROXY
  export NO_PROXY no_proxy
  echo "no_proxy: dropped wildcard entries the Kubernetes client rejects"
fi
echo "setup: ready -- './gradlew build' can now run the full suite"
