# Design decisions

The choices that were not obvious, and what each one cost.

One rule runs through all the version picks: one release back, at rest. A `.0` is where the
ecosystem has not caught up yet, and a patch published the same day is a line still being
corrected.

---

## Environment

The case names Vagrant and VirtualBox, so that is what I used — KVM would be faster on a
Linux host but matching the reviewer's environment is worth more than the overhead.

I moved off the supplied `ubuntu/focal64` box. It is Ubuntu 20.04, out of standard support
since May 2025, and Canonical's boxes ship without Guest Additions — so `/vagrant` never
mounts, and that folder is how the cluster config reaches the nodes.

Memory is reversed from the supplied defaults, which give the control plane 4 GiB and each
worker 2. The control plane runs about 1.2 GiB of components; each worker carries Jenkins or
Elasticsearch plus Prometheus, an ingress controller and application pods. So 2.5 / 4.5 /
4.5, with Elasticsearch and Prometheus deliberately on different workers — they are the two
biggest consumers and would starve a single 4.5 GiB node.

The supplied Vagrantfile also has a bug worth mentioning: `MASTER_MEMORY` reads
`ENV["MASTER_CPUS"]`, so setting `MASTER_CPUS=2` boots the control plane with 2 MB of RAM.
Invisible while you use the defaults.

---

## Bootstrap

kubeadm with a config file rather than flags. Kubespray was the other option the case allows,
and it hides exactly the layer this exercise is about. Within kubeadm, several settings have
no flag at all — kubelet eviction thresholds, etcd timers, certificate SANs, the kube-proxy
mode.

Kubernetes 1.36.4: one minor behind stable, mature patch. 1.28 would satisfy the requirement
but reads as a floor rather than a choice.

**The control plane keeps its taint.** Untainting would free 2.5 GiB of schedulable memory,
which is tempting on a host this size, but a control plane running workloads is not
production-ready — a workload that exhausts memory there takes the API server with it. There
is one exception: the deployment pipeline's Ansible agent tolerates the taint, because it
runs only `ansible` and `ssh`, and on a worker its 384 MB is the exact headroom the rollout
it is driving needs.

Secrets are encrypted at rest with `secretbox`. I picked it from upstream's own guidance,
where the obvious answers lose: `aescbc` is vulnerable to padding oracles, `aesgcm` needs
automated key rotation because of its nonce space, and KMS needs a key manager this cluster
does not have.

The provider order matters more than the provider. `identity` sits second so Secrets written
before encryption was on stay readable. Putting it first would be the silent version of this
mistake — everything keeps being written in plaintext and nothing complains.

The honest limit: the key is on the control plane node. It protects a stolen etcd snapshot or
a cloned disk, not someone who already has root there.

---

## Networking

**Calico**, because Flannel does not implement NetworkPolicy — and applying one to a Flannel
cluster *succeeds*. The object is stored and nothing happens. Cilium is genuinely stronger,
and costs about 2.5× the per-node memory.

VXLAN in CrossSubnet mode with BGP off. All three nodes share one L2 segment, so
encapsulation is skipped for same-subnet traffic and only used across a boundary — close to
BGP performance without a router to peer with.

The CIDRs were chosen by elimination, not preference: `192.168/16` is Calico's own default
*and* where VirtualBox puts host-only networks, `172.17/16` is `docker0`, `10.244/16` is
Flannel's. That leaves pod `10.32.0.0/16` and Service `10.96.0.0/16`. The `/16` for Services
instead of kubeadm's `/12` is about address-plan hygiene rather than performance — kube-proxy
writes rules per Service, not per address, so the size changes nothing in iptables.

The trap in this environment repeats three times. Every VM has the same NAT address
`10.0.2.15` on `eth0` while real traffic uses `eth1`, and kubelet, the API server and Calico
each pick a node address independently — all three defaulting to the interface behind the
default route. Two of the three fail quietly: the cluster reports `Ready` while `kubectl
logs` is broken, or pods talk within a node but not across nodes. Calico is pinned by CIDR
rather than interface name so a rename does not break it.

