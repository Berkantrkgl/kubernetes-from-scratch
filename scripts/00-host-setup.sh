#!/usr/bin/env bash
#
# Installs VirtualBox and Vagrant on Ubuntu 24.04. Neither distro package works:
# Ubuntu's VirtualBox is from 2024 and won't build against a 7.x kernel, and
# Vagrant left the Ubuntu archive after the licence change.
#
# Safe to re-run.

set -euo pipefail

VBOX_SERIES="7.2"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "Run as your normal user, the script calls sudo itself."

log "Host: Ubuntu ${CODENAME}, kernel $(uname -r)"

log "Adding Oracle VirtualBox repository"
curl -fsSL https://www.virtualbox.org/download/oracle_vbox_2016.asc \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/oracle-virtualbox-2016.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian ${CODENAME} contrib" \
  | sudo tee /etc/apt/sources.list.d/virtualbox.list >/dev/null

log "Adding HashiCorp repository"
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

# any unrelated broken repo makes apt-get update exit non-zero, so don't let
# that kill the script. What matters is whether our packages resolve.
log "Refreshing package indexes"
if sudo apt-get update 2>&1 | grep -Ei '^(E|W):'; then
  warn "Those come from other repositories on this host, not the two above."
fi

log "Verifying our packages resolve"
for p in "virtualbox-${VBOX_SERIES}" vagrant; do
  cand="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')"
  if [[ -z $cand || $cand == "(none)" ]]; then
    die "No installation candidate for '${p}', its index did not load."
  fi
  printf '    %-18s %s\n' "$p" "$cand"
done

log "Installing build toolchain, VirtualBox ${VBOX_SERIES} and Vagrant"
sudo apt-get install -y \
  dkms build-essential "linux-headers-$(uname -r)" \
  "virtualbox-${VBOX_SERIES}" vagrant

# VirtualBox only allows host-only addresses from an allow-list and ships with
# just 192.168.56.0/21 on it. The nodes live on 10.50.0.0/24.
log "Allowing the 10.50.0.0/16 host-only range"
sudo mkdir -p /etc/vbox
if ! sudo grep -qs '10\.50\.0\.0/16' /etc/vbox/networks.conf; then
  echo '* 10.50.0.0/16'    | sudo tee -a /etc/vbox/networks.conf >/dev/null
  echo '* 192.168.56.0/21' | sudo tee -a /etc/vbox/networks.conf >/dev/null
fi
sudo cat /etc/vbox/networks.conf

# did the out-of-tree modules compile? Secure Boot doesn't matter yet, it only
# blocks loading.
log "Checking kernel module build"
BUILD_OK=0
if dkms status 2>/dev/null | grep -qE 'vboxhost.*(installed|built)'; then
  dkms status | grep vboxhost
  BUILD_OK=1
elif modinfo vboxdrv >/dev/null 2>&1; then
  echo "vboxdrv found at: $(modinfo -n vboxdrv)"
  BUILD_OK=1
fi

if [[ $BUILD_OK -eq 0 ]]; then
  warn "Modules did not build against $(uname -r)."
  warn "Log: /var/lib/dkms/vboxhost/*/build/make.log"
  warn "Either boot an older kernel or switch the Vagrant provider to libvirt."
  exit 1
fi

log "Modules built successfully."

if sudo modprobe vboxdrv 2>/dev/null; then
  log "vboxdrv loaded. VirtualBox is ready."
else
  warn "Built but won't load, Secure Boot is on. Either turn it off in the"
  warn "firmware, or sign the modules: ./scripts/01-secureboot-sign.sh enroll"
fi

log "Installed versions"
vboxmanage --version 2>/dev/null || echo "VBoxManage: not usable until modules load"
vagrant --version

log "Done."
