# k3s Install / Uninstall Scripts — User Guide

Two self-contained scripts that stand up and tear down a local **k3s** Kubernetes cluster,
one per operating system. Each handles **install**, **uninstall**, and **status** through a
single subcommand.

| Script          | Runs on        | How k3s runs                                                |
|-----------------|----------------|-------------------------------------------------------------|
| `k3s-ubuntu.sh` | Linux / Ubuntu | **Native** k3s (systemd service) via the official installer |
| `k3s-mac.sh`    | macOS          | k3s **inside Docker** via k3d (k3s is Linux-only)           |

Both pin the same version (`v1.36.2+k3s1`), disable the bundled Traefik, and use k3s's
built-in containerd runtime.

---

## 1. Quick start

```bash
# Linux / Ubuntu
./k3s-ubuntu.sh install     # stand up the cluster
./k3s-ubuntu.sh status      # check it
./k3s-ubuntu.sh uninstall   # tear it down

# macOS
./k3s-mac.sh install        # Docker Desktop or OrbStack must be running
./k3s-mac.sh status
./k3s-mac.sh uninstall
```

After `install`, verify:

```bash
kubectl get nodes      # should show one Ready node
kubectl get pods -A    # CoreDNS, metrics-server, local-path-provisioner, etc.
```

---

## 2. Prerequisites

### Ubuntu (`k3s-ubuntu.sh`)

- A systemd-based Linux host (Ubuntu 20.04+).
- `sudo` rights (k3s installs a system service and writes to `/etc/rancher`, `/usr/local/bin`).
- `curl` and outbound internet access to `get.k3s.io`.

### macOS (`k3s-mac.sh`)

- A **running Docker engine** — Docker Desktop **or** OrbStack. (The script checks `docker info`.)
- **Homebrew** — used to auto-install `k3d` and `kubectl` if they're missing.
- Outbound internet to pull the `rancher/k3s` image and Homebrew formulae.

> **Why different approaches?** k3s needs a Linux kernel and cgroups, which macOS doesn't have.
> So on a Mac, k3s runs *inside a Linux container* managed by **k3d** (k3s-in-Docker). It's the
> real k3s binary — just containerized.

---

## 3. Command reference

Each script has the same three subcommands. Anything else prints usage and exits non-zero.

| Command     | Ubuntu                                                           | macOS                                                   |
|-------------|------------------------------------------------------------------|---------------------------------------------------------|
| `install`   | Runs the k3s installer, waits for Ready, writes `~/.kube/config` | Ensures tools, creates a k3d cluster, merges kubeconfig |
| `uninstall` | Runs `k3s-uninstall.sh`, removes our kubeconfig                  | Deletes the k3d cluster                                 |
| `status`    | `systemctl is-active k3s` + `kubectl get nodes`                  | `k3d cluster list` + `kubectl get nodes`                |

Both are **idempotent**: a second `install` is a no-op if the cluster already exists, and
`uninstall` exits cleanly even when nothing is installed.

---

## 4. How the Ubuntu script works (mechanism by mechanism)

### 4.1 The safety header

```bash
set -euo pipefail
trap 'echo "[k3s-ubuntu] failed at line ${LINENO}" >&2' ERR
```

- `set -e` → abort on the first command that fails (no silently-broken clusters).
- `set -u` → abort if an undefined variable is used (catches typos).
- `set -o pipefail` → a pipeline fails if *any* stage fails, not just the last.
- `trap ... ERR` → prints the exact line number when something aborts, so failures are debuggable.

### 4.2 `install` — what actually happens

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.36.2+k3s1" \
  INSTALL_K3S_EXEC='--disable=traefik --write-kubeconfig-mode=644' \
  sh -
```

This pipes the **official k3s install script** into `sh`, controlled by two env vars:

- `INSTALL_K3S_VERSION` — pins the exact k3s release (reproducible installs).
- `INSTALL_K3S_EXEC` — flags passed to the k3s server:
    - `--disable=traefik` → skip k3s's bundled Traefik ingress (you bring your own).
    - `--write-kubeconfig-mode=644` → make the generated kubeconfig world-readable so a
      non-root user can read it.

**Under the hood, the installer:**

1. Downloads the single `k3s` binary → `/usr/local/bin/k3s` (kubectl/crictl/ctr are symlinks to it).
2. Writes and enables a **systemd unit** `k3s.service`, then starts it.
3. On first boot k3s generates its CA/PKI, creates a **SQLite** datastore (not etcd), starts
   the apiserver/scheduler/controller-manager/kubelet **all in one process**, and launches
   bundled CoreDNS, metrics-server, and local-path-provisioner.
4. Writes the cluster kubeconfig to `/etc/rancher/k3s/k3s.yaml` (server `https://127.0.0.1:6443`).