MetalLB runs in L2 mode because there is no BGP-capable router here. Worth knowing what that
costs: the address pool has to sit in the node subnet, since ARP does not leave the broadcast
domain, and all traffic for one address enters through a single elected node.

---

## Ingress

This is the decision with the most research behind it, because the default answer stopped
being available. **`kubernetes/ingress-nginx` is retired** — final release 19 March 2026, its
supported-Kubernetes table stops at 1.35 while this cluster runs 1.36.4, and the Kubernetes
Security Response Committee wrote that staying on it leaves users vulnerable. The artifacts
still install cleanly and nothing warns you, which is the trap.

What I looked at:

| | |
|---|---|
| `kubernetes/ingress-nginx` | unmaintained, untested on 1.36, no more security fixes |
| InGate, the announced successor | archived March 2026 without ever cutting a release |
| NGINX Gateway Fabric | Gateway API only — it does not process `Ingress`, and the case says Ingress |
| Traefik, HAProxy | nothing wrong with either; the case says load-balanced using **Nginx** |

I went with F5's `nginx/kubernetes-ingress` OSS v5.5.4 — a different project from the
community one despite the near-identical name, written by the NGINX team, tested on 1.29 to
1.36, monthly releases.

It costs one thing: the annotation prefix is `nginx.org/`, so anything copied from an
ingress-nginx example is silently ignored. That pushed a later decision too — each backend
serves its own subpath (`--web.route-prefix`, `serve_from_sub_path`) instead of relying on
the controller's rewrite dialect.

I also overrode the chart's `externalTrafficPolicy: Local`. Not because client IP does not
matter, but because of MetalLB issue #2747: with `Local` and two replicas on different nodes,
several speakers answer ARP for the same VIP with different MACs and connectivity goes
intermittent about half an hour in. `X-Forwarded-For` does not rescue the client IP either —
SNAT happens before NGINX, so NGINX already sees the node address. In production the answer
is MetalLB in BGP mode, where `Local` costs nothing.

---

## Platform

kubeadm installs no storage provisioner at all, so every PVC would sit `Pending` — and
Jenkins, Prometheus, Grafana and Elasticsearch all need one. Longhorn and Rook/Ceph are the
real bare-metal answers and both want spare disks and roughly a gigabyte per node.
local-path-provisioner is a single 30 MB Deployment, and `WaitForFirstConsumer` is what makes
node-local storage acceptable: the volume is created after the pod is scheduled. No
replication though — losing `node-2` loses Jenkins' home.

Helm 4 rather than 3, because ArgoCD bundles Helm 4 and I did not want to render charts with
one engine and ship them with another. Helm 4 defaults to server-side apply, which surfaced a
real ownership conflict over Calico's IP pool on the first upgrade. Helm 3 would have
silently overwritten the operator's fields instead, so the newer major turning it into a
visible error is an argument in its favour.

ExternalDNS points at Route53 instead of a local provider, and that is a verifiability
decision rather than a technical one. With local CoreDNS, "records are created automatically"
is only demonstrable on the machine that built the cluster — a reviewer gets a screenshot.
With Route53 they run `dig`. The IAM policy is scoped to one zone ARN rather than the
documented `hostedzone/*`, and I tested both directions: a write to the delegated zone
succeeds, a write to the parent gets `AccessDenied`.

The cost is real — a public zone now resolves to RFC1918 addresses, and static AWS keys exist
where EKS would give me IRSA.

Jenkins comes from the official chart. ExternalDNS is five static objects so I wrote those by
hand; Jenkins is a StatefulSet, a PVC, two Services, agent RBAC, a plugin init container, a
config-reload sidecar and a JCasC ConfigMap wired together. Reproducing that by hand is
transcription, not engineering. It is pinned to `node-2` by label rather than hostname, so
the constraint survives a rename.

---

## The application and its image

I wrote the application instead of adopting the linked sample. The sample is Spring Boot
2.6.1 from December 2021 — out of support since 2022, with published CVEs in its transitive
set, which sits badly next to a requirement about security best practices. Four things have
to be built either way: a Dockerfile, Actuator probes, async file logging and Micrometer
metrics. Adopting it saves one controller class. I kept its endpoint contract.

For the base image:

