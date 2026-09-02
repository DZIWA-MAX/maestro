# Maestro behaviour notes

Things established by reading this repository's source and running it, that are
not stated in the documentation or that differ from what the Maestro blog posts
describe. Each entry names the evidence, so a reader can re-check it rather than
take it on faith.

Verified against `d11af99`, running under the `local-db` profile.

## Foreach, as observed

Reproduce with:

```
bash scripts/setup-build-env.sh && bash scripts/start-maestro-db.sh
./gradlew bootRun --args='--spring.profiles.active=local-db'
curl --header "user: tester" -X POST 'http://127.0.0.1:8080/api/v3/workflows' \
  -H "Content-Type: application/json" \
  -d @maestro-server/src/test/resources/samples/sample-nested-foreach-wf.json
curl --header "user: tester" -X POST \
  'http://127.0.0.1:8080/api/v3/workflows/sample-nested-foreach-wf/versions/latest/actions/start' \
  -H "Content-Type: application/json" -d '{"initiator": {"type": "manual"}}'
```

The run finishes in about two minutes and reports **one** step at the top level.
The iterations live in separate workflow instances, which is what makes them
visible in `maestro_workflow_instance`:

```
sample-nested-foreach-wf          | 1    | MANUAL  | root_depth 0
maestro_foreach_<prefix>_12de26b0 | 1..6 | FOREACH | root_depth 1
maestro_foreach_<prefix>_3c5148c2 | 1    | FOREACH | root_depth 2
maestro_foreach_<prefix>_93f6233f | 1,2  | FOREACH | root_depth 2
maestro_foreach_<prefix>_9f110f7c | 1    | FOREACH | root_depth 2
maestro_foreach_<prefix>_fce9f7bf | 1,2  | FOREACH | root_depth 2
```

`initiator_type` separates generated instances from user-created ones, and
`root_depth` carries the nesting level. The inline workflow id is derived per
sub-graph, so the inner foreach produces four distinct ids rather than one.

### Iteration status is stored as ranges, not per iteration

The top-level step's artifact holds the collected status:

```json
"total_loop_count": 6, "next_loop_index": 6, "checkpoint": 7,
"foreach_overview": {
  "stats":   {"SUCCEEDED": 6},
  "details": {"SUCCEEDED": [[1, 6]]},
  "rollup":  {"total_leaf_count": 14}
}
```

`details` records contiguous ranges of same-status iterations — `[[1, 6]]` is
iterations 1 through 6. The cost of monitoring is therefore proportional to the
number of status ranges, not to the iteration count, which is what lets a
foreach carry the very large iteration counts the design is meant to support.

### loop_params iterate as a cartesian product

`sample-nested-foreach-wf.json` declares `i` as `[1, 2, 3]` and `j` as `["a", "b"]`,
and the run produced **six** iterations, not three:

| iteration | i | j |
|---|---|---|
| 1 | 1 | a |
| 2 | 2 | a |
| 3 | 3 | a |
| 4 | 1 | b |
| 5 | 2 | b |
| 6 | 3 | b |

Read from `instance::jsonb #>> '{params,i,evaluated_result}'` on the depth-1
instances. This also explains why `j`'s `param.size() > 2` validator does not
reject a two-element array: the loop parameters are not zipped, so they need not
share a length.

### A foreach with zero iterations still counts as one leaf

`Util.intsBetween(1, i, 1)` excludes its upper bound. The `x` values recorded on
the depth-2 instances give `i=1 → []`, `i=2 → [1]`, `i=3 → [1, 2]`, so the inner
foreach of iteration `i=1` generates no instance at all.

Its rollup is nevertheless 2, not 1:

| outer iteration | i | inner iterations | `total_leaf_count` |
|---|---|---|---|
| 1 | 1 | none | 2 |
| 2 | 2 | 1 | 2 |
| 3 | 3 | 2 | 3 |

Summed over both `j` values that is `(2 + 2 + 3) × 2 = 14`, matching the
`total_leaf_count` on the top-level artifact. An empty foreach step is counted as
a leaf in its own right.

### Timings follow the SEL expressions exactly

