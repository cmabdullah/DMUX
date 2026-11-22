# How the Ansible secret-sync works — file by file

A detailed walkthrough of the two commands that populate the `panda-db-credentials`
Kubernetes Secret from OpenBao:

```bash
ansible-galaxy collection install -r panda-app/ansible/requirements.yml
ansible-playbook sync-secret.yaml -e bao_role_id="$BAO_ROLE_ID" -e bao_secret_id="$BAO_SECRET_ID"
```

The model is **push-at-deploy**: Ansible (on the runner) reads the secret from OpenBao into a
variable, then pushes a native K8s Secret into the cluster. Neither OpenBao nor the app contains
the other's logic — the runner is the only thing that talks to both.

---

## Part 1 — `ansible-galaxy collection install -r requirements.yml`

**Reads** `ansible/requirements.yml`:

```yaml
collections:
  - name: community.hashi_vault   # provides the OpenBao/Vault lookup plugin
  - name: kubernetes.core         # provides the k8s module
```

**Does:**

1. Downloads each collection from Ansible Galaxy.
2. Installs to `~/.ansible/collections/ansible_collections/<namespace>/<name>/`.
3. Makes two things usable by fully-qualified name:
   - `community.hashi_vault.vault_kv2_get` — a **lookup plugin** (runs in-process on the control
     node; returns data into a variable).
   - `kubernetes.core.k8s` — a **module** (performs an action: create/update a K8s object).

> These are Python wrappers: `community.hashi_vault` calls OpenBao's HTTP API via the **`hvac`**
> library; `kubernetes.core` calls the K8s API via the **`kubernetes`** library — hence both pip
> packages are prerequisites. The `ansible` pip package already bundles both collections, so this
> step is usually a no-op; it pins them explicitly for a clean Jenkins agent.

---

## Part 2 — `ansible-playbook sync-secret.yaml -e ...`

### Load/execution order

```
1. ansible.cfg          → settings (roles_path=./roles, yaml output)
2. group_vars/all.yaml  → bao_addr, kv_mount, secret_path, app_namespace, kubeconfig_path
3. -e extra-vars        → bao_role_id, bao_secret_id   (HIGHEST precedence)
4. sync-secret.yaml     → the play: run roles [secrets, k8s-secret] on localhost
5. roles/secrets/...    → READ from OpenBao  → facts
6. roles/k8s-secret/... → WRITE the K8s Secret
```

---

### File 1 — `ansible.cfg` (settings)

```ini
[defaults]
roles_path = ./roles                 # where `secrets` / `k8s-secret` roles live
host_key_checking = False
callback_result_format = yaml        # pretty output (replaces the removed stdout_callback=yaml)
retry_files_enabled = False
```

Loaded first (you run from the `ansible/` dir). Points Ansible at `./roles`.

---

### File 2 — `group_vars/all.yaml` (non-secret inputs, committable)

```yaml
bao_addr:        "{{ lookup('env','BAO_ADDR') | default('http://192.168.64.1:8200', true) }}"
kv_mount:        "secret"       # KV v2 mount
secret_path:     "panda/db"     # path within the mount
app_namespace:   "panda"
kubeconfig_path: "{{ lookup('env','KUBECONFIG') }}"   # which cluster to write to
```

Auto-loads for the `all` group (every host, incl. `localhost`). `bao_addr` and `kubeconfig_path`
are read from **environment variables** at runtime.

---

### The `-e` flags (secret inputs, NOT on disk)

```bash
-e bao_role_id="$BAO_ROLE_ID" -e bao_secret_id="$BAO_SECRET_ID"
```

Command-line **extra-vars** = Ansible's highest-precedence source. Kept off disk on purpose
(in CI these come from Jenkins credentials). Now in scope beside the group_vars.

**Variable precedence (low → high):** `group_vars/all.yaml` < role defaults < facts < **`-e` extra-vars**.

---

### File 3 — `sync-secret.yaml` (the play)

```yaml
- name: Sync panda-app DB credentials from OpenBao to Kubernetes
  hosts: localhost          # run on the control node itself...
  connection: local         # ...not over SSH
  gather_facts: true
  roles:
    - secrets               # ① read OpenBao  (produces facts)
    - k8s-secret            # ② write K8s     (consumes facts)
```

`localhost/local` because both the OpenBao HTTP call and the K8s API call are made *from* the
runner — there is no remote host to manage. Roles run **in order**.

---

### File 4 — `roles/secrets/tasks/main.yaml` (READ)

