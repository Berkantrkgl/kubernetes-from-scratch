# Design decisions

The non-obvious choices, the alternatives considered, and what each one costs.

Version rule applied throughout: **one release back, at rest.** A `.0` is where the
ecosystem has not caught up; a patch published the same day is a line still being corrected.

---

## Environment and bootstrap

| Decision | Alternatives | Why |
|---|---|---|
| VirtualBox | libvirt/KVM | KVM is faster, but the case names VirtualBox as a prerequisite |
| `bento/ubuntu-24.04` | `ubuntu/focal64` (supplied) | 20.04 left support in May 2025, and Canonical's boxes ship without Guest Additions — the `/vagrant` mount would not work |
| Memory 2.5 / 4.5 / 4.5 GiB | supplied 4 / 2 / 2 | Reversed: the control plane runs ~1.2 GiB of components, each worker carries Jenkins or Elasticsearch plus the app |
| kubeadm + config file | flags, Kubespray | Kubespray hides the bootstrap, which is the thing being demonstrated. Several settings have no flag equivalent |
| Kubernetes 1.36.4 | 1.37.0, 1.28 | One minor back at a mature patch; 1.28 is a floor, not a choice |

**Three defects were fixed in the supplied Vagrantfile**, one dangerous: `MASTER_MEMORY`
read `ENV["MASTER_CPUS"]`, so `MASTER_CPUS=2` would boot the control plane with 2 MB of RAM.

**The control plane taint is retained.** Untainting would add 2.5 GiB of schedulable
capacity, but a control plane running workloads is not production-ready — a workload that
exhausts memory there takes the API server with it. One deliberate exception: the deployment
pipeline's Ansible agent, which runs only `ansible` and `ssh` and needs to be off the workers
whose memory the rollout it drives depends on.

**Secrets encrypted at rest with `secretbox`** — chosen from upstream's guidance, where the
obvious answers lose: `aescbc` is vulnerable to padding oracles, `aesgcm` needs automated key
rotation, KMS needs an external key manager. Provider **order** matters more than the
provider: `identity` sits second so pre-existing Secrets stay readable. First would mean
everything continues to be written in plaintext, silently.

*Trade-off:* the key is on the control plane node — protects a stolen snapshot, not an
attacker who already has root there.

---

## Networking

**Calico**, because Flannel does not implement NetworkPolicy and applying one **succeeds
silently** — the object is stored and nothing happens. Cilium is stronger and costs ~2.5×
the per-node memory.

**VXLAN `CrossSubnet`, BGP disabled.** All three nodes share one L2 segment, so
encapsulation is skipped for same-subnet traffic — BGP-like performance **without BGP
peering**, which would need a router this environment does not have.

**CIDRs chosen by elimination:** `192.168/16` is Calico's default *and* VirtualBox's
host-only range, `172.17/16` is `docker0`, `10.244/16` is Flannel's. Left with pod
`10.32.0.0/16`, Service `10.96.0.0/16`. The `/16` for Services rather than kubeadm's `/12` is
**address-plan hygiene, not performance** — kube-proxy writes rules per Service, not per
address.

**The multi-interface trap, which repeats three times.** Every VM has the identical NAT
address `10.0.2.15` on `eth0`; real traffic uses `eth1`. kubelet, the API server and Calico
each pick a node address independently and all three default to the interface behind the
default route. Two of the three fail **silently** — the cluster reports `Ready` while
`kubectl logs` is broken, or pods talk within a node but not across nodes. Calico is pinned
by CIDR rather than interface name, so a rename does not break it.

**MetalLB, L2 mode.** `type: LoadBalancer` does nothing on bare metal — the Service is stored
and waits for a cloud controller that does not exist. BGP mode needs a peering router.
*Consequences:* the pool must be in the node subnet (ARP does not leave the broadcast
domain), and all traffic for an address enters through one elected node.

---

## Ingress — the choice the ecosystem forced

**`kubernetes/ingress-nginx` is retired.** Final release 19 March 2026; its supported-Kubernetes
table stops at 1.35 while this cluster runs 1.36.4; the Kubernetes Security Response Committee
wrote that staying on it "leaves you and your users vulnerable to attack." It still installs
cleanly and nothing warns you — that is the trap.

| Alternative | Rejected because |
|---|---|
| `kubernetes/ingress-nginx` | unmaintained, untested on 1.36, no further security fixes |
| InGate (announced successor) | archived March 2026 **without ever cutting a release** |
| NGINX Gateway Fabric | does not process `Ingress` at all — the case says "using an Ingress" |
| Traefik, HAProxy | no technical objection; the case says "load-balanced using **Nginx**" |

**Chosen: F5/NGINX `nginx/kubernetes-ingress` OSS v5.5.4** — a different project from the
community one despite the name, tested on 1.29–1.36, monthly releases. It is NGINX, it
implements the Ingress API, and it is maintained.

*Cost:* the annotation prefix is `nginx.org/`, so an annotation copied from an ingress-nginx
example is **silently ignored**. This shaped a later decision — each backend serves its own
subpath rather than relying on the controller's rewrite dialect.