| | | |
|---|---|---|
| `eclipse-temurin:21-jre` | 303 MiB | 120 MiB of shell and tools never called |
| the alpine variant | 198 MiB | musl, still carries busybox and apk |
| **distroless java21** | **183 MiB** | what I used |
| a `jlink` runtime | ~110 MiB | rejected on risk |

`jlink` would have been much smaller, but the module set has to be enumerated and `jdeps`
cannot see modules reached by reflection — and Spring reflects heavily. A missing module does
not fail the build, it fails on whichever code path first needs it, possibly days later.

Distroless costs something worth stating: no shell, so `kubectl exec` gets nothing, and since
logs go to a file rather than stdout, `kubectl logs` is empty too. Two of the three reflexes
for looking at a running pod are gone. It works out because the fluent-bit sidecar shares the
log volume and has a shell, and the logs are in Elasticsearch anyway.

---

## Observability

The requirement names five components as if they were one system. They are two pipelines that
only meet in Grafana — Prometheus holds numeric series and is not a log store, which is why
Elasticsearch is in the list at all.

kube-prometheus-stack, mainly because what it installs is the Prometheus Operator. There is
no `prometheus.yml` in this repository; a scrape target is a `ServiceMonitor` and the operator
regenerates the config and reloads it without restarting anything.

Three of its defaults had to go. `storageSpec: {}` means `emptyDir`, so it installs, looks
healthy, and the first restart deletes every sample. The `*SelectorNilUsesHelmValues` flags
make Prometheus read only objects carrying the chart's own labels — a hand-written
`ServiceMonitor` is stored and never read, with no error anywhere. And the chart ships no
resource requests at all, which puts everything in BestEffort and would fail this cluster's
own admission webhook.

Seven scrape targets were down right after the install, four of them because kubeadm binds
controller-manager, scheduler, kube-proxy and etcd metrics to loopback and Prometheus runs on
a worker. Disabling those ServiceMonitors was the easy fix and I rejected it — the
requirement says monitor the cluster, and a green dashboard produced by not looking is worse
than a red one.

For Elasticsearch I used ECK rather than the Helm chart. The classic chart is frozen at 8.5.1
from 2022, but unlike ingress-nginx it was replaced rather than abandoned: cluster formation,
certificate rotation and shard-aware rolling restarts cannot be templated. Helm renders and
exits; it cannot restart a StatefulSet one pod at a time while watching shard allocation.

fluent-bit runs twice, because one deployment cannot see both sources. The DaemonSet reads
container stdout and covers every other pod; the application writes only to a file inside its
own pod, which a DaemonSet has no path to. That sidecar is a native sidecar — an
`initContainer` with `restartPolicy: Always` — so it starts before the app and stops after
it, which is why "Graceful shutdown complete" reaches Elasticsearch for a pod that no longer
exists.

No Kibana. Elasticsearch has no dashboard, Kibana does, and Kibana costs about a gigabyte on a
host with none to spare. Grafana is already a dashboard, so it got two Elasticsearch
datasources instead.

---

## CI/CD

BuildKit rootless rather than kaniko. Kaniko was my default answer going in, and Google
archived the repository on 3 June 2025 — adopting an archived tool for a pipeline meant to
show current practice would repeat the ingress-nginx mistake exactly. Mounting the node's
`docker.sock` was out before that: it gives the build pod root on the node's runtime.

Images are tagged with the git commit SHA. `latest` is pushed for anyone typing `docker pull`
and no Deployment ever references it — a moving tag gives a rolling update nothing to compare
and `rollout undo` no image to go back to.

Polling instead of a webhook, because this cluster's public records resolve to RFC1918
addresses and GitHub cannot reach it. Both jobs are defined in JCasC rather than created in
the UI, so they survive a rebuild.

The deployment pipeline is an SSH client, not a Kubernetes client. It runs the same
`08-app.yml` that `site.yml` runs, on the control plane, against that node's own
`admin.conf`. Giving it a kubeconfig would mean two execution models for one file depending
on who called it. A side effect worth noticing: the agent needs no Kubernetes RBAC of its
own.

