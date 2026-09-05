# Written answers

The case asks a few things in prose rather than in code. Here they are.

---

## 1.2.a — Speeding up the application build

Three things, each covering a case the others miss.

**The pom is copied before the source.** Docker invalidates a layer and everything after it,
so with the source copied first a one-line change would re-resolve every dependency:

```dockerfile
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B dependency:go-offline
COPY src ./src
```

**A BuildKit cache mount for `~/.m2`**, so the ~24 MB of jars are downloaded once per
machine and never end up inside the image.

**The jar is unpacked into layers by how often each changes.** Spring Boot's `tools` jarmode
splits it into dependencies (24.2 MB), the loader (402 kB) and the application classes
(11.1 kB). Copied in that order, a code change rebuilds and pushes 11 kB instead of 24 MB.

A rebuild after a one-line change takes 7.7 seconds, 10 of 12 steps cached.

One thing worth knowing: in the pipeline the cache mount buys nothing, because the daemon is
a fresh pod every build and the mount starts empty. BuildKit's registry cache covers that
instead — `--export-cache type=inline` on the way out, `--import-cache` from the `latest`
tag on the way in.

Tests run inside the build stage rather than as a separate step. Skipping them would save a
few seconds and make it possible to build an image from source that fails its own tests.

---

## 1.3.c — GitOps

I did not install it, and the reason is memory rather than disagreement.

ArgoCD costs around 700 MB. The host has 15 GiB, the three VMs already take 11.6, and both
workers sit at 84–94% of allocatable memory with the platform, Jenkins, Elasticsearch,
Prometheus and the application on them. Adding ArgoCD means removing something the case asks
for.

What exists instead is a cluster that rebuilds itself from this repository — `vagrant up`,
then one `ansible-playbook site.yml`, measured at 11m49s from three empty VMs, and
`changed=0` on a second run. Declarative and reproducible, but not reconciling: Ansible is
right at the moment it runs and then stops looking. Nothing notices an object edited by hand
afterwards.

The boundary would sit in a specific place. A pod cannot install the pod network it runs on,
so kubeadm and Calico stay in Ansible regardless — playbooks 01 to 04. Everything above them
is what a controller could own.

The gap shows up concretely in the deployment pipeline: it passes `-e app_image_tag=<sha>`,
which runs `kubectl set image`, and now the cluster and the manifest in git disagree. The
GitOps version is the pipeline committing that tag back and something reconciling it from
there.

---

## 1.7 — Logging: async, 1 GB cap, daily rotation

The case says stdout logging is hurting performance, and it is right about why: the write is
synchronous, so the request thread does it and waits. Log volume becomes request latency.

An `AsyncAppender` puts a bounded queue in between. The request thread enqueues and returns;
one worker thread drains it.

```xml
<queueSize>8192</queueSize>
<discardingThreshold>0</discardingThreshold>
<neverBlock>true</neverBlock>
```

`discardingThreshold: 0` turns off logback's habit of dropping INFO and below once the queue
is 80% full. `neverBlock: true` is the trade-off worth arguing about: when the queue really
is full, drop the event instead of blocking the caller. A request thread parked on a full
queue is exactly the failure this requirement is trying to remove, so losing a log line
during a burst is the cheaper loss.

Rotation is one policy covering both remaining constraints:

```xml
<rollingPolicy class="ch.qos.logback.core.rolling.SizeAndTimeBasedRollingPolicy">
  <fileNamePattern>${LOG_DIR}/application.%d{yyyy-MM-dd}.%i.log.gz</fileNamePattern>
  <maxFileSize>100MB</maxFileSize>
  <maxHistory>7</maxHistory>
  <totalSizeCap>1GB</totalSizeCap>
  <cleanHistoryOnStart>true</cleanHistoryOnStart>
</rollingPolicy>
```

`%d` gives the daily roll, `%i` with `maxFileSize` keeps a single day from growing
unbounded, and I read the 1 GB cap the strict way — the whole directory, not just the active
file — so it holds either way. `cleanHistoryOnStart` matters on a restarted pod, which would
otherwise carry the previous life's archives past the cap.

The consequence is that `kubectl logs` on this pod is empty. That is the requirement working,
and it is also why fluent-bit runs as a sidecar tailing the file instead of the usual
DaemonSet reading container stdout — there is nothing on stdout to read.

---

## 2.3.c — Zero-downtime deployments

Rolling update, and the property comes from four things rather than from the strategy alone.

**Capacity never drops below what is serving.** `maxSurge: 0, maxUnavailable: 1` — three of
four pods serve throughout. I started with `maxUnavailable: 0`, which is a stronger promise
and could not execute here: the surge pod needs 320 MB and the topology spread constraint
sent it to the node with 297 MB free. A guarantee that cannot run is worth less than a
weaker one that can.

**The readiness probe is the traffic gate.** A pod joins the Service's endpoints only after
`/actuator/health/readiness` passes, so nothing is routed to a process that is still coming
up.