**`externalTrafficPolicy: Cluster`**, overriding the chart's `Local`, because of MetalLB
issue #2747: with `Local` and two replicas on different nodes, multiple speakers answer ARP
for the same VIP with different MACs and connectivity becomes intermittent about half an hour
in. The cost is the client IP, and `X-Forwarded-For` does not rescue it — SNAT happens before
NGINX. In production the answer is BGP mode, where `Local` costs nothing.

---

## Platform

**local-path-provisioner.** kubeadm installs no provisioner, so every PVC would sit `Pending`.
Longhorn and Rook/Ceph are the real bare-metal answers and want spare disks plus ~1 GiB per
node. `WaitForFirstConsumer` is what makes node-local storage acceptable — the volume is
created after the pod is scheduled. *Limitation:* no replication; losing `node-2` loses
Jenkins' home.

**Helm 4, not 3.** ArgoCD bundles Helm 4, so installing 3 would mean testing a render with one
engine and shipping with another. Helm 4 defaults to **server-side apply**, which surfaced a
real ownership conflict over Calico's IP pool on the first upgrade — Helm 3 would have
silently overwritten the operator's fields instead.

**ExternalDNS against Route53**, not a local provider — a **verifiability** decision. With
local CoreDNS the claim "records are created automatically" is only demonstrable on the
machine that built the cluster; with Route53 the reviewer runs `dig`. The IAM policy is scoped
to **one zone ARN**, and both directions were tested: a write to the delegated zone succeeds,
a write to the parent returns `AccessDenied`. *Trade-off:* public records resolve to RFC1918
addresses, and static AWS keys exist where EKS would use IRSA.

**Jenkins from the official chart**, because it is a StatefulSet, a PVC, two Services, agent
RBAC, a plugin init container, a config-reload sidecar and a JCasC ConfigMap wired together —
reproducing that by hand is transcription. Placement is by **label**, not hostname, so the
constraint survives a rename.

---

## Application and image

**Written rather than adopting the sample.** The linked sample is Spring Boot 2.6.1 from
December 2021 — out of support since 2022, with published CVEs in its transitive set, which
collides directly with the requirement to apply security best practices. Four things have to
be built regardless (Dockerfile, probes, async file logging, metrics), so adopting it saves
one controller class. The endpoint contract is preserved deliberately.

**Distroless base.**

| Base | Size | |
|---|---|---|
| `eclipse-temurin:21-jre` | 303 MiB | 120 MiB never called |
| `…-jre-alpine` | 198 MiB | musl, still carries busybox and apk |
| **`distroless/java21-debian12`** | **183 MiB** | chosen |
| `jlink` runtime | ~110 MiB | rejected on risk |

`jlink` would be smallest, but the module set must be enumerated and `jdeps` cannot see
modules reached by reflection — and Spring reflects heavily. A missing module fails at
runtime, days later.

*Cost, stated plainly:* no shell, so `kubectl exec` gets nothing; logs go to a file, so
`kubectl logs` is empty too. Two of the three reflexes for inspecting a pod are gone.
Survivable because the fluent-bit sidecar shares the log volume and the logs land in
Elasticsearch.

**Layered jar** ordered by change frequency, so a code change rebuilds and pushes **11.1 kB**
instead of a 24 MB fat jar.

---

## Observability

The requirement names five components as if they were one system. They are **two pipelines
that meet only in Grafana** — Prometheus holds numeric series and is not a log store, which is
why Elasticsearch is in the list at all.

**kube-prometheus-stack**, because what it installs is the **Prometheus Operator** — there is
no `prometheus.yml` here. A scrape target is a `ServiceMonitor`; the operator regenerates the
config and reloads it without restarting anything.

Three chart defaults are load-bearing overrides: `storageSpec: {}` means `emptyDir` (the first
restart deletes every sample), the `*SelectorNilUsesHelmValues` flags would make Prometheus
ignore any hand-written `ServiceMonitor` **with no error**, and the chart ships **no resource
requests**, which would fail this cluster's own admission webhook.

**The control plane was invisible until fixed.** Seven targets were down after install, four
because kubeadm binds controller-manager, scheduler, kube-proxy and etcd metrics to loopback.
Disabling those ServiceMonitors was the alternative and was rejected — **a green dashboard
produced by not looking is worse than a red one.**

**ECK, not the Helm chart.** The classic chart is frozen at 8.5.1 (2022), but unlike
ingress-nginx it was **replaced rather than abandoned**: cluster formation, certificate
rotation and shard-aware rolling restarts cannot be templated. Helm renders and exits; it
cannot restart a StatefulSet one pod at a time while watching shard allocation.

**Two fluent-bit deployments**, because one cannot see both sources: the DaemonSet reads
container stdout and covers every other pod, while the application writes only to a file
inside its own pod. The sidecar is a **native sidecar** (`initContainer` +
`restartPolicy: Always`), so it starts before the app and stops after it — which is why
"Graceful shutdown complete" reaches Elasticsearch for a pod that no longer exists.

