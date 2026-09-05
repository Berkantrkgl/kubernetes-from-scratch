# Written answers

The case asks several questions in prose rather than in code. Each one is answered here,
with a pointer to where the corresponding implementation lives.

---

## 1.2.a — Strategies for accelerating the application build

Three independent mechanisms, each covering a case the others do not.

**1. The dependency layer is keyed on `pom.xml` alone.**

```dockerfile
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B dependency:go-offline
COPY src ./src
```

Docker invalidates a layer and everything after it when its inputs change. With the source
copied first, editing one line would re-resolve every dependency. Split this way, the
resolution layer survives every source-only change.

**2. A BuildKit cache mount for the Maven repository.** `--mount=type=cache` persists
between builds without ever being committed to a layer, so ~24 MB of jars are downloaded
once per machine rather than once per pom change — and they do not end up inside the image.

**3. The jar is unpacked into layers by change frequency**, using Spring Boot's `tools`
jarmode:

| Layer | Size | Changes |
|---|---|---|
| `dependencies` | 24.2 MB | when the pom changes |
| `spring-boot-loader` | 402 kB | with the Boot version |
| `application` | **11.1 kB** | every commit |

Copied in that order, a code change rebuilds and pushes **11.1 kB** instead of a 24 MB fat
jar. Registry push and node pull both shrink by three orders of magnitude for the common
case.

**Measured:** rebuild after a one-line source change **7.7 s**, 10 steps cached.

**In the pipeline the cache mount buys nothing**, and that is worth stating: the daemon is
a fresh pod every build, so the mount starts empty. BuildKit's registry cache covers it
instead:

```
--export-cache type=inline
--import-cache type=registry,ref=berkantrkgl/query-echo:latest
```

Tests run inside the build stage rather than as a separate pipeline step. Skipping them
with `-DskipTests` would shave seconds and make it possible to produce an image from source
that does not pass its own tests — which is the one thing the build stage exists to prevent.

> Implementation: `app/Dockerfile`, `app/Jenkinsfile`

---

## 1.3.c — GitOps, and why it is not installed

The case says applying the GitOps paradigm where applicable is highly desirable. It is not
installed here, and the honest reason is memory rather than disagreement.

ArgoCD costs roughly 700 MB across its components. The host has 15 GiB total and the three
VMs already take 11.6 GiB; the workers run at 94% and 84% of allocatable memory with the
platform, Jenkins, Elasticsearch, Prometheus and the application on them. Adding ArgoCD
would mean removing something the case explicitly asks for.

**What was built instead:** the whole cluster is declarative and reproducible from this
repository — `vagrant up` then `ansible-playbook site.yml`, measured at 11 minutes 49
seconds from three empty VMs, and `changed=0` on a second run. Every manifest, chart value
and cluster setting is version controlled.

**What that does not give, and GitOps would:** Ansible makes the cluster right at the moment
it runs and then stops looking. Nothing notices an object edited by hand afterwards. There
is no continuous reconciliation and no drift correction.

**Where the boundary would sit.** A pod cannot install the pod network it runs on, so
`01-node-prep` through `04-platform` — kubeadm, Calico, MetalLB, the ingress controller —
stay in Ansible regardless. Everything above them is what a controller could own:
ExternalDNS, monitoring, Jenkins, the application.

**The gap is visible in one concrete place.** The deployment pipeline passes
`-e app_image_tag=<sha>`, which drives `kubectl set image`. That makes the running cluster
disagree with the manifest in git. The GitOps version is the pipeline committing the new tag
back to this repository and a controller reconciling it from there — the same requirement,
reached from the deployment side.

> Related: `README.md` "Rebuilding from nothing"

---

## 1.7 — Logging design: asynchronous, capped at 1 GB, rotated daily

The case states its own reasoning — stdout logging is hurting performance. The cause is that
writing to stdout is **synchronous**: the request thread performs the write and waits for
it, so log volume becomes request latency.

```
request thread ──> AsyncAppender queue ──> worker thread ──> RollingFileAppender
```

**(a) Asynchronous.** `ch.qos.logback.classic.AsyncAppender` puts a bounded queue between
the request thread and the disk. The request thread enqueues and returns; one worker drains.

```xml
<queueSize>8192</queueSize>
<discardingThreshold>0</discardingThreshold>
<neverBlock>true</neverBlock>
```

`discardingThreshold: 0` disables logback's default of dropping INFO and below once the
queue is 80% full. `neverBlock: true` is the real trade-off: when the queue is genuinely
full, drop the event rather than block the caller — because a request thread parked on a
full queue is the exact failure this requirement exists to remove. Losing a log line under
extreme burst is the cheaper loss, and it is a deliberate choice rather than a default.

**(b) and (c) — one rolling policy covers both.**

