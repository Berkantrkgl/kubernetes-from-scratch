# Case study Vagrantfile with three fixes:
#   - MASTER_MEMORY was reading ENV["MASTER_CPUS"]
#   - env vars come back as strings, (1.."2") raises, so .to_i everywhere
#   - focal64 is EOL and ships no Guest Additions, so /vagrant never mounts
#
# Control plane gets the least memory, it stays tainted. Workers carry Jenkins,
# Elasticsearch and Prometheus.

IMAGE_NAME    = ENV["IMAGE_NAME"] || "bento/ubuntu-24.04"
MASTER_MEMORY = (ENV["MASTER_MEMORY"] || 2560).to_i
MASTER_CPUS   = (ENV["MASTER_CPUS"]   || 2).to_i
WORKER_NODES  = (ENV["WORKER_NODES"]  || 2).to_i
WORKER_MEMORY = (ENV["WORKER_MEMORY"] || 4608).to_i
WORKER_CPUS   = (ENV["WORKER_CPUS"]   || 3).to_i
BASE_IP       = ENV["BASE_IP"] || "10.50.0"

Vagrant.configure("2") do |config|
  config.ssh.insert_key = false

  config.vm.define "k8s-master" do |master|
      master.vm.provider "virtualbox" do |v|
        v.memory = MASTER_MEMORY
        v.cpus = MASTER_CPUS
      end
      master.vm.box = IMAGE_NAME
      master.vm.network "private_network", ip: "#{BASE_IP}.#{10}"
      master.vm.hostname = "k8s-master"
  end

  (1..WORKER_NODES).each do |i|
      config.vm.define "node-#{i}" do |node|
          node.vm.provider "virtualbox" do |v|
            v.memory = WORKER_MEMORY
            v.cpus = WORKER_CPUS
          end
          node.vm.box = IMAGE_NAME
          node.vm.network "private_network", ip: "#{BASE_IP}.#{i + 10}"
          node.vm.hostname = "node-#{i}"
      end
  end
end