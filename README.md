# Kubernetes from Scratch — DevOps Case Study

A three-node Kubernetes cluster built from scratch on local VMs: kubeadm for the
bootstrap, Ansible for node provisioning, and Jenkins, monitoring and a custom
admission webhook running on top of it.

No managed control plane here — everything from the certificates up is set up and
configured in this repository.

## Environment

Three VirtualBox VMs on a host-only network, created with Vagrant.

| Node | Role | Address | Memory |
|---|---|---|---|
| `k8s-master` | control plane | 10.50.0.10 | 2.5 GiB |
| `node-1` | worker | 10.50.0.11 | 4.5 GiB |
| `node-2` | worker | 10.50.0.12 | 4.5 GiB |

The control plane keeps its taint and runs no workloads, so both workers carry
the platform components and the application.

```
Node network   10.50.0.0/24
Pod CIDR       10.32.0.0/16
Service CIDR   10.96.0.0/16
```

Kubernetes 1.36.4, containerd 2.3, Calico as the CNI.

## Layout

```
scripts/     host prerequisites: VirtualBox, Vagrant, host-only network
Vagrantfile  the three VMs
ansible/     node preparation - swap, kernel modules, containerd, kubeadm packages
cluster/     kubeadm configuration
```

## Getting started

```bash
./scripts/00-host-setup.sh          # VirtualBox + Vagrant on the host
vagrant up                          # three VMs

cd ansible
ansible all -m ping                 # check connectivity
ansible-playbook playbooks/01-node-prep.yml

vagrant ssh k8s-master
sudo kubeadm init --config /vagrant/cluster/kubeadm-config.yaml
```

The playbook is idempotent — running it twice should report `changed=0`.

## Progress

- [x] Host prerequisites and VM environment
- [x] Node preparation with Ansible
- [ ] Cluster bootstrap and Calico
- [ ] MetalLB, ingress-nginx, ExternalDNS
- [ ] Java application and container image
- [ ] Jenkins with configuration as code
- [ ] Prometheus, Elasticsearch, Grafana, fluent-bit, AlertManager
- [ ] Build and deployment pipelines
- [ ] Validating admission webhook

Design decisions and the alternatives considered are documented separately as the
work progresses.