```yaml
- name: read DB creds from OpenBao (KV v2) using AppRole
  ansible.builtin.set_fact:
    panda_db: "{{ lookup('community.hashi_vault.vault_kv2_get',
                         secret_path,                 # 'panda/db'
                         engine_mount_point=kv_mount, # 'secret'
                         url=bao_addr,                # http://127.0.0.1:8200
                         auth_method='approle',
                         role_id=bao_role_id,         # from -e
                         secret_id=bao_secret_id) }}" # from -e
  no_log: true

- name: extract username/password
  ansible.builtin.set_fact:
    db_username: "{{ panda_db.secret.username }}"
    db_password: "{{ panda_db.secret.password }}"
  no_log: true
```

**Task 1** evaluates the `lookup(...)` on the control node. Under the hood the plugin makes
**two HTTP calls to OpenBao**:

```
POST  http://127.0.0.1:8200/v1/auth/approle/login   {role_id, secret_id}  → client_token
GET   http://127.0.0.1:8200/v1/secret/data/panda/db   (X-Vault-Token: client_token)
                               ↑ inserts 'data/' because it knows the mount is KV v2
```

The response is stored in fact `panda_db`; `panda_db.secret` = `{username: "panda", password: "panda"}`.

**Task 2** copies those into simple facts `db_username` / `db_password`.
`no_log: true` keeps the secret material out of task output.

---

### File 5 — `roles/k8s-secret/tasks/main.yaml` (WRITE)

```yaml
- name: ensure namespace exists
  kubernetes.core.k8s:
    kubeconfig: "{{ kubeconfig_path }}"
    definition:
      apiVersion: v1
      kind: Namespace
      metadata: { name: "{{ app_namespace }}" }

- name: create/update panda-db-credentials secret
  kubernetes.core.k8s:
    kubeconfig: "{{ kubeconfig_path }}"
    state: present
    definition:
      apiVersion: v1
      kind: Secret
      metadata: { name: panda-db-credentials, namespace: "{{ app_namespace }}" }
      type: Opaque
      data:
        SPRING_DATASOURCE_USERNAME: "{{ db_username | b64encode }}"
        SPRING_DATASOURCE_PASSWORD: "{{ db_password | b64encode }}"
  no_log: true
```

**Task 1** ensures the `panda` namespace exists (idempotent).
**Task 2** builds a `Secret`. K8s Secret `data` values must be **base64**, so `| b64encode`
turns `panda` → `cGFuZGE=`. The `kubernetes.core.k8s` module then uses the `kubernetes` Python
client + your `kubeconfig` to `POST/PATCH` the object to the API server (`state: present` =
create-or-update). First run → `changed`.

---

## Data transformation chain

```
OpenBao  secret/data/panda/db
   .data.data = {username: "panda", password: "panda"}
        │  vault_kv2_get lookup  (2 HTTP calls: login + read)
        ▼
   fact panda_db.secret = {username:"panda", password:"panda"}
        │  set_fact
        ▼
   db_username="panda"   db_password="panda"
        │  | b64encode
        ▼
   SPRING_DATASOURCE_USERNAME="cGFuZGE="   _PASSWORD="cGFuZGE="
        │  kubernetes.core.k8s → API server
        ▼
   K8s Secret  panda/panda-db-credentials     ← app reads via envFrom
```

---

## End-to-end sequence

```
ansible-playbook
  ├─ load ansible.cfg, group_vars/all.yaml, -e extra-vars
  ├─ PLAY localhost (connection: local)
  │   ├─ ROLE secrets
  │   │    task1: lookup vault_kv2_get ──HTTP──▶ OpenBao: login(approle) + read(kv2)  → fact panda_db
  │   │    task2: set_fact db_username / db_password
  │   └─ ROLE k8s-secret
  │        task1: k8s Namespace panda                    ──API──▶ RKE2
  │        task2: k8s Secret panda-db-credentials (b64)  ──API──▶ RKE2   [changed]
  └─ RECAP: ok=5 changed=2
```

---

## Two key ideas

1. **The lookup runs on the runner, not in the cluster.** Ansible pulls the secret into an
   in-memory variable, then pushes a K8s object out. OpenBao and Kubernetes are both *clients*
   of the runner; nothing in the cluster talks to OpenBao.
2. **Variable precedence enforces the security boundary.** Non-secret config lives in
   `group_vars` (safe to commit); `role_id`/`secret_id` arrive via `-e` (from Jenkins
   credentials) and never touch the repo. The DB password exists only transiently in the
   runner's memory and then as a K8s Secret — never in git or Terraform state.

---

## Gotchas (macOS runner)

- `export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` and `no_proxy='*'` — else the lookup worker
  crashes with "A worker was found in a dead state". Not needed on a Linux Jenkins agent.
- `callback_result_format = yaml` in `ansible.cfg` (the old `stdout_callback = yaml` was removed
  in newer Ansible and errors out).

See also: `../DEPLOY-COMMANDS.md` (full runbook) · `../REFACTOR-PLAN-V3-ANSIBLE-JENKINS.md` (design).