```xml
<rollingPolicy class="ch.qos.logback.core.rolling.SizeAndTimeBasedRollingPolicy">
  <fileNamePattern>${LOG_DIR}/application.%d{yyyy-MM-dd}.%i.log.gz</fileNamePattern>
  <maxFileSize>100MB</maxFileSize>
  <maxHistory>7</maxHistory>
  <totalSizeCap>1GB</totalSizeCap>
  <cleanHistoryOnStart>true</cleanHistoryOnStart>
</rollingPolicy>
```

`%d{yyyy-MM-dd}` gives the daily rotation. `%i` with `maxFileSize` splits within a day so no
single file grows unbounded. `totalSizeCap: 1GB` is the requirement read the strict way —
**the whole log directory, not just the active file** — so it holds under either reading.
`.gz` compresses on roll. `cleanHistoryOnStart` matters on a restarted pod, which would
otherwise accumulate the previous life's archives past the cap.

**Consequence, accepted deliberately:** `kubectl logs` on this pod is empty, because nothing
goes to stdout any more. That is the requirement working. It is also why fluent-bit runs as
a **sidecar** tailing the file rather than as the usual DaemonSet reading the container
runtime's log — the DaemonSet sees nothing for this pod.

> Implementation: `app/src/main/resources/logback-spring.xml`,
> `k8s/app/fluent-bit-config.yaml`

---

## 2.3.c — Achieving zero-downtime deployments

**Strategy: rolling update**, and the zero-downtime property comes from four things working
together rather than from the strategy alone.

**1. The rollout never removes capacity it has not replaced.**

```yaml
strategy:
  rollingUpdate:
    maxSurge: 0
    maxUnavailable: 1
```

Three of four pods serve throughout. An earlier version used `maxUnavailable: 0` with
`maxSurge: 1` — a stronger guarantee that **could not execute on this cluster**: the fifth
pod needed 320Mi of free memory and the topology spread constraint forced it onto the node
that had 297Mi. A guarantee that cannot execute is worth less than a weaker one that can.

**2. `readinessProbe` is the traffic gate.** A new pod joins the Service's EndpointSlice
only after `/actuator/health/readiness` passes, so no request is routed to a process that
is still starting.

**3. `preStop` covers the race that most rollouts get wrong.** Pod termination is **not
ordered**: endpoint removal and `SIGTERM` are dispatched at the same moment, and the removal
takes time to reach every node's kube-proxy. Without a pause, a pod can stop accepting
connections while a node still lists it as an endpoint.

```yaml
lifecycle:
  preStop:
    sleep: { seconds: 5 }
terminationGracePeriodSeconds: 40
```

**4. The arithmetic has to fit inside the grace period.**

```
preStop sleep             5 s
Spring graceful shutdown 25 s
──────────────────────────────
                         30 s  <  terminationGracePeriodSeconds: 40
```

**Measured, not claimed.** During a `0.1.0 → 0.1.1` rollout, with a request every 200 ms
from outside the cluster: **423 requests, zero failures.**

The same log shows the other half of the truth — for **sixteen seconds both versions
answered**. That is not a defect, it is what a rolling update *is*, and it is the reason a
deployment strategy cannot be discussed without backward compatibility: for that window any
API or schema change has to be acceptable to both versions at once.

> Implementation: `k8s/app/deployment.yaml`, `ansible/Jenkinsfile`

---

## 3.1 — App X must scale under load, on a cluster that cannot add nodes

**Sample manifests: `examples/step-3.1/`**

The constraint in the question is on the **nodes** ("we can't scale them"), not on the
workloads — and the same paragraph asks for App X to scale. So two different meanings of
*scale* are in play:

| Scaling | Available | Mechanism |
|---|---|---|
| Adding nodes | no | Cluster Autoscaler — not possible |
| Adding App X pods | **required** | HPA |

App X has to grow, no new capacity is coming, so the room it grows into must be taken from
App Y — which the case describes as killable or pausable. Three mechanisms, three layers:

**1. `PriorityClass` and preemption — how App X gets a place to run.**

```yaml
realtime-critical    value: 1000000
batch-preemptible    value: 100      preemptionPolicy: Never
```

When the scheduler cannot place a high-priority pod, it evicts lower-priority pods to make
room. `preemptionPolicy: Never` on App Y means it can be evicted but will never evict
anything itself. Both values sit below `system-cluster-critical` (2000000000), so cluster
components outrank both applications.

**QoS alone would not solve this.** QoS decides who kubelet evicts when a node is *already*
under memory pressure; it has no effect on scheduling. A pending App X pod on a full cluster
stays pending forever regardless of its QoS class.

**2. QoS — who survives once running.** App X sets `requests == limits` on both resources,
making it **Guaranteed**: last to be evicted under node pressure, and its CPU is reserved
rather than shared. App Y is **Burstable** — a real request, no CPU limit, so it can use
whatever App X is not using at that moment.

