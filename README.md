# k3s & RKE2 Install / Uninstall Scripts — User Guide

Self-contained scripts that stand up and tear down a local Kubernetes cluster — **k3s** or
**RKE2** (both Rancher/SUSE distributions) — one script per OS. Each handles **install**,
**uninstall**, and **status** through a single subcommand.

| Script           | Distro | Runs on        | How it runs                                                 |
|------------------|--------|----------------|-------------------------------------------------------------|
| `k3s-ubuntu.sh`  | k3s    | Linux / Ubuntu | **Native** k3s (systemd service) via the official installer |
| `k3s-mac.sh`     | k3s    | macOS          | k3s **inside Docker** via k3d                               |
| `rke2-ubuntu.sh` | RKE2   | Linux / Ubuntu | **Native** RKE2 (`rke2-server` systemd service)             |
| `rke2-mac.sh`    | RKE2   | macOS          | RKE2 **inside a Lima Linux VM**                             |

All four share the same subcommand UX, the same safety header, and the same idempotency
guards. They disable the distro's bundled ingress controller (so you bring your own) and use
the **containerd** runtime.

### k3s vs RKE2 — which do I want?

|                 | **k3s**                     | **RKE2**                                    |
|-----------------|-----------------------------|---------------------------------------------|
| Focus           | Lightweight, edge/dev, fast | Security/compliance, production, government |
| Datastore       | SQLite (single binary)      | **etcd**                                    |
| Bundled ingress | Traefik                     | **ingress-nginx**                           |
| CNI             | Flannel                     | **Canal** (Calico + Flannel)                |
| Hardening       | minimal                     | **CIS / FIPS 140-2** focus                  |
| Footprint       | smaller                     | larger                                      |
| macOS story     | k3d (k3s-in-Docker)         | Lima VM (no RKE2-in-Docker exists)          |

> Rule of thumb: **k3s** for the lightest local dev loop; **RKE2** when you want to mirror a
> hardened, etcd-backed production cluster.

The sections below document **k3s** in depth (§1–§10), then **RKE2** (§11).

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

---

## 11. RKE2 (`rke2-ubuntu.sh`, `rke2-mac.sh`)

RKE2 is Rancher's **security-hardened, etcd-backed** Kubernetes distribution. These two scripts
mirror the k3s scripts' UX (`install | uninstall | status`, same safety header, same
idempotency) but target RKE2.

### 11.1 Quick start

```bash
# Linux / Ubuntu
./rke2-ubuntu.sh install
./rke2-ubuntu.sh status
./rke2-ubuntu.sh uninstall

# macOS (runs RKE2 in a Lima VM)
./rke2-mac.sh install
./rke2-mac.sh status
./rke2-mac.sh uninstall
```

> **Version pin:** both scripts default to `RKE2_VERSION='v1.36.2+rke2r1'`. RKE2 release tags
> do **not** always match k3s's — before a real install, confirm a published tag at
> <https://github.com/rancher/rke2/releases> and edit the constant (or switch to
> `INSTALL_RKE2_CHANNEL=stable`).

### 11.2 Prerequisites

- **Ubuntu:** systemd host, `sudo`, `curl`, outbound access to `get.rke2.io`.
- **macOS:** **Homebrew** (auto-installs `lima` + `kubectl`) and enough free RAM/disk for a VM
  (defaults: 4 CPU / 8 GB / 40 GB). No Docker needed — RKE2 runs inside the Lima VM.

### 11.3 How the Ubuntu RKE2 script works

```bash
# config written before install — bring-your-own-ingress
/etc/rancher/rke2/config.yaml:
  write-kubeconfig-mode: "0644"
  disable:
    - rke2-ingress-nginx

curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="v1.36.2+rke2r1" sh -
sudo systemctl enable --now rke2-server.service
```

Mechanism:

1. **Config first:** `config.yaml` is RKE2's control surface (the equivalent of k3s's
   `INSTALL_K3S_EXEC` flags). It sets a readable kubeconfig mode and disables the bundled
   **ingress-nginx** (parity with the k3s `--disable=traefik` intent).
2. **Installer:** `get.rke2.io` lays down the RKE2 binaries under `/var/lib/rancher/rke2/bin`
   and the `rke2-server.service` systemd unit. `INSTALL_RKE2_VERSION` pins the release.
3. **Start:** enabling `rke2-server` boots the control plane. **First boot pulls several images
   and can take minutes** (RKE2 runs its control-plane components as static pods, unlike k3s's
   single process) — so the readiness wait uses a **300s** timeout.
4. **Datastore:** **etcd** (not SQLite), managed by RKE2.
5. **Kubeconfig:** written to `/etc/rancher/rke2/rke2.yaml`; the script copies it to
   `~/.kube/config`, `chown`s it to you, and `chmod 600`s it. RKE2's own `kubectl` lives at
   `/var/lib/rancher/rke2/bin/kubectl` — add that dir to `PATH`, or use your own `kubectl`.