Then the script waits for readiness and publishes the kubeconfig to your user:

```bash
sudo k3s kubectl wait --for=condition=Ready nodes --all --timeout=180s
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config
```

- `kubectl wait` blocks until the node reports `Ready` (or times out at 180s) — a deterministic
  readiness gate instead of a guess-and-sleep loop.
- Copying to `~/.kube/config` + `chown` to you means plain `kubectl` works without `sudo`.
- `chmod 600` locks the kubeconfig (it contains cluster admin credentials) to your user.

The idempotency guard at the top skips all of this if the service is already up:

```bash
if systemctl is-active --quiet k3s 2>/dev/null; then ... return 0; fi
```

### 4.3 `uninstall` — what actually happens

```bash
sudo /usr/local/bin/k3s-uninstall.sh
```

The k3s installer *generates* this uninstall script at install time. It:

1. Stops and disables the `k3s` systemd service.
2. Kills remaining containerd/pod processes and unmounts their filesystems.
3. Removes the binary, the systemd unit, `/etc/rancher/k3s`, and `/var/lib/rancher/k3s`
   (all cluster data — **this is destructive and total**).

The script then removes `~/.kube/config` **only if** it points at this local cluster
(`grep -q '127.0.0.1:6443'`), so it won't delete a kubeconfig pointing at some other cluster.

### 4.4 `status`

```bash
systemctl is-active k3s && kubectl get nodes || echo 'k3s is not running.'
```

Reports the systemd service state and the node list, or a friendly "not running" message.

---

## 5. How the macOS script works (mechanism by mechanism)

### 5.1 `ensure_tools` — preflight

```bash
which brew   ... || exit            # Homebrew required
which docker ... || exit            # a Docker engine must exist
docker info  ... || exit            # ...and be running
which k3d     ... || brew install k3d
which kubectl ... || brew install kubectl
```

- Fails fast with a clear message if Homebrew or Docker is missing / not running.
- Auto-installs `k3d` and `kubectl` via Homebrew if they aren't on `PATH`.
- `docker info` is the real "is the engine up?" check (OrbStack and Docker Desktop both answer it).

### 5.2 The version → image mapping

```bash
K3S_VERSION='v1.36.2+k3s1'
K3D_IMAGE="rancher/k3s:${K3S_VERSION/+/-}"   # -> rancher/k3s:v1.36.2-k3s1
```

k3s *releases* use a `+` (`v1.36.2+k3s1`), but Docker image *tags* can't contain `+`, so the
upstream image uses `-` instead. `${K3S_VERSION/+/-}` does that one-character substitution so
the same pin drives both scripts.

### 5.3 `install` — what actually happens

```bash
k3d cluster create localdev \
  --image "rancher/k3s:v1.36.2-k3s1" \
  --k3s-arg '--disable=traefik@server:0' \
  -p '80:80@loadbalancer' \
  -p '443:443@loadbalancer' \
  --wait
```

**k3d** ("k3s in docker") creates:

1. A Docker container running the real `k3s server` (your control plane + worker node).
2. A small **load-balancer container** (based on nginx) in front of it.
3. A dedicated Docker network for the cluster.

The flags:

- `--image` → pins the exact k3s version (same release as Ubuntu).
- `--k3s-arg '--disable=traefik@server:0'` → passes `--disable=traefik` to the server node
  (`@server:0` = "the first server"). Same intent as the Ubuntu `--disable=traefik`.
- `-p '80:80@loadbalancer'` / `-p '443:443@loadbalancer'` → map your **Mac's** ports 80/443 to
  the k3d load balancer, so `http(s)://localhost` reaches Services inside the cluster. This is
  the macOS equivalent of the host network a native Linux node already has.
- `--wait` → k3d blocks until the server is up before returning.

Then:

```bash
k3d kubeconfig merge localdev --kubeconfig-switch-context
kubectl wait --for=condition=Ready nodes --all --timeout=180s
```

- `kubeconfig merge ... --kubeconfig-switch-context` folds the new cluster into your existing
  `~/.kube/config` and sets it as the current context — so `kubectl` targets it immediately
  without clobbering your other contexts.
- `kubectl wait` gates on the node reporting `Ready`.

