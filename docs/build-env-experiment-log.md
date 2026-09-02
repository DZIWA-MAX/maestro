# Build environment experiment log

Chronological record of getting `./gradlew build` and `./gradlew bootRun` to pass
inside an ephemeral cloud container, and the reasoning each run supports.

Every row states **the one change from the previous run**. That column is the
point of the format: when a row has to name two changes, the run cannot attribute
its own result, and the run has to be redone. Run 4 below is exactly that failure,
left in place rather than tidied away.

Metrics come from the Gradle output of each run. "Tests" counts the aggregate
across all modules; the per-module numbers are in the notes.

## Log

| # | Change vs. previous run | Command | Result | Tests | Duration |
|---|---|---|---|---|---|
| 1 | (baseline) | `./gradlew build --continue` | FAILED | 244 failed | 3m49s |
| 2 | Started `dockerd` | `./gradlew build` | FAILED | 244 failed | 30s |
| 3 | Pulled+tagged `postgres:17` from `mirror.gcr.io` | *(not run in isolation)* | — | — | — |
| 4 | Tagged `ryuk:0.11.0` **and** set `TESTCONTAINERS_RYUK_DISABLED=true` | `./gradlew build` | SUCCESS | 1966, 0 failed | 1m10s |
| 5 | Dropped `TESTCONTAINERS_RYUK_DISABLED` | `:maestro-queue:test --rerun-tasks` | FAILED | 39, 8 failed | 57s |
| 6 | Ryuk tag read from `RyukContainer.class` → `0.12.0` | `:maestro-queue:test --rerun-tasks` | SUCCESS | 39, 0 failed | 37s |
| 7 | Full build, cold, no env overrides | `./gradlew build --rerun-tasks` | SUCCESS | 1966, 0 failed | 4m55s |
| 8 | Target changed to the server | `./gradlew bootRun` | FAILED | n/a | 24s |
| 9 | Wildcard entries stripped from `NO_PROXY` | `./gradlew bootRun` | UP on :8080 | n/a | ~60s to health |
| 10 | Sourced the setup script instead of inline env | `source scripts/setup-build-env.sh && ./gradlew bootRun` | UP on :8080 | n/a | ~60s to health |
| 11 | None — rerun after a container restart | `GET /workflows/sample-dag-test-1/versions/latest` | HTTP 404 | n/a | — |

## What each run established

**Run 1 — the failures are all one thing.** 244 failures across five modules
(engine 221, flow 10, queue 8, signal 4, extensions 1). Every failing class is a
DAO test, and every one traces to
`Previous attempts to find a Docker environment failed. Will not retry.`
Compilation, checkstyle, PMD and jar tasks passed. So this was never the code:
`MaestroDatabaseHelper` hands Testcontainers `jdbc:tc:postgresql:17:///maestro`,
and no daemon was running. Testcontainers caches that verdict, so one missing
daemon takes out every DB-backed test.

**Run 2 — the daemon was necessary but not sufficient.** Same 244 failures, but
the message moved to `Can't get Docker image` / `Mapped port can only be obtained
after the container is started`. Progress is the *change in error*, not the count.
`docker pull postgres:17` then failed on its own with 403 Forbidden from
`production.cloudfront.docker.com`; the proxy status endpoint confirmed a policy
denial at CONNECT for that host. Docker Hub serves its blobs there, so no image
can be pulled from Hub in this environment.

**Run 3 — not isolated.** The postgres tag and the Ryuk tag were applied back to
back without a build between them. Nothing here proves what the postgres tag alone
achieved. Recorded as a gap rather than a result.

**Run 4 — green for the wrong reason.** Two changes shipped together: a guessed
Ryuk tag and a flag disabling Ryuk entirely. The build passed, which made it look
like both were right. Neither was established: the flag alone explains the pass.
This is the run the log format exists to catch.

**Run 5 — the guess was wrong.** Removing only the flag failed immediately, and
the error named the image Testcontainers actually wanted: `testcontainers/ryuk:0.12.0`.
So run 4's tag was never used, and disabling Ryuk had been hiding that.

**Run 6 — reading beats guessing.** The tag is a constant in
`RyukContainer.class`; the script now reads it from the resolved jar and keeps a
pin only as a fallback for a cold Gradle cache. With the right image, Ryuk starts
and reaps its containers as designed, and the disable flag is unnecessary.

**Run 7 — the claim, verified cold.** Full build with every task re-executed and
nothing set in the environment beyond the script: 170 tasks, 1966 tests, 0 failures.

**Run 8 — the server needs more than the build does.** `bootRun` died before
Tomcat bound, reported as an `UnsatisfiedDependencyException` on
`flowEngineController`. The real cause was eight frames down:
`java.net.MalformedURLException: NO_PROXY URL contains invalid entry: '*.svc.cluster.local'`.
`MaestroStepRuntimeConfiguration` builds a fabric8 `KubernetesClient`
unconditionally, and that client parses `NO_PROXY` strictly. The failure then
cascaded up through `kubernetesRuntimeExecutor` → `maestroTask` →
`executionContext`, so the top of the stack named a component with nothing to do
with it.

**Run 9 — dropping the wildcard costs nothing.** The same suffix is already listed
in its plain `.svc.cluster.local` form, so no host stops being excluded from the
proxy. Server reached `{"status":"UP"}` on :8080.

**Run 10 — via the committed path.** Exercised end to end with the README sample:
workflow created (HTTP 200), started (HTTP 200), instance reached `SUCCEEDED`,
6 steps `SUCCEEDED`. The server does not merely boot, it executes.

**Run 11 — the data does not survive.** After a container restart the workflow
returned 404. `jdbc:tc:postgresql:17:///maestro_local` provisions a throwaway
Postgres on every boot, so nothing created through the API outlives the process.

## Symptom → fix

| Symptom | Cause | Fix |
|---|---|---|
| `Previous attempts to find a Docker environment failed` | No `dockerd` running | Start the daemon; wait for the socket |
| `Can't get Docker image` / `Mapped port can only be obtained…` | Docker Hub blob CDN blocked (403 at CONNECT) | Pull from `mirror.gcr.io`, retag under the canonical name |
| `ContainerFetchException` naming `testcontainers/ryuk:<v>` | Mirrored Ryuk tag ≠ the one Testcontainers wants | Read the tag from `RyukContainer.class`; do not guess |
| `NO_PROXY URL contains invalid entry: '*…'` | fabric8 Kubernetes client rejects wildcard entries | Strip wildcard entries; the plain suffix already covers them |
| `UnsatisfiedDependencyException` on an unrelated bean | Real cause is at the bottom of the `Caused by` chain | Read the last `Caused by`, not the first line |

## Unresolved

The script makes any given container work; it does not make a container last.
The container is reclaimed between turns — the daemon, the server process and the
Testcontainers Postgres all die with it, and run 11 shows the API data going with
them. Only what is committed survives.

Two consequences worth stating plainly. Long-running work cannot be started and
left here, because there is no long-lived machine to reattach to; session
persistence tools solve a different problem, one where the client dies and the
host lives. And the images survive restarts only because Docker's data directory
happens to persist — nothing guarantees that, and a cold cache puts the mirror
pulls back on the critical path.

Setup automation buys a working container, not a durable one. Anything that must
outlive a restart has to be reconstructable from the repository.