*This reverses a decision made elsewhere in this repository on purpose.* `query-echo` has no
CPU limit, because CPU throttling is a latency problem that is hard to trace. That reasoning
still holds — it answers a different question. An application described as *real-time* is
asking for predictability, and predictability is what a shared CPU allocation cannot
promise. The cost is that App X cannot burst into idle CPU.

**3. HPA — how App X knows to grow.**

```yaml
minReplicas: 2, maxReplicas: 6
target: cpu 70% utilization
behavior:
  scaleUp:   stabilizationWindowSeconds: 0
  scaleDown: stabilizationWindowSeconds: 300
```

The asymmetry is deliberate: scale up immediately, give capacity back slowly. A momentary
dip in load is not evidence the capacity is no longer needed, and for a real-time
application being one pod short costs more than holding one pod too long.

**A `PodDisruptionBudget` does not protect App Y from preemption**, and that distinction is
part of the answer. PDBs cover *voluntary* disruption — drains, node upgrades. The scheduler
ignores them when preempting, deliberately: preemption exists so the cluster can run
critical work, and a budget on the victim would defeat it.

**Honest limitation:** this cluster has no `metrics-server`, so an HPA applied here would
report `<unknown>` and never scale. These manifests are a design answer, not a running
system. In a real environment metrics-server is one Helm release.

---

## 3.2 — Deploying a critical application, and shifting traffic

### (a) Strategy

For an application where a bad version has user impact, the strategy has to answer one
question the rolling update cannot: **how much traffic sees the new version before you can
undo it?**

Rolling update exposes **all** traffic to the new version by the time it finishes, and its
rollback is another rolling update — minutes, not seconds. That is acceptable for
`query-echo` and not for something critical.

| Strategy | Blast radius before rollback | Cost |
|---|---|---|
| Rolling update | everything, once complete | none |
| **Blue/green** | everything, but rollback is instant | 2× resources |
| **Canary** | a defined slice — 5%, then 25% | slowest, needs traffic control |

**For a critical application: canary, falling back to blue/green** when the deployment
cannot be expressed as a percentage of traffic (a schema migration, a stateful protocol
change).

Canary is the stronger answer because it limits *exposure*, not just *recovery time*.
Blue/green still sends 100% of users to the new version at the moment of the switch — it
only makes going back cheap. Canary means most users never see a bad version at all.

**What makes either safe is the rollback path, not the rollout.** Blue/green keeps the old
environment running and switches a selector; canary keeps the old version serving the
majority throughout. Both are decisions about what happens when the new version is wrong,
which is the actual subject of the question.

### (b) Implementing the traffic shift

**Who moves the traffic** has three possible answers, and they differ in granularity:

| Mechanism | Granularity | Notes |
|---|---|---|
| Replica ratio | coarse — 1 of 10 pods ≈ 10% | no extra components; the Service load-balances across both ReplicaSets |
| **Ingress weights** | precise percentage | NGINX and most controllers support weighted backends |
| Service mesh | precise, plus per-header routing | Istio/Linkerd — the most control, the most infrastructure |

**The steps I would take:**

1. **Deploy the canary alongside the stable version** — a second Deployment, same Service
   selector or a weighted ingress backend, starting at 5%.
2. **Watch metrics that answer "is this version worse", not "is it up".** Error rate and p95
   latency for the canary specifically, compared against the stable version over the same
   window. This repository already emits both — `http_server_requests_seconds` by pod,
   with histogram buckets enabled so `histogram_quantile` works.
3. **Hold at each step long enough to be statistically meaningful.** A 5% canary on low
   traffic may take an hour to say anything; shifting on a two-minute sample is theatre.
4. **Shift in steps — 5% → 25% → 50% → 100%** — re-evaluating at each one.
5. **Automate the decision, not just the shift.** Argo Rollouts or Flagger run the analysis
   as part of the rollout and abort automatically on a metric breach. A human watching a
   dashboard is the version that fails at 3 a.m.
6. **Keep the old version deployed until the new one has run through a full traffic cycle**
   — a peak, a batch window — not just until the rollout reports success.

**The database is the part the strategy cannot solve on its own.** Two versions are live
simultaneously in every one of these strategies, so schema changes must follow
**expand–contract**: add the new column and write to both, deploy the version that reads
the new one, and only remove the old column after the old version is gone. A schema change
that is not backward compatible turns any of these strategies into an outage.

**Prerequisites the strategy assumes:** readiness probes that mean what they say, metrics
per version, and a rollback that has been tested rather than documented.

> Implementation of the parts that exist here: `k8s/app/deployment.yaml`,
> `k8s/monitoring/dashboard.yaml`