**Kibana was not installed.** Elasticsearch has no dashboard, Kibana does, and Kibana costs
~1 GiB. Grafana is already a dashboard, so it gets two Elasticsearch datasources instead.

---

## CI/CD

**BuildKit rootless, not kaniko** — **Google archived kaniko on 3 June 2025.** Adopting an
archived tool for a pipeline meant to demonstrate current practice repeats the ingress-nginx
mistake. Mounting the node's `docker.sock` was rejected earlier still: it gives the build pod
root on the node's runtime.

**Images tagged by git commit SHA.** `latest` is pushed for humans and **no Deployment ever
references it** — a moving tag gives a rolling update nothing to compare and `rollout undo` no
image to return to.

**Polling, not a webhook**, because this cluster's public records resolve to RFC1918
addresses and GitHub cannot reach it. Correct for a private cluster, not a downgrade.

**Both jobs are defined in JCasC**, so they survive a rebuild rather than living in someone's
click history.

**The deployment pipeline is an SSH client, not a Kubernetes client.** It runs the same
`08-app.yml` that `site.yml` runs, on the control plane, against that node's own `admin.conf`.
Giving it a kubeconfig would mean two execution models for one file. Consequence worth
stating: **the agent needs no Kubernetes RBAC of its own.**

**One playbook, two callers.** `site.yml` imports it; the pipeline calls it with
`-e app_image_tag=<sha>`. That override is named as an interim answer — `kubectl set image`
makes the cluster and the manifest disagree, and the clean version is the pipeline committing
the tag back for a controller to reconcile.

**Rolling update with `maxSurge: 0, maxUnavailable: 1`.** The earlier `maxUnavailable: 0` was a
stronger guarantee that **could not execute here**: the surge pod needed 320Mi and the spread
constraint forced it onto the node with 297Mi free. Three defensible decisions intersected
into a rollout that could not finish. A guarantee that cannot execute is worth less than a
weaker one that can.

---

## Admission control

**A webhook, though a policy would be better.** `ValidatingAdmissionPolicy` (CEL, GA since
1.30) expresses the same rule inside the API server — no network hop, no TLS, no pods, no
`failurePolicy` dilemma. The case asks for a custom webhook, so that is what is built, and
naming the better answer is part of the answer.

**Go over Java:** `k8s.io/api` carries the `AdmissionReview` types and the image is **12.3 MB**
against ~180 MB with a JVM — which matters for a component on the critical path of every
Deployment write.

**`failurePolicy: Fail`**, because a policy that disappears when its enforcer dies is not a
policy. That forces two replicas across two nodes, a PodDisruptionBudget, and namespace
exclusions.

**The exclusions are not cosmetic.** Before enabling the webhook the cluster was asked what
would happen, and **seven existing Deployments violated the policy** — all upstream charts,
including `tigera-operator`, which reconciles Calico continuously. Without the exclusion its
next update to `calico-typha` would have been rejected by our own webhook, leaving the CNI
unable to repair itself. *Trade-off:* the policy covers workload namespaces, not the platform;
the real fix is setting requests in each chart's values and shrinking the exemption list.

---

## Known limitations

| Limitation | Consequence | Production answer |
|---|---|---|
| Single etcd member | The cluster's single point of failure, forced by the 1+2 topology | Three stacked control plane nodes; `controlPlaneEndpoint` is already set so no certificates change |
| **No etcd snapshot job** | Nothing backs up cluster state — planned, **not built** | A CronJob running `etcdctl snapshot save` off-node, plus a rehearsed restore |
| Single control plane | No API server redundancy | Three behind a load balancer |
| Encryption key on the node | Protects a stolen snapshot, not root on that host | KMS envelope encryption |
| Insecure Vagrant SSH key | Every node trusts a public key — and the deploy pipeline now holds it, which is root on the cluster | Provisioned single-purpose keys |
| Static IAM credentials | A long-lived AWS key in a Secret | IRSA or workload identity federation |
| L2 LoadBalancer | All traffic for an address enters through one node | BGP with a peering router |
| Single-node Elasticsearch | No replicas; losing the node loses the index | Three nodes, replica shards, snapshots |
| Elasticsearch HTTP without TLS | Logs and the credential cross the pod network in clear | cert-manager, or a mesh terminating TLS everywhere |
| fluent-bit uses the `elastic` superuser | A log shipper with full rights, password in two namespaces | A scoped user via ECK's file realm |
| etcd metrics unauthenticated on 2381 | Readable by anything on the node network; opened so the control plane could be scraped | Firewalled to the monitoring node |
| No index lifecycle policy | Old log indices are never deleted | ILM with a retention window |
| Nothing watches certificate expiry | Certificates lapse after a year without warning | A `PrometheusRule` plus scheduled renewal |
| No metrics-server | The HPA in `examples/step-3.1/` would report `<unknown>` | metrics-server or Prometheus Adapter |
| No continuous reconciliation | Ansible is right when it runs, then stops looking | ArgoCD — see [ANSWERS.md](ANSWERS.md) |
