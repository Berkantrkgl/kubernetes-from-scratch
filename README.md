# Kubernetes from Scratch — DevOps Case Study

A three-node Kubernetes cluster built from scratch on local VMs: kubeadm for the bootstrap,
Ansible for everything above it, and Jenkins, monitoring, logging and a custom admission
webhook running on top. No managed control plane — everything from the certificates up is
configured in this repository, and the whole cluster rebuilds from three empty VMs with one
command.

| | |
|---|---|
| **Written answers** to the case's prose questions | [ANSWERS.md](ANSWERS.md) |
| **Design decisions**, alternatives and limitations | [DESIGN.md](DESIGN.md) |

---

## Environment

| Node | Case study | Role | Address | Memory |
|---|---|---|---|---|
| `k8s-master` | Node 1 | control plane, taint retained | 10.50.0.10 | 2.5 GiB |
| `node-1` | Node 2 | worker | 10.50.0.11 | 4.5 GiB |
| `node-2` | **Node 3** | worker — Jenkins runs here | 10.50.0.12 | 4.5 GiB |

```
Node network   10.50.0.0/24        Pod CIDR    10.32.0.0/16
Service CIDR   10.96.0.0/16        MetalLB     10.50.0.200-250
```

Kubernetes 1.36.4 · containerd 2.3 · Calico · Helm 4 · Spring Boot 4 / Java 21

Reachable from outside the cluster, resolved through public DNS:

```
app.k8s.berkan.link            the application, behind the Ingress
jenkins.k8s.berkan.link        Jenkins, behind a LoadBalancer Service
monitor.k8s.berkan.link/{prometheus,grafana,alertmanager,elasticsearch}
```

---

## Rebuilding from nothing

```bash
./scripts/00-host-setup.sh                      # VirtualBox + Vagrant on the host
vagrant up                                      # three VMs

cd ansible
ansible-playbook site.yml -e @../route53.yml    # everything else
```

**Measured on a clean rebuild — three empty VMs to everything running: 11 minutes 49
seconds, `failed=0`.** A second run reports `changed=0` on all three hosts, which is the
check that the playbooks describe a state rather than repeat actions.

**The Route53 credential is the only thing that cannot be generated on a node**, because it
belongs to an AWS account. Create `route53.yml` in the repository root before the first run
— it is gitignored, and `-e @file` rather than `-e key=value` keeps the value out of `argv`
where `ps` could read it:

```yaml
route53_access_key_id: AKIA...
route53_secret_access_key: ...
```

Everything else — the encryption key, the Grafana and Jenkins admin passwords, the webhook's
TLS certificate — is generated on the control plane during the run and never enters this
repository.

---

## The pipelines

```
git push  →  build-and-push  →  query-echo:<git-sha> → Docker Hub
                   ↓ post success
              deploy-app  →  ssh → ansible-playbook 08-app.yml → rollout status
```

Both jobs are defined in JCasC, so they survive a rebuild. The deployment pipeline runs the
same `08-app.yml` that `site.yml` runs — one playbook, two callers, no drift between them.

---

## Layout

```
Vagrantfile          the three VMs
scripts/             host prerequisites
ansible/             nine playbooks; site.yml runs them in order
  Jenkinsfile          deployment pipeline          (2.3)
cluster/             kubeadm config and Helm values for every chart
k8s/                 manifests applied by Ansible: app, externaldns, monitoring, webhook
app/                 the Java application
  Dockerfile           multi-stage, distroless      (1.2)
  Jenkinsfile          build pipeline               (2.2)
webhook/             the validating admission webhook, in Go   (2.4)
examples/step-3.1/   sample manifests for the written answer to 3.1
```

---

## Where each requirement lives

| | Requirement | Implementation | Answer |
|---|---|---|---|
| 1.1 | Java app printing query parameters | `app/` | |
| 1.2 | Multi-stage Dockerfile, small image, security | `app/Dockerfile` | [build acceleration](ANSWERS.md#12a--strategies-for-accelerating-the-application-build) |
| 1.3 | Production-ready cluster, custom subnets | `cluster/kubeadm-config.yaml` | |
| 1.3.c | GitOps | not installed | [why](ANSWERS.md#13c--gitops-and-why-it-is-not-installed) |
| 1.4 | ExternalDNS | `k8s/externaldns/` | |
| 1.5 | Jenkins on Node 3, JCasC, persistent, LoadBalancer | `cluster/jenkins/values.yaml` | |
| 1.6 | Prometheus · Elasticsearch · Grafana · fluent-bit · AlertManager | `cluster/monitoring/`, `k8s/monitoring/` | |
| 1.7 | Async file logging, 1 GB cap, daily rotation | `app/…/logback-spring.xml` | [design](ANSWERS.md#17--logging-design-asynchronous-capped-at-1-gb-rotated-daily) |
| 2.1 | 4 pods across both workers, load balanced by NGINX | `k8s/app/` | |
| 2.2 | Build pipeline | `app/Jenkinsfile` | |
| 2.3 | Deployment pipeline using Ansible | `ansible/Jenkinsfile`, `playbooks/08-app.yml` | [zero downtime](ANSWERS.md#23c--achieving-zero-downtime-deployments) |
| 2.4 | Validating admission webhook | `webhook/`, `k8s/webhook/` | |
| 3.1 | Resource contention between two applications | `examples/step-3.1/` | [answer](ANSWERS.md#31--app-x-must-scale-under-load-on-a-cluster-that-cannot-add-nodes) |
| 3.2 | Strategy and traffic shift for a critical application | — | [answer](ANSWERS.md#32--deploying-a-critical-application-and-shifting-traffic) |

Known limitations, each with what production would do instead, are at the end of
[DESIGN.md](DESIGN.md#known-limitations).
