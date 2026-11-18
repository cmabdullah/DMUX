#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[k3s-mac] failed at line ${LINENO}" >&2' ERR

K3S_VERSION='v1.36.2+k3s1'
K3D_IMAGE="rancher/k3s:${K3S_VERSION/+/-}"   # v1.36.2+k3s1 -> v1.36.2-k3s1
CLUSTER_NAME='localdev'

require_mac() {
  [[ "$(uname -s)" == 'Darwin' ]] || { echo 'This script is for macOS only.' >&2; exit 1; }
}

ensure_tools() {
  which brew   >/dev/null 2>&1 || { echo 'Homebrew is required: https://brew.sh' >&2; exit 1; }
  which docker >/dev/null 2>&1 || { echo 'A Docker engine (Docker Desktop or OrbStack) is required.' >&2; exit 1; }
  docker info  >/dev/null 2>&1 || { echo 'Docker engine is not running. Start Docker/OrbStack first.' >&2; exit 1; }
  which k3d     >/dev/null 2>&1 || { echo 'Installing k3d...';     brew install k3d; }
  which kubectl >/dev/null 2>&1 || { echo 'Installing kubectl...'; brew install kubectl; }
}

install_k3s() {
  require_mac
  ensure_tools

  if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}\b"; then
    echo "k3d cluster '${CLUSTER_NAME}' already exists. Nothing to do."
  else
    echo "Creating k3d cluster '${CLUSTER_NAME}' (${K3D_IMAGE}, Traefik disabled)..."
    k3d cluster create "${CLUSTER_NAME}" \
      --image "${K3D_IMAGE}" \
      --k3s-arg '--disable=traefik@server:0' \
      -p '80:80@loadbalancer' \
      -p '443:443@loadbalancer' \
      --wait
  fi

  echo 'Merging kubeconfig and switching context...'
  k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-switch-context >/dev/null

  kubectl wait --for=condition=Ready nodes --all --timeout=180s
  echo 'k3s (via k3d) install complete. Try: kubectl get nodes'
}

uninstall_k3s() {
  require_mac
  which k3d >/dev/null 2>&1 || { echo 'k3d not installed; nothing to uninstall.'; return 0; }
  if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}\b"; then
    echo "Deleting k3d cluster '${CLUSTER_NAME}'..."
    k3d cluster delete "${CLUSTER_NAME}"
  else
    echo "No k3d cluster named '${CLUSTER_NAME}'."
  fi
  echo 'k3s uninstall complete.'
}

status_k3s() {
  require_mac
  k3d cluster list 2>/dev/null || true
  kubectl get nodes 2>/dev/null || echo 'cluster not reachable.'
}

case "${1:-}" in
  install)   install_k3s ;;
  uninstall) uninstall_k3s ;;
  status)    status_k3s ;;
  *) echo "usage: $0 {install|uninstall|status}" >&2; exit 1 ;;
esac