6. **Uninstall:** `sudo /usr/local/bin/rke2-uninstall.sh` (installer-generated) stops the
   service and removes binaries, `/etc/rancher/rke2`, and `/var/lib/rancher/rke2` — total and
   destructive. The script then drops `~/.kube/config` only if it pointed at this cluster.

### 11.4 How the macOS RKE2 script works (Lima)

RKE2 has **no k3d-equivalent** (no "RKE2-in-Docker"), so the Mac script runs it inside a
**Lima** Linux VM:

1. `ensure_tools` installs `lima` + `kubectl` via Homebrew if missing.
2. `limactl start --name=rke2 template://ubuntu-lts` boots an Ubuntu VM (4 CPU / 8 GB / 40 GB).
3. Inside the VM (`limactl shell rke2 ...`) it writes the same `config.yaml` and runs the same
   `get.rke2.io` installer + `systemctl enable --now rke2-server`.
4. It waits for the node to be `Ready`, then copies `/etc/rancher/rke2/rke2.yaml` out to
   `~/.kube/rke2-lima.yaml`. The kubeconfig server is `https://127.0.0.1:6443`, reachable from
   the host because **Lima auto-forwards** the VM's `6443` to host `127.0.0.1:6443`.
5. Use it with `export KUBECONFIG=~/.kube/rke2-lima.yaml`.
6. **Uninstall:** `limactl stop -f rke2 && limactl delete -f rke2` removes the whole VM (so no
   in-guest `rke2-uninstall.sh` needed), then deletes the exported kubeconfig.

> Unlike the k3s-mac script, this one does **not** map host ports 80/443 — it exposes only the
> API server via Lima's default forward. Add `portForwards` to the Lima config if you need
> ingress ports on the host.

### 11.5 k3s vs RKE2 script differences (at a glance)

|                          | k3s scripts                       | RKE2 scripts                           |
|--------------------------|-----------------------------------|----------------------------------------|
| Config surface           | CLI flags (`INSTALL_K3S_EXEC`)    | `/etc/rancher/rke2/config.yaml`        |
| Datastore                | SQLite                            | **etcd**                               |
| Bundled ingress disabled | Traefik                           | **ingress-nginx**                      |
| Service unit             | `k3s.service`                     | `rke2-server.service`                  |
| kubectl path             | symlinked from the k3s binary     | `/var/lib/rancher/rke2/bin/kubectl`    |
| Kubeconfig               | `/etc/rancher/k3s/k3s.yaml`       | `/etc/rancher/rke2/rke2.yaml`          |
| macOS mechanism          | k3d (Docker)                      | **Lima VM**                            |
| First-boot time          | seconds                           | **minutes** (static-pod control plane) |
| Uninstall                | `k3s-uninstall.sh` / `k3d delete` | `rke2-uninstall.sh` / `limactl delete` |

### 11.6 RKE2 troubleshooting

| Symptom                                      | Likely cause / fix                                                                                                          |
|----------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| Install fails pulling the version            | The pinned `RKE2_VERSION` tag doesn't exist — pick a real one from the releases page, or use `INSTALL_RKE2_CHANNEL=stable`. |
| Ubuntu: stuck "Waiting for node to be Ready" | Normal on first boot (image pulls); check `sudo journalctl -u rke2-server -f`.                                              |
| `kubectl: command not found` (Ubuntu)        | `export PATH=$PATH:/var/lib/rancher/rke2/bin`.                                                                              |
| macOS: `cluster not reachable`               | `limactl list` (is `rke2` Running?); `limactl shell rke2 sudo systemctl status rke2-server`.                                |
| macOS: port 6443 already in use              | Another cluster/kubeconfig owns it; stop it, or edit Lima's port forwards.                                                  |

Useful inspection:

```bash
# Ubuntu
sudo systemctl status rke2-server
sudo journalctl -u rke2-server -f
sudo /var/lib/rancher/rke2/bin/crictl ps     # containers via RKE2's containerd

# macOS
limactl list
limactl shell rke2 sudo systemctl status rke2-server
```

### 11.7 Customizing RKE2

- `RKE2_VERSION` — the release pin (both scripts).
- `config.yaml` (in the scripts) — add `cni:`, `tls-san:`, more `disable:` entries, CIS profile
  (`profile: cis`), etc. See <https://docs.rke2.io/install/configuration>.
- macOS `VM_NAME` and the `limactl start` resource flags (`--cpus/--memory/--disk`).

---

## 12. Verifying the cluster is running

### 12.1 Point `kubectl` at the right kubeconfig

Each script writes its kubeconfig to a different place:

