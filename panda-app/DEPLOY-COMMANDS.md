# panda-app v3 — deploy commands (Ansible push-at-deploy)

The exact command sequence used to deploy `panda-app` on RKE2: **Ansible reads the DB creds
from OpenBao → writes a K8s Secret → image import → `kubectl apply` → test.** Verified
2026-11-23 on a freshly reinstalled cluster.

> Jenkins runs these same steps later (see `Jenkinsfile`). This is the manual/local runbook.

---

## 0. Prerequisites (one-time on the runner)

```bash
# OpenBao + Postgres run on the host and are up; RKE2 (Lima VM) is up.
# kubeconfig written by rke2-mac.sh:
export KUBECONFIG="$HOME/.kube/rke2-lima.yaml"

# Ansible + python deps (collections community.hashi_vault, kubernetes.core are bundled with ansible):
python3 -m venv ansible-venv
./ansible-venv/bin/pip install ansible hvac kubernetes
./ansible-venv/bin/ansible-galaxy collection install -r panda-app/ansible/requirements.yml
```

AppRole credentials for OpenBao (kept out of git — in `panda-app/deploy/APPROLE.local.md`):

```bash
export BAO_ROLE_ID=<role_id>        # from APPROLE.local.md (or Jenkins credential)
export BAO_SECRET_ID=<secret_id>    # from APPROLE.local.md (or Jenkins credential)
export BAO_ADDR=http://127.0.0.1:8200   # host-local; 192.168.64.1:8200 from inside the cluster
```

---

## 1. Confirm the cluster node is Ready

```bash
./rke2-mac.sh kubectl get nodes
# NAME        STATUS   ROLES                 AGE   VERSION
# lima-rke2   Ready    control-plane,etcd    4m    v1.36.2+rke2r1
```

---

## 2. Run the Ansible playbook — OpenBao → K8s Secret

Creates the `panda` namespace and the `panda-db-credentials` Secret.

```bash
cd panda-app/ansible

# macOS only: avoid the "worker in a dead state" fork-safety crash
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
export no_proxy='*'

ansible-playbook sync-secret.yaml \
  -e bao_role_id="$BAO_ROLE_ID" \
  -e bao_secret_id="$BAO_SECRET_ID"
cd ../..
```

Expected recap: `ok=5 changed=2` — tasks: read OpenBao → extract → ensure namespace → create secret.

**Verify the secret:**

```bash
./rke2-mac.sh kubectl -n panda get secret panda-db-credentials \
  -o jsonpath='{.data}' | python3 -c \
  "import json,sys,base64;d=json.load(sys.stdin);print({k:base64.b64decode(v).decode() for k,v in d.items()})"
# {'SPRING_DATASOURCE_PASSWORD': 'panda', 'SPRING_DATASOURCE_USERNAME': 'panda'}
```

---

## 3. Make the image available to RKE2 containerd

Only needed when the image isn't already in the node (e.g. after a cluster reinstall).

```bash
# build (if not built)
docker build -t panda-app:0.3.0 panda-app

# import into the Lima VM's RKE2 containerd (no registry)
docker save panda-app:0.3.0 | limactl shell rke2 sudo \
  /var/lib/rancher/rke2/bin/ctr -a /run/k3s/containerd/containerd.sock -n k8s.io images import -

# verify
limactl shell rke2 sudo /var/lib/rancher/rke2/bin/ctr \
  -a /run/k3s/containerd/containerd.sock -n k8s.io images ls | grep panda-app:0.3.0
```

---

## 4. Apply the manifests

```bash
./rke2-mac.sh kubectl apply -f panda-app/deploy/
# namespace/panda configured
# secret/openbao-approle created        <- stale (v2); unused by v3, harmless
# deployment.apps/panda-app created
# service/panda-app created
# middleware.traefik.io/panda-stripprefix created
# ingress.networking.k8s.io/panda-app created

./rke2-mac.sh kubectl -n panda rollout status deploy/panda-app --timeout=120s
```

---

## 5. Test

```bash
# node IP (vmnet)
NODE_IP=$(./rke2-mac.sh kubectl get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')   # 192.168.64.2

# via Traefik ingress (path /panda, no Host header)
curl -s http://$NODE_IP/panda
# {"message":"Hello, World","database":"connected","db_name":"panda","db_user_source":"openbao:secret/panda/db"}

# pod status
./rke2-mac.sh kubectl -n panda get pods -l app=panda-app

# confirm the app is Vault-unaware: SPRING_DATASOURCE_* present, no BAO_* env
./rke2-mac.sh kubectl -n panda exec deploy/panda-app -- printenv | grep -E 'SPRING_DATASOURCE|BAO_|DB_' | sort
```

---

## Notes / gotchas learned

- **macOS Ansible:** set `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` (and `no_proxy='*'`), or the
  playbook dies with "A worker was found in a dead state". Not needed on a Linux Jenkins agent.
- **`ansible.cfg`:** uses `callback_result_format = yaml` (the old `stdout_callback = yaml` was
  removed in newer Ansible and errors out).
- **kubeconfig:** `./rke2-mac.sh kubectl ...` uses `~/.kube/rke2-lima.yaml`; the default kube
  context (`:26443`) is stale — always go through the script or set `KUBECONFIG`.
- **After a cluster reinstall:** containerd is empty → re-import the image (step 3) or you'll get
  `ImagePullBackOff`.
- **OpenBao role drift:** the `panda-app` AppRole role must have `token_policies=panda-app`
  (a prior edit had pointed it at a non-existent `panda-app-v2`, causing `permission denied`).
- **Stale file:** `deploy/15-openbao-approle.yaml` is from the v2 (pull) design and is unused by
  v3; it just creates an unreferenced `openbao-approle` Secret.

---

## One-shot (all steps)

```bash
export KUBECONFIG="$HOME/.kube/rke2-lima.yaml"
export BAO_ADDR=http://127.0.0.1:8200
export BAO_ROLE_ID=<role_id> BAO_SECRET_ID=<secret_id>
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES no_proxy='*'

( cd panda-app/ansible && ansible-playbook sync-secret.yaml \
    -e bao_role_id="$BAO_ROLE_ID" -e bao_secret_id="$BAO_SECRET_ID" )

docker save panda-app:0.3.0 | limactl shell rke2 sudo \
  /var/lib/rancher/rke2/bin/ctr -a /run/k3s/containerd/containerd.sock -n k8s.io images import -

./rke2-mac.sh kubectl apply -f panda-app/deploy/
./rke2-mac.sh kubectl -n panda rollout status deploy/panda-app --timeout=120s
curl -s http://192.168.64.2/panda ; echo
```

See also: `REFACTOR-PLAN-V3-ANSIBLE-JENKINS.md` (design) · `Jenkinsfile` (CI version).