The idempotency guard skips creation if the cluster name already exists:

```bash
if k3d cluster list | grep -q "^localdev\b"; then ... ; else k3d cluster create ...; fi
```

### 5.4 `uninstall` — what actually happens

```bash
k3d cluster delete localdev
```

k3d removes the server container, the load-balancer container, the cluster's Docker network and
volumes, and strips the cluster's entry from `~/.kube/config`. Clean and total — no leftover
system services (everything lived in Docker). The guard above makes it safe to run when there's
nothing to delete.

### 5.5 `status`

```bash
k3d cluster list || true
kubectl get nodes || echo 'cluster not reachable.'
```

---

## 6. Ubuntu vs. macOS — mechanism comparison

| Aspect            | Ubuntu (native)                                | macOS (k3d)                                |
|-------------------|------------------------------------------------|--------------------------------------------|
| Where k3s runs    | Directly on the host, as a **systemd service** | Inside a **Docker container**              |
| Lifecycle tool    | Official `get.k3s.io` installer                | `k3d` CLI                                  |
| Datastore         | SQLite at `/var/lib/rancher/k3s`               | SQLite inside the container                |
| Container runtime | k3s embedded **containerd**                    | k3s embedded containerd (nested in Docker) |
| Host ports 80/443 | Native (node has host networking)              | Mapped via `-p ...@loadbalancer`           |
| Needs Docker?     | **No**                                         | **Yes**                                    |
| Needs sudo?       | **Yes** (system service)                       | No (runs in Docker)                        |
| Uninstall         | `k3s-uninstall.sh` (removes service + data)    | `k3d cluster delete` (removes containers)  |

---

## 7. What you get after install (both platforms)

A single-node, fully-conformant Kubernetes cluster with k3s's bundled components:

- **CoreDNS** — in-cluster DNS.
- **metrics-server** — `kubectl top` support.
- **local-path-provisioner** — the default `local-path` StorageClass for PVCs.
- **Flannel** — pod networking (CNI).
- **Klipper ServiceLB** — `LoadBalancer`-type Services without a cloud.
- **Traefik is intentionally NOT installed** (both scripts disable it).

---

## 8. Troubleshooting

| Symptom                                                 | Likely cause / fix                                                                            |
|---------------------------------------------------------|-----------------------------------------------------------------------------------------------|
| `This script is for macOS/Linux only.`                  | You ran the wrong script for your OS.                                                         |
| macOS: `Docker engine is not running`                   | Start Docker Desktop or OrbStack, then retry.                                                 |
| macOS: `Homebrew is required`                           | Install from https://brew.sh (or install `k3d`/`kubectl` manually).                           |
| Ubuntu: install hangs at "Waiting for node to be Ready" | Check `journalctl -u k3s -f` for apiserver/kubelet errors.                                    |
| `kubectl` points at the wrong cluster                   | Ubuntu: `export KUBECONFIG=~/.kube/config`. macOS: `kubectl config use-context k3d-localdev`. |
| Port 80/443 already in use (macOS)                      | Another service owns the port; stop it, or edit the `-p` mappings in the script.              |
| Re-install does nothing                                 | By design — it's idempotent. `uninstall` first, then `install`.                               |
| Failure with a line number (`failed at line N`)         | The `trap` printed where it broke; open the script at that line.                              |

Useful inspection commands:

```bash
# Ubuntu
sudo systemctl status k3s
sudo journalctl -u k3s -f
sudo k3s crictl ps              # containers via k3s's containerd

# macOS
k3d cluster list
docker ps | grep k3d            # the k3d containers
kubectl config get-contexts
```

---

## 9. Customizing

Edit the constants at the top of each script:

- `K3S_VERSION` — bump to change the k3s release (update it in **both** scripts).
- macOS `CLUSTER_NAME` — the k3d cluster name (default `localdev`).
- macOS port maps — change `-p '80:80@loadbalancer'` / `443` if those host ports are taken.
- Ubuntu `INSTALL_K3S_EXEC` — add server flags (e.g. keep Traefik by removing `--disable=traefik`,
  or add `--disable=servicelb`, `--node-name`, etc.).

---

## 10. Safety notes

- `uninstall` is **destructive and irreversible** — it deletes the cluster and all its data
  (PVCs, workloads). There is no confirmation prompt.
- The kubeconfig holds **cluster-admin credentials**. The Ubuntu script `chmod 600`s it;
  don't commit it or share it.
- These scripts are standalone and do not integrate with any build system.