One playbook, two callers. `site.yml` imports it so one command produces the whole cluster;
the pipeline calls it with `-e app_image_tag=<sha>`. That override is an interim answer, not
a design — `kubectl set image` makes the cluster and the manifest disagree, and the clean
version is the pipeline committing the tag back for something to reconcile.

The rollout uses `maxSurge: 0, maxUnavailable: 1`. I started with `maxUnavailable: 0`, which
is the stronger promise, and it could not execute here: the surge pod wanted 320 MB and the
spread constraint sent it to the node with 297 MB free. Three defensible decisions — no
unavailability, even spread, a cluster at 94% — intersected into a rollout that could not
finish.

---

## Admission control

The case asks for a custom validating webhook, so that is what this is. But
`ValidatingAdmissionPolicy` — CEL, GA since 1.30 — expresses the same rule inside the API
server with no network hop, no TLS, no pods to keep alive and no `failurePolicy` dilemma. For
a rule this simple it is the better production answer, and I would rather say so than pretend
the webhook is the only way.

Go rather than Java: `k8s.io/api` carries the `AdmissionReview` types directly and the image
is 12.3 MB against roughly 180 with a JVM. That matters here more than anywhere else, because
this thing sits on the path of every Deployment write in the cluster.

`failurePolicy: Fail`, because a policy that disappears when its enforcer dies is not a
policy. That forces two replicas across two nodes and a PodDisruptionBudget.

It also forces namespace exclusions, and those are not cosmetic. Before turning the webhook
on I asked the cluster what would happen, and seven Deployments already violated the policy —
all of them upstream charts, including `tigera-operator`, which reconciles Calico
continuously. Without the exclusion its next update to `calico-typha` would have been
rejected by my own webhook, leaving the CNI unable to repair itself. The policy now covers
workload namespaces rather than the platform; the real fix is setting requests in each
chart's values and shrinking the exemption list until only `kube-system` is left.

---

## Known limitations

| | Consequence | What production would do |
|---|---|---|
| Single etcd member | The cluster's single point of failure, forced by the 1+2 topology | Three stacked control plane nodes; `controlPlaneEndpoint` is already set so no certificates change |
| No etcd snapshot job | Nothing backs up cluster state — planned, not built | A CronJob running `etcdctl snapshot save` off-node, plus a rehearsed restore |
| Single control plane | No API server redundancy | Three behind a load balancer |
| Encryption key on the node | Protects a stolen snapshot, not root on that host | KMS envelope encryption |
| Insecure Vagrant SSH key | Every node trusts a public key, and the deploy pipeline now holds it — which is root on the cluster | Provisioned single-purpose keys |
| Pipeline credentials applied by hand | `site.yml` gives a working cluster, but the Docker Hub token, deploy key and SSH key are separate, so the Jenkins jobs do not run on a fresh rebuild until they are applied | External Secrets Operator pulling them from a secret manager |
| Static IAM credentials | A long-lived AWS key in a Secret | IRSA, or workload identity federation |
| L2 LoadBalancer | All traffic for an address enters through one node | BGP with a peering router |
| Single-node Elasticsearch | No replicas; losing the node loses the index | Three nodes, replica shards, snapshots |
| Elasticsearch HTTP without TLS | Logs and the credential cross the pod network in clear | cert-manager, or a mesh terminating TLS everywhere |
| fluent-bit uses the `elastic` superuser | A log shipper with full rights, and the password exists in two namespaces | A scoped user via ECK's file realm |
| etcd metrics unauthenticated on 2381 | Readable by anything on the node network; opened so the control plane could be scraped at all | Firewalled to the monitoring node |
| No index lifecycle policy | Old log indices are never deleted | ILM with a retention window |
| Nothing watches certificate expiry | Certificates lapse after a year with no warning | A `PrometheusRule` plus scheduled renewal |
| No metrics-server | The HPA in `examples/step-3.1/` would report `<unknown>` | metrics-server or Prometheus Adapter |
| Ingress hostnames literal in two manifests | `dns_zone` is a variable but Kustomize does not template | A Kustomize overlay per environment |
| No continuous reconciliation | Ansible is right when it runs, then stops looking | ArgoCD — see [ANSWERS.md](ANSWERS.md) |
