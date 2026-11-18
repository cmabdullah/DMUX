#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[k3s-ubuntu] failed at line ${LINENO}" >&2' ERR

K3S_VERSION='v1.36.2+k3s1'
KUBECONFIG_DST="${HOME}/.kube/config"

require_linux() {
  [[ "$(uname -s)" == 'Linux' ]] || { echo 'This script is for Ubuntu/Linux only.' >&2; exit 1; }
}

install_k3s() {
  require_linux
  if systemctl is-active --quiet k3s 2>/dev/null; then
    echo 'k3s is already running. Nothing to do (uninstall first to reinstall).'
    return 0
  fi

  echo "Installing k3s ${K3S_VERSION} (containerd runtime, Traefik disabled)..."
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_EXEC='--disable=traefik --write-kubeconfig-mode=644' \
    sh -

  echo 'Waiting for node to be Ready...'
  sudo k3s kubectl wait --for=condition=Ready nodes --all --timeout=180s

  echo "Writing kubeconfig to ${KUBECONFIG_DST}..."
  mkdir -p "$(dirname "${KUBECONFIG_DST}")"
  sudo cp /etc/rancher/k3s/k3s.yaml "${KUBECONFIG_DST}"
  sudo chown "$(id -u):$(id -g)" "${KUBECONFIG_DST}"
  chmod 600 "${KUBECONFIG_DST}"

  echo 'k3s install complete. Try: kubectl get nodes'
}

uninstall_k3s() {
  require_linux
  if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    echo 'Uninstalling k3s...'
    sudo /usr/local/bin/k3s-uninstall.sh
  else
    echo 'k3s not installed (no uninstall script found).'
  fi
  # drop the kubeconfig if it was ours
  if [[ -f "${KUBECONFIG_DST}" ]] && grep -q '127.0.0.1:6443' "${KUBECONFIG_DST}" 2>/dev/null; then
    rm -f "${KUBECONFIG_DST}"
    echo "Removed ${KUBECONFIG_DST}"
  fi
  echo 'k3s uninstall complete.'
}

status_k3s() {
  require_linux
  systemctl is-active k3s 2>/dev/null && kubectl get nodes 2>/dev/null || echo 'k3s is not running.'
}

case "${1:-}" in
  install)   install_k3s ;;
  uninstall) uninstall_k3s ;;
  status)    status_k3s ;;
  *) echo "usage: $0 {install|uninstall|status}" >&2; exit 1 ;;
esac
