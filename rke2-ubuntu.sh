#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[rke2-ubuntu] failed at line ${LINENO}" >&2' ERR

# Adjust to a published RKE2 release: https://github.com/rancher/rke2/releases
# (or switch to channel-based install with INSTALL_RKE2_CHANNEL=stable)
RKE2_VERSION='v1.36.2+rke2r1'
KUBECONFIG_DST="${HOME}/.kube/config"
RKE2_BIN='/var/lib/rancher/rke2/bin'

require_linux() {
  [[ "$(uname -s)" == 'Linux' ]] || { echo 'This script is for Ubuntu/Linux only.' >&2; exit 1; }
}

write_config() {
  # Bring-your-own-ingress (parity with the k3s --disable=traefik intent). RKE2 ships Traefik in
  # current releases and ingress-nginx in older ones; list both — unknown entries are ignored.
  sudo mkdir -p /etc/rancher/rke2
  sudo tee /etc/rancher/rke2/config.yaml >/dev/null <<'EOF'
write-kubeconfig-mode: "0644"
disable:
  - rke2-traefik
  - rke2-ingress-nginx
EOF
}

install_rke2() {
  require_linux
  if systemctl is-active --quiet rke2-server 2>/dev/null; then
    echo 'rke2-server is already running. Nothing to do (uninstall first to reinstall).'
    return 0
  fi

  write_config

  echo "Installing RKE2 ${RKE2_VERSION} (containerd runtime, etcd datastore, bundled ingress-nginx disabled)..."
  curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${RKE2_VERSION}" sh -

  echo 'Enabling and starting rke2-server (first boot pulls images, can take several minutes)...'
  sudo systemctl enable --now rke2-server.service

  echo 'Waiting for kubeconfig...'
  sudo bash -c 'until [ -f /etc/rancher/rke2/rke2.yaml ]; do sleep 3; done'

  echo 'Waiting for node to be Ready...'
  sudo "${RKE2_BIN}/kubectl" --kubeconfig /etc/rancher/rke2/rke2.yaml \
    wait --for=condition=Ready nodes --all --timeout=300s

  echo "Writing kubeconfig to ${KUBECONFIG_DST}..."
  mkdir -p "$(dirname "${KUBECONFIG_DST}")"
  sudo cp /etc/rancher/rke2/rke2.yaml "${KUBECONFIG_DST}"
  sudo chown "$(id -u):$(id -g)" "${KUBECONFIG_DST}"
  chmod 600 "${KUBECONFIG_DST}"

  echo 'RKE2 install complete.'
  echo "Add RKE2 tools to PATH:  export PATH=\$PATH:${RKE2_BIN}"
  echo 'Then: kubectl get nodes'
}

uninstall_rke2() {
  require_linux
  if [[ -x /usr/local/bin/rke2-uninstall.sh ]]; then
    echo 'Uninstalling RKE2...'
    sudo /usr/local/bin/rke2-uninstall.sh
  else
    echo 'RKE2 not installed (no uninstall script found).'
  fi
  # drop the kubeconfig if it was ours
  if [[ -f "${KUBECONFIG_DST}" ]] && grep -q '127.0.0.1:6443' "${KUBECONFIG_DST}" 2>/dev/null; then
    rm -f "${KUBECONFIG_DST}"
    echo "Removed ${KUBECONFIG_DST}"
  fi
  echo 'RKE2 uninstall complete.'
}

status_rke2() {
  require_linux
  systemctl is-active rke2-server 2>/dev/null \
    && sudo "${RKE2_BIN}/kubectl" --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes 2>/dev/null \
    || echo 'rke2-server is not running.'
}

case "${1:-}" in
  install)   install_rke2 ;;
  uninstall) uninstall_rke2 ;;
  status)    status_rke2 ;;
  *) echo "usage: $0 {install|uninstall|status}" >&2; exit 1 ;;
esac