`job.2` slept 10 s, 20 s and 30 s for `i` of 1, 2 and 3 (`i * 10`). The inner
foreach of `i=3` took 10 s in total, not 15 s: its two iterations sleep `x * 5`
for `x` of 1 and 2, and `concurrency: 3` runs them in parallel.

## Step parameter merge order differs from the blog post

The Maestro blog describes the step parameter merge as: default general
parameters, then **injected** parameters, then **default typed** parameters,
then workflow and step info, then undefined new parameters, then step definition
parameters, then run and restart parameters.

`ParamsManager.generateMergedStepParams`
(`maestro-engine/src/main/java/com/netflix/maestro/engine/params/ParamsManager.java:141-172`)
swaps the second and third of those:

```
1. getDefaultStepParams()                   SYSTEM_DEFAULT
2. getDefaultParamsForType(step.getType())  SYSTEM_DEFAULT    <- typed
3. stepRuntime.injectRuntimeParams(...)     TEMPLATE_SCHEMA   <- injected
4. injectWorkflowAndStepInfoParams(...)     SYSTEM_INJECTED
```

This is not cosmetic. `ParamsMergeHelper.mergeParams(base, toMerge, context)`
writes `toMerge` into `base`, so a later merge wins. In the code, parameters
injected by the step runtime override the step type's defaults; in the order the
blog gives, the type defaults would override the injected ones. The precedence
of that pair is reversed.

One qualification: `buildMergedParamDefinition` applies the parameter's mode, so
a reserved or immutable parameter is not overridden regardless of merge order.
The reversal holds for parameters whose mode permits an override.

The likely explanation is that the blog post predates the current code rather
than describing it incorrectly.

## SEL is not sandboxed by the Java Security Manager

The Maestro blog post says of SEL: *"It leverages the Java Security Manager to
restrict access, ensuring a secure and controlled environment for code
execution."*

No part of this repository uses it. Searching the Java sources returns exactly
one occurrence, and it is in a test, as a string an attacker might submit:

```java
// netflix-sel/src/test/java/com/netflix/sel/SelJailbreakTest.java:181
"System.setSecurityManager(null);",
```

It sits in a `SYSTEM_MATH_ABUSE` array beside `System.exit(1)`,
`System.getenv('PATH')` and `System.load('/x')` — expressions the parser is
required to reject. There is no `SecurityManager` in any main source, no
`.policy` file, and no `java.security.manager` setting in any Gradle, YAML or
properties file.

This matters for anyone evaluating SEL for untrusted input: the published
guarantee is not the one the code provides. What actually contains SEL is four
separate mechanisms.

**Identifiers resolve to stand-in types, never to the JDK.** `SelTypeUtil`
(`netflix-sel/src/main/java/com/netflix/sel/type/SelTypeUtil.java:210`) maps the
name `System` to `SelMiscFunc.INSTANCE`, and `Math` to `SelJavaMath`. A SEL
expression cannot reach `java.lang.System` because that name resolves to
something else entirely. This is the primary containment: the dangerous call is
not blocked at runtime, it is unnameable.

**Evaluation runs on a dedicated thread with a restricted context classloader.**
`SelThread.run` installs `SelClassLoader` as the context classloader
(`netflix-sel/src/main/java/com/netflix/sel/security/SelThread.java`), and that
loader preloads and pins a fixed set of packages — `com.netflix.sel.ast`,
`.type`, `.visitor`, `.ext`, and `org.joda.time`.

**Runtime limits bound resource use.** `SelProperties` carries `loopLimit`,
`visitLimit` and `memoryLimit`, enforced by `MemoryCounter` and the visitors;
`application.yml` sets them to 25001 loop iterations, a 128-deep stack, and a
100 MB memory ceiling, among others.

**`SelJailbreakTest` is the regression suite that keeps escapes failing.** It is
the file to read first when judging how much the containment is worth, and the
file to extend when adding a new SEL capability.

The Security Manager was deprecated for removal by JEP 411 in Java 17, and this
project targets Java 21 (`build.gradle:47`). Building the guarantee on it would
have meant building on something already scheduled to disappear, so the code
being ahead of the blog post is the right direction for the two to diverge in.