**`preStop` covers the race most rollouts get wrong.** Endpoint removal and `SIGTERM` are
dispatched at the same moment — they are not ordered — and the removal takes time to reach
every node's kube-proxy. Without a pause the pod can stop accepting connections while a node
still lists it as an endpoint. Five seconds of `preStop` sleep covers that.

**The timings have to fit inside the grace period.** 5 s of preStop plus Spring's 25 s
graceful shutdown is 30, and `terminationGracePeriodSeconds` is 40.

I measured it rather than claiming it: during a `0.1.0 → 0.1.1` rollout, one request every
200 ms from outside the cluster, **423 requests and no failures**.

The same log shows the other half. For sixteen seconds both versions answered. That is not a
defect, it is what a rolling update is — and it is why you cannot discuss deployment
strategy without backward compatibility. For that window, any API or schema change has to be
acceptable to both versions at once.

---

## 3.1 — App X has to scale, and no nodes can be added

Sample manifests: `examples/step-3.1/`.

The constraint is on the nodes, not the workloads — and the same paragraph asks App X to
scale under load. So App X grows, nothing new arrives to grow into, and the room has to come
from App Y, which the case describes as killable.

Three mechanisms, three different layers:

**Priority and preemption** get App X a place to run. `realtime-critical` at 1000000 for
App X, `batch-preemptible` at 100 for App Y, with `preemptionPolicy: Never` on the second so
it can be evicted but never evicts anything itself. Both sit below `system-cluster-critical`,
so cluster components still outrank them.

QoS alone would not solve this, and the difference is worth being precise about: QoS decides
who kubelet kills when a node is already under memory pressure. It has no effect on
scheduling. A pending App X pod on a full cluster stays pending forever whatever its QoS
class is.

**QoS** decides who survives once running. App X sets requests equal to limits on both
resources, which makes it Guaranteed — last to be evicted, CPU reserved rather than shared.
App Y is Burstable with no CPU limit, so it uses whatever App X is not using.

That reverses a decision I made for `query-echo`, deliberately. There I left the CPU limit
off, because throttling is a latency problem that is hard to trace back. That still holds —
it answers a different question. Something described as real-time wants predictability, and
predictability is what a shared CPU allocation cannot promise. The price is that App X can
no longer use idle CPU.

**HPA** tells App X when to grow: 2 to 6 replicas at 70% CPU, scaling up immediately and
down after five minutes. The asymmetry is on purpose — a dip in load is not evidence the
capacity is no longer needed.

Two things worth adding. A PodDisruptionBudget does not protect App Y from preemption; PDBs
cover drains and node upgrades, and the scheduler ignores them when preempting, because
otherwise a budget on the victim would defeat the whole mechanism. And this cluster has no
metrics-server, so that HPA would report `<unknown>` and never scale — the manifests are a
design answer, not a running system.

---

## 3.2 — Deploying a critical application

### Strategy

For something where a bad version reaches users, the question a rolling update cannot answer
is: how much traffic sees the new version before you can undo it?

Rolling update exposes everything by the time it finishes, and its rollback is another
rolling update — minutes, not seconds. Fine for `query-echo`, not for this.

| | Exposure before rollback | Cost |
|---|---|---|
| Rolling update | everything, once complete | none |
| Blue/green | everything, but rollback is instant | 2× resources |
| Canary | a slice you choose | slowest, needs traffic control |

I would use a canary, falling back to blue/green where the change cannot be expressed as a
percentage of traffic — a schema migration, say.

Canary is the stronger answer because it limits exposure rather than just recovery time.
Blue/green still sends everyone to the new version at the moment of the switch; it only makes
going back cheap. With a canary most users never see a bad version at all.

### The traffic shift

Three ways to move it, differing in how fine-grained they are: replica ratio (1 of 10 pods is
roughly 10%, no extra components), ingress weights (a real percentage, and NGINX supports
it), or a service mesh (percentages plus per-header routing, and a lot more infrastructure).

The steps:

1. Deploy the canary next to the stable version, starting around 5%.
2. Watch metrics that answer "is this version worse", not "is it up" — error rate and p95
   latency for the canary compared against stable over the same window. This cluster already
   emits both per pod, with histogram buckets enabled so `histogram_quantile` has something
   to read.
3. Hold at each step long enough to mean something. A 5% canary on low traffic may take an
   hour to say anything, and deciding on a two-minute sample is theatre.
4. Step through 5% → 25% → 50% → 100%, re-checking at each one.
5. Automate the decision, not just the shift. Argo Rollouts or Flagger run the analysis as
   part of the rollout and abort on a metric breach. A person watching a dashboard is the
   version that fails at 3 a.m.
6. Keep the old version deployed until the new one has been through a full traffic cycle —
   a peak, a batch window — not just until the rollout reports success.

The database is the part no strategy fixes on its own. Every one of these runs two versions
at once, so schema changes have to be expand–contract: add the new column and write to both,
deploy the version that reads it, drop the old one only after the old version is gone. A
schema change that is not backward compatible turns any of these strategies into an outage.
