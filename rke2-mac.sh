#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[rke2-mac] failed at line ${LINENO}" >&2' ERR

# RKE2 is Linux-only and (unlike k3s) has no "RKE2-in-Docker" like k3d.
# So on macOS we run RKE2 inside a lightweight Lima Linux VM.
#
# Adjust to a published RKE2 release: https://github.com/rancher/rke2/releases
RKE2_VERSION='v1.36.2+rke2r1'
VM_NAME='rke2'
KUBECONFIG_DST="${HOME}/.kube/rke2-lima.yaml"

require_mac() {
  [[ "$(uname -s)" == 'Darwin' ]] || { echo 'This script is for macOS only.' >&2; exit 1; }
}

ensure_tools() {
  which brew    >/dev/null 2>&1 || { echo 'Homebrew is required: https://brew.sh' >&2; exit 1; }
  which limactl >/dev/null 2>&1 || { echo 'Installing lima...';    brew install lima; }
  which kubectl >/dev/null 2>&1 || { echo 'Installing kubectl...'; brew install kubectl; }
}

install_rke2() {
  require_mac
  ensure_tools

  if limactl list --quiet 2>/dev/null | grep -qx "${VM_NAME}"; then
    echo "Using existing Lima VM '${VM_NAME}'..."
  else
    echo "Creating Lima Ubuntu 24.04 VM '${VM_NAME}'..."
    # Pin Ubuntu 24.04 LTS (noble). Lima's `ubuntu-lts` now resolves to 26.04 / kernel 7.x,
    # which is ahead of RKE2's validated platform matrix and crash-loops the kubelet.
    local cfg="${TMPDIR:-/tmp}/rke2-lima.yaml"
    cat > "${cfg}" <<'EOF'
images:
  - location: "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
    arch: "x86_64"
  - location: "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"
cpus: 4
memory: "8GiB"
disk: "40GiB"
EOF
    # RKE2 manages its own containerd. Skip Lima's separate runtime setup.
    limactl start --name="${VM_NAME}" --tty=false --vm-type=vz --network=vzNAT --containerd=none "${cfg}"
    rm -f "${cfg}"
  fi

  echo 'Preparing RKE2 config inside the VM...'
  limactl shell "${VM_NAME}" sudo mkdir -p /etc/rancher/rke2
  limactl shell "${VM_NAME}" sudo bash -c 'if [[ ! -e /etc/rancher/rke2/config.yaml ]]; then cat > /etc/rancher/rke2/config.yaml; fi' <<'EOF'
write-kubeconfig-mode: "0644"
ingress-controller: traefik
node-ip: 192.168.5.15
EOF

  echo "Installing RKE2 ${RKE2_VERSION} inside the VM (first boot can take several minutes)..."
  limactl shell "${VM_NAME}" sudo bash -c \
    "curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION='${RKE2_VERSION}' sh -"
  limactl shell "${VM_NAME}" sudo systemctl enable --now rke2-server.service

  echo 'Waiting for kubeconfig to be generated...'
  limactl shell "${VM_NAME}" sudo bash -c 'until [ -f /etc/rancher/rke2/rke2.yaml ]; do sleep 3; done'

  # Export the kubeconfig to the host FIRST, then wait from the host via Lima's 127.0.0.1:6443
  # forward. This avoids holding a long-lived `limactl shell` session open during the slow cold
  # boot — heavy image pulls can saturate the guest and wedge the SSH ControlMaster.
  echo "Exporting kubeconfig to ${KUBECONFIG_DST}..."
  mkdir -p "$(dirname "${KUBECONFIG_DST}")"
  limactl shell "${VM_NAME}" sudo cat /etc/rancher/rke2/rke2.yaml > "${KUBECONFIG_DST}"
  chmod 600 "${KUBECONFIG_DST}"

  echo 'Waiting for node to be Ready (cold first boot pulls all control-plane images)...'
  KUBECONFIG="${KUBECONFIG_DST}" kubectl wait --for=condition=Ready nodes --all --timeout=600s

  echo 'RKE2 (via Lima) install complete.'
  echo "Use it with: $0 kubectl get nodes"
}

enable_ingress() {
  require_mac
  limactl shell "${VM_NAME}" sudo bash -s <<'EOF'
set -euo pipefail
config=/etc/rancher/rke2/config.yaml
current=$(cat "$config")
legacy='write-kubeconfig-mode: "0644"
disable:
  - rke2-traefik
  - rke2-ingress-nginx'
updated='write-kubeconfig-mode: "0644"
ingress-controller: traefik'

if [[ "$current" == "$updated" || "$current" == "$updated"$'\nnode-ip: 192.168.5.15' ]]; then
  echo 'Traefik is already configured.'
elif [[ "$current" == "$legacy" ]]; then
  backup="$config.before-traefik"
  cp -p --update=none "$config" "$backup"
  tmp=$(mktemp "$config.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  chmod --reference="$config" "$tmp"
  chown --reference="$config" "$tmp"
  printf '%s\n' "$updated" > "$tmp"
  mv "$tmp" "$config"
  echo "Restarting RKE2. Previous config saved to $backup"
  if ! systemctl restart rke2-server; then
    cp -p "$backup" "$config"
    systemctl restart rke2-server
    exit 1
  fi
else
  echo "Custom RKE2 config detected at $config. Set ingress-controller: traefik and remove rke2-traefik from disable, then restart rke2-server." >&2
  exit 1
fi
EOF
  local -a kube=(kubectl --kubeconfig "${KUBECONFIG_DST}")
  "${kube[@]}" wait --for=condition=Ready nodes --all --timeout=300s
  "${kube[@]}" wait --for=create ingressclass/traefik --timeout=300s
  "${kube[@]}" -n kube-system wait --for=create service/rke2-traefik --timeout=300s
  "${kube[@]}" -n kube-system wait --for=create daemonset/rke2-traefik --timeout=300s
  "${kube[@]}" -n kube-system rollout status daemonset/rke2-traefik --timeout=300s
  echo 'Traefik is ready.'
}

uninstall_rke2() {
  require_mac
  which limactl >/dev/null 2>&1 || { echo 'lima not installed; nothing to uninstall.'; return 0; }
  if limactl list --quiet 2>/dev/null | grep -qx "${VM_NAME}"; then
    echo "Stopping and deleting Lima VM '${VM_NAME}'..."
    limactl stop -f "${VM_NAME}" 2>/dev/null || true
    limactl delete -f "${VM_NAME}"
  else
    echo "No Lima VM named '${VM_NAME}'."
  fi
  rm -f "${KUBECONFIG_DST}"
  echo 'RKE2 uninstall complete.'
}

status_rke2() {
  require_mac
  limactl list 2>/dev/null || true
  KUBECONFIG="${KUBECONFIG_DST}" kubectl get nodes 2>/dev/null || echo 'cluster not reachable.'
}

case "${1:-}" in
  install)   install_rke2 ;;
  enable-ingress) enable_ingress ;;
  uninstall) uninstall_rke2 ;;
  status)    status_rke2 ;;
  kubectl)
    shift
    exec kubectl --kubeconfig "${KUBECONFIG_DST}" "$@"
    ;;
  *) echo "usage: $0 {install|enable-ingress|uninstall|status|kubectl [args...]}" >&2; exit 1 ;;
esac
