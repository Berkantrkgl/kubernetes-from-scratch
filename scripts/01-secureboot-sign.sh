#!/usr/bin/env bash
#
# Signs the VirtualBox kernel modules so they load under Secure Boot. They are
# built on this machine and carry no signature, so the kernel rejects them:
#
#     modprobe: ERROR: could not insert 'vboxdrv': Key was rejected by service
#
# Only needed if you keep Secure Boot on. Turning it off in the firmware works
# too and needs no maintenance.
#
#   ./01-secureboot-sign.sh enroll   once, then reboot
#   ./01-secureboot-sign.sh sign     after the reboot, and after every upgrade

set -euo pipefail

MOK_DIR=/var/lib/shim-signed/mok
MODULES=(vboxdrv vboxnetflt vboxnetadp vboxpci)

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

cmd_enroll() {
  log "Generating a Machine Owner Key"
  sudo mkdir -p "$MOK_DIR"

  if sudo test -f "$MOK_DIR/MOK.der"; then
    warn "Key already exists at $MOK_DIR, reusing it."
  else
    sudo openssl req -nodes -new -x509 \
      -newkey rsa:2048 -days 36500 -outform DER \
      -keyout "$MOK_DIR/MOK.priv" \
      -out    "$MOK_DIR/MOK.der" \
      -subj "/CN=VirtualBox Module Signing/"
    sudo chmod 600 "$MOK_DIR/MOK.priv"
  fi

  log "Registering the key with the firmware"
  echo
  echo "  Pick a short password you can type on a US layout -- MOK Manager runs"
  echo "  before the OS and ignores your keyboard settings."
  echo
  sudo mokutil --import "$MOK_DIR/MOK.der"

  cat <<'EOF'

  Now reboot. A blue "MOK Manager" screen appears before Ubuntu starts:

     Enroll MOK -> Continue -> Yes -> password -> Reboot

  Skip past it and the key is not enrolled. After the reboot:

     ./scripts/01-secureboot-sign.sh sign

EOF
}

cmd_sign() {
  local kver signer signed=0
  kver="$(uname -r)"
  signer="/usr/src/linux-headers-${kver}/scripts/sign-file"

  sudo test -f "$MOK_DIR/MOK.priv" || die "No MOK key found. Run: $0 enroll"
  [[ -x $signer ]] || die "sign-file missing at $signer"

  if ! mokutil --test-key "$MOK_DIR/MOK.der" 2>/dev/null | grep -q 'is already enrolled'; then
    die "Key not enrolled yet. Reboot and finish the MOK Manager screen."
  fi

  log "Signing VirtualBox modules for kernel ${kver}"
  for m in "${MODULES[@]}"; do
    local path
    path="$(modinfo -n "$m" 2>/dev/null || true)"
    [[ -n $path ]] || { warn "skip ${m}, not built for this kernel"; continue; }
    sudo "$signer" sha256 "$MOK_DIR/MOK.priv" "$MOK_DIR/MOK.der" "$path"
    echo "    signed ${m}"
    signed=$((signed + 1))
  done
  [[ $signed -gt 0 ]] || die "Nothing was signed, are the modules built?"

  log "Loading vboxdrv"
  sudo modprobe vboxdrv
  lsmod | grep -E '^vbox' || die "vboxdrv still not loaded"

  log "VirtualBox is ready: $(vboxmanage --version)"
  warn "Run '$0 sign' again after every kernel or VirtualBox upgrade."
}

case "${1:-}" in
  enroll) cmd_enroll ;;
  sign)   cmd_sign   ;;
  *)      die "Usage: $0 {enroll|sign}" ;;
esac