| Script | Kubeconfig to use |
|---|---|
| `k3s-ubuntu.sh` | `~/.kube/config` (default — nothing to set) |
| `k3s-mac.sh` | `~/.kube/config`, context `k3d-localdev` (`kubectl config use-context k3d-localdev`) |
| `rke2-ubuntu.sh` | `~/.kube/config` (default) |
| `rke2-mac.sh` | `~/.kube/rke2-lima.yaml` → `export KUBECONFIG=~/.kube/rke2-lima.yaml` |

```bash
# RKE2 on macOS:
export KUBECONFIG=~/.kube/rke2-lima.yaml
```

> **Important — `rke2-mac.sh` uses a *separate* kubeconfig.** It writes
> `~/.kube/rke2-lima.yaml` (server `https://127.0.0.1:6443`) and does **not** merge into your
> default `~/.kube/config`, so it won't clobber other contexts (OrbStack, k3d, …). A plain
> `kubectl …` with no `KUBECONFIG` set therefore talks to whatever your *default* context is —
> **not** the RKE2 cluster.

**Three ways to run `kubectl` against the RKE2 cluster — pick one:**

```bash
# A) point this shell at it (add to ~/.zshrc to make it stick)
export KUBECONFIG=~/.kube/rke2-lima.yaml
kubectl get deployments

# B) the script's passthrough — no env needed
./rke2-mac.sh kubectl get deployments

# C) merge into the default config so plain `kubectl` sees it, then switch context
KUBECONFIG=~/.kube/config:~/.kube/rke2-lima.yaml kubectl config view --flatten > ~/.kube/config.new
mv ~/.kube/config.new ~/.kube/config
kubectl config use-context default     # RKE2's context is named "default"
```

> **Gotcha — `connection refused` on port `26443` (or any port ≠ `6443`).**
> That means `kubectl` is hitting the **wrong cluster** (e.g. OrbStack lives on `127.0.0.1:26443`),
> not RKE2. It is **not** an RKE2 failure — the ingress URL (`http://192.168.64.2/`) keeps working
> because Traefik serves on the node independently of your kubeconfig. Fix it with A, B, or C
> above. Check what you're pointed at with:
> ```bash
> kubectl config current-context
> kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
> ```
> RKE2's server must read `https://127.0.0.1:6443`.

### 12.2 The one-line health check

```bash
kubectl get nodes
```

Healthy — **`STATUS` must say `Ready`**:

```
NAME        STATUS   ROLES                AGE   VERSION
lima-rke2   Ready    control-plane,etcd   20m   v1.36.2+rke2r1
```

### 12.3 The script's built-in check

```bash
./rke2-mac.sh status      # or k3s-mac.sh / *-ubuntu.sh — runs limactl/systemctl + kubectl get nodes
```

### 12.4 Deeper checks

```bash
# All system pods up? (want Running / Completed — not CrashLoopBackOff or Pending)
kubectl get pods -A

# API server healthy? (prints "readyz check passed" at the end)
kubectl get --raw='/readyz?verbose'

# Control-plane endpoints + CoreDNS
kubectl cluster-info

# Is the backing VM/engine up?
limactl list          # RKE2-mac / (k3s-mac: `k3d cluster list` + `docker ps | grep k3d`)
```

### 12.5 Confirm RKE2 is configured as intended

```bash
# The applied config (disable list, kubeconfig mode, etc.)
limactl shell rke2 sudo cat /etc/rancher/rke2/config.yaml        # macOS
sudo cat /etc/rancher/rke2/config.yaml                            # Ubuntu

# Datastore is etcd (RKE2 default) and service is enabled + active
kubectl get pods -n kube-system -l component=etcd
limactl shell rke2 systemctl is-enabled rke2-server              # -> enabled
limactl shell rke2 systemctl is-active  rke2-server              # -> active
```

A properly-configured single node shows: **etcd** datastore, **Canal** CNI (`rke2-canal` 2/2),
**containerd** runtime, `rke2-server` enabled+active, and `/readyz` passing.

### 12.6 Prove it schedules workloads (the real test)

```bash
kubectl run test --image=nginx --restart=Never
kubectl get pod test -w        # wait for STATUS = Running (Ctrl-C to stop)
kubectl delete pod test        # clean up
```

### 12.7 Interpreting the result

| You see | Meaning |
|---|---|
| Node `Ready` + `get pods -A` all Running/Completed | ✅ cluster is healthy |
| Node `NotReady` | control-plane / CNI problem — check `kubectl get pods -A` |
| `kubectl` hangs or `connection refused` | VM/engine down or forward broken — `limactl list`, then `limactl start rke2` |
| `The connection to the server ... was refused` | wrong/empty `KUBECONFIG` — re-export it (§12.1) |
| `config.yaml` disables an add-on but it's still Running | disabling after first boot doesn't remove it — rebuild, or `kubectl delete` it |
