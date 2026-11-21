# OpenBao — AppRole Setup (step by step) & API Endpoint Reference

**Date:** 2026-11-21
**Instance:** host OpenBao `http://127.0.0.1:8200` (v2.7.3), reached from the RKE2 cluster
at `http://192.168.64.1:8200`.

> **Security:** real `role_id`, `secret_id`, tokens, and unseal keys are **not** in this
> file. Examples use `<PLACEHOLDER>` / sample UUIDs. Live credentials live in gitignored
> files (`openbao/CREDENTIALS.local.md`, `panda-app/deploy/APPROLE.local.md`).

---

## Shared setup for the commands below

Every step shows **two equivalent forms**: the `bao` CLI and a complete `curl`.

```bash
# --- common env ---
export BAO_ADDR=http://127.0.0.1:8200          # host OpenBao
export VAULT_TOKEN=<root-token>                # setup only; from CREDENTIALS.local.md
# OpenBao's HTTP header is X-Vault-Token (Vault-compatible API).

# The CLI runs inside the container on this host:
R() { docker exec -e BAO_ADDR=$BAO_ADDR -e BAO_TOKEN=$VAULT_TOKEN openbao "$@"; }
# curl runs straight from the host against :8200.
```

> **Write semantics:** OpenBao accepts `POST` **or** `PUT` for writes. `LIST` is a real verb
> (or `GET ...?list=true`). Reads are `GET`. All bodies are JSON.

---

## Part A — AppRole, step by step

AppRole has **four** distinct concepts:

| Concept       | Analogy                | Created when                    | Mutable?              | Secret?             |
|---------------|------------------------|---------------------------------|-----------------------|---------------------|
| **role**      | the account definition | you *write* the role            | only if rewritten     | no                  |
| **role_id**   | username               | auto, with the role             | stable                | low (useless alone) |
| **secret_id** | password               | each *write* to `.../secret-id` | new every call        | **yes**             |
| **token**     | session cookie         | at *login*                      | expires (`token_ttl`) | **yes**             |

---

### Step 0a — Enable the AppRole auth method

**CLI**

```bash
R bao auth enable approle
```

**curl**

```bash
curl -sS -X POST \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -d '{"type":"approle"}' \
  "$BAO_ADDR/v1/sys/auth/approle"
```

- Endpoint: `POST /v1/sys/auth/approle`  → `204 No Content`
- Mounts the method at `auth/approle/`. (Re-enabling an existing path returns `400 path is already in use`.)

### Step 0b — Write the policy the role will grant

**CLI**

```bash
printf 'path "secret/data/panda/db" { capabilities = ["read"] }\n' \
  | docker exec -i -e BAO_ADDR=$BAO_ADDR -e BAO_TOKEN=$VAULT_TOKEN \
      openbao bao policy write panda-app -
```

**curl** (policy is a JSON string field — note the escaped quotes)

```bash
curl -sS -X PUT \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -d '{"policy":"path \"secret/data/panda/db\" { capabilities = [\"read\"] }"}' \
  "$BAO_ADDR/v1/sys/policies/acl/panda-app"
```

- Endpoint: `PUT /v1/sys/policies/acl/panda-app` → `204 No Content`
- `secret/data/...` — KV **v2** stores values under `data/`, so ACL paths must include it.

**Verify (curl):**

```bash
curl -sS -H "X-Vault-Token: $VAULT_TOKEN" "$BAO_ADDR/v1/sys/policies/acl/panda-app"
# {"data":{"name":"panda-app","policy":"path \"secret/data/panda/db\" { capabilities = [\"read\"] }\n", ...}}
```

---

### Step 1 — Create the role

**CLI**

```bash
R bao write auth/approle/role/panda-app \
  token_policies=panda-app token_ttl=1h token_max_ttl=4h
```

**curl**

```bash
curl -sS -X POST \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -d '{"token_policies":"panda-app","token_ttl":"1h","token_max_ttl":"4h"}' \
  "$BAO_ADDR/v1/auth/approle/role/panda-app"
```

- Endpoint: `POST /v1/auth/approle/role/panda-app` → `204 No Content`
- Creates the role and **auto-generates its role_id**. Tokens minted via this role carry the
  `panda-app` policy, TTL 1h (max 4h).

Key parameters:

| Param                                         | Meaning                     | Value here     | Prod suggestion |
|-----------------------------------------------|-----------------------------|----------------|-----------------|
| `token_policies`                              | policies on the login token | `panda-app`    | least-privilege |
| `token_ttl` / `token_max_ttl`                 | token lifetime / cap        | 1h / 4h        | short           |
| `secret_id_ttl`                               | secret_id validity          | `0` (never) ⚠️ | e.g. `24h`      |
| `secret_id_num_uses`                          | logins per secret_id        | `0` (∞) ⚠️     | `1` single-use  |
| `token_num_uses`                              | uses per token              | `0` (∞)        | limit           |
| `secret_id_bound_cidrs` / `token_bound_cidrs` | restrict by source IP       | —              | cluster subnet  |

---

### Step 2 — Inspect the role (optional)

**CLI**

```bash
R bao read auth/approle/role/panda-app
```

**curl**

```bash
curl -sS -H "X-Vault-Token: $VAULT_TOKEN" \
  "$BAO_ADDR/v1/auth/approle/role/panda-app"
```

- Endpoint: `GET /v1/auth/approle/role/panda-app`
- Response (abridged): `{"data":{"token_policies":["panda-app"],"token_ttl":3600,"secret_id_ttl":0,...}}`

---

### Step 3 — Read the role_id (stable)

**CLI**

```bash
R bao read auth/approle/role/panda-app/role-id
```

**curl**

```bash
curl -sS -H "X-Vault-Token: $VAULT_TOKEN" \
  "$BAO_ADDR/v1/auth/approle/role/panda-app/role-id"
```

- Endpoint: `GET /v1/auth/approle/role/panda-app/role-id`
- **Real response** from this instance:
  ```json
  { "data": { "role_id": "8284877b-8686-06f8-a13d-a150bfa64291" } }
  ```
- Idempotent — reading never changes it. Extract just the value with:
  ```bash
  curl -sS -H "X-Vault-Token: $VAULT_TOKEN" \
    "$BAO_ADDR/v1/auth/approle/role/panda-app/role-id" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['role_id'])"
  ```

---

### Step 4 — Generate a secret_id (the credential)

**CLI**

```bash
R bao write -f auth/approle/role/panda-app/secret-id
```

**curl** (empty JSON body)

```bash
curl -sS -X POST \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -d '{}' \
  "$BAO_ADDR/v1/auth/approle/role/panda-app/secret-id"
```

- Endpoint: `POST /v1/auth/approle/role/panda-app/secret-id`
- Response:
  ```json
  { "data": { "secret_id": "2d43044c-...", "secret_id_accessor": "7294dad0-...",
              "secret_id_ttl": 0, "secret_id_num_uses": 0 } }
  ```
- **Every call mints a NEW secret_id** → this is how you rotate.
- Response-wrapped (prod — raw secret_id never in plaintext): add the wrap header:
  ```bash
  curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -H "X-Vault-Wrap-TTL: 120s" \
    -d '{}' "$BAO_ADDR/v1/auth/approle/role/panda-app/secret-id"
  # -> {"wrap_info":{"token":"<unwrap-token>","ttl":120,...}}   (app unwraps it once)
  ```
- Revoke a specific secret_id by its accessor (no value needed):
  ```bash
  curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
    -d '{"secret_id_accessor":"<ACCESSOR>"}' \
    "$BAO_ADDR/v1/auth/approle/role/panda-app/secret-id-accessor/destroy"
  ```

---

### Step 5 — Login (role_id + secret_id → token)

**CLI**

```bash
R bao write auth/approle/login role_id=<ROLE_ID> secret_id=<SECRET_ID>
```

**curl** (NO token header — this is how you *get* a token)

```bash
curl -sS -X POST \
  -d '{"role_id":"<ROLE_ID>","secret_id":"<SECRET_ID>"}' \
  "$BAO_ADDR/v1/auth/approle/login"
```

- Endpoint: `POST /v1/auth/approle/login`
- **Real response** (token/accessor redacted):
  ```json
  { "auth": {
      "client_token": "<REDACTED>",
      "accessor": "<REDACTED>",
      "token_policies": ["default","panda-app"],
      "lease_duration": 3600,
      "renewable": true,
      "metadata": { "role_name": "panda-app" } } }
  ```
- Capture the token for the next call:
  ```bash
  APP_TOKEN=$(curl -sS -X POST \
    -d '{"role_id":"<ROLE_ID>","secret_id":"<SECRET_ID>"}' \
    "$BAO_ADDR/v1/auth/approle/login" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")
  ```

---

### Step 6 — Use the token to read the secret

**CLI**

```bash
BAO_TOKEN=$APP_TOKEN R bao kv get secret/panda/db
```

**curl** (use the AppRole token, not root)

```bash
curl -sS -H "X-Vault-Token: $APP_TOKEN" \
  "$BAO_ADDR/v1/secret/data/panda/db"
```

- Endpoint: `GET /v1/secret/data/panda/db`  (the `data/` segment = KV **v2**)
- **Real response** — values nested at `.data.data`:
  ```json
  { "data": {
      "data": { "password": "panda", "username": "panda" },
      "metadata": { "version": 1, "created_time": "2026-11-21T05:01:33Z", "destroyed": false } } }
  ```
- Extract one field:
  ```bash
  curl -sS -H "X-Vault-Token: $APP_TOKEN" "$BAO_ADDR/v1/secret/data/panda/db" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['data']['password'])"
  ```

> In production Steps 5–6 (+ token renewal) are done automatically by **Spring Cloud Vault**
> using `BAO_ROLE_ID` / `BAO_SECRET_ID` from the `openbao-approle` Kubernetes Secret.

---

### Lifecycle — rotate a secret_id (complete)

```bash
# 1. mint a new secret_id (curl)
NEW=$(curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{}' \
  "$BAO_ADDR/v1/auth/approle/role/panda-app/secret-id" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['secret_id'])")

# 2. update the K8s Secret
./rke2-mac.sh kubectl -n panda create secret generic openbao-approle \
  --from-literal=role-id=<ROLE_ID> --from-literal=secret-id="$NEW" \
  --dry-run=client -o yaml | ./rke2-mac.sh kubectl apply -f -

# 3. restart the app to pick it up
./rke2-mac.sh kubectl -n panda rollout restart deploy/panda-app

# 4. (optional) destroy the old secret_id by accessor
curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" \
  -d '{"secret_id_accessor":"<OLD_ACCESSOR>"}' \
  "$BAO_ADDR/v1/auth/approle/role/panda-app/secret-id-accessor/destroy"
```

---

## Part B — OpenBao API endpoint reference (with curl)

All under `/v1/...`. Three families: **system** (`sys/*`), **auth** (`auth/<method>/*`),
**secrets engines** (`<mount>/*`).

### Live state on this instance

```
Secrets engines: cubbyhole/  identity/  kubernetes/  secret/(kv v2)  sys/
Auth methods:    approle/    token/
Policies:        default  panda-app  root
```

### B.1 System endpoints (`/v1/sys/*`)

| Endpoint                        | Method         | Use case                       | curl                                                                                                                                                  |
|---------------------------------|----------------|--------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| `/v1/sys/health`                | GET            | health (init/sealed/active)    | `curl -sS $BAO_ADDR/v1/sys/health`                                                                                                                    |
| `/v1/sys/seal-status`           | GET            | seal state / unseal progress   | `curl -sS $BAO_ADDR/v1/sys/seal-status`                                                                                                               |
| `/v1/sys/init`                  | PUT            | initialize                     | `curl -sS -X PUT -d '{"secret_shares":5,"secret_threshold":3}' $BAO_ADDR/v1/sys/init`                                                                 |
| `/v1/sys/unseal`                | PUT            | submit unseal key (×threshold) | `curl -sS -X PUT -d '{"key":"<unseal-key>"}' $BAO_ADDR/v1/sys/unseal`                                                                                 |
| `/v1/sys/mounts`                | GET            | list secrets engines           | `curl -sS -H "X-Vault-Token: $VAULT_TOKEN" $BAO_ADDR/v1/sys/mounts`                                                                                   |
| `/v1/sys/mounts/<path>`         | POST           | enable engine                  | `curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{"type":"kv","options":{"version":"2"}}' $BAO_ADDR/v1/sys/mounts/secret`                       |
| `/v1/sys/auth`                  | GET            | list auth methods              | `curl -sS -H "X-Vault-Token: $VAULT_TOKEN" $BAO_ADDR/v1/sys/auth`                                                                                     |
| `/v1/sys/auth/<path>`           | POST           | enable auth method             | `curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{"type":"approle"}' $BAO_ADDR/v1/sys/auth/approle`                                             |
| `/v1/sys/policies/acl`          | LIST           | list policies                  | `curl -sS -H "X-Vault-Token: $VAULT_TOKEN" -X LIST $BAO_ADDR/v1/sys/policies/acl`                                                                     |
| `/v1/sys/policies/acl/<name>`   | GET/PUT/DELETE | read/write/delete policy       | `curl -sS -H "X-Vault-Token: $VAULT_TOKEN" $BAO_ADDR/v1/sys/policies/acl/panda-app`                                                                   |
| `/v1/sys/capabilities-self`     | POST           | what can my token do on a path | `curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{"paths":["secret/data/panda/db"]}' $BAO_ADDR/v1/sys/capabilities-self`                        |
| `/v1/sys/storage/raft/snapshot` | GET            | **backup** raft                | `curl -sS -H "X-Vault-Token: $VAULT_TOKEN" $BAO_ADDR/v1/sys/storage/raft/snapshot -o bao.snap`                                                        |
| `/v1/sys/audit/<path>`          | PUT            | enable audit device            | `curl -sS -X PUT -H "X-Vault-Token: $VAULT_TOKEN" -d '{"type":"file","options":{"file_path":"/openbao/logs/audit.log"}}' $BAO_ADDR/v1/sys/audit/file` |

### B.2 Auth endpoints (`/v1/auth/*`)

| Endpoint                              | Method          | Use case              | curl                                                                                                           |
|---------------------------------------|-----------------|-----------------------|----------------------------------------------------------------------------------------------------------------|
| `/v1/auth/approle/role/<n>`           | POST/GET/DELETE | manage roles          | `curl -sS -H "X-Vault-Token: $VAULT_TOKEN" $BAO_ADDR/v1/auth/approle/role/panda-app`                           |
| `/v1/auth/approle/role/<n>/role-id`   | GET             | read role_id          | `curl -sS -H "X-Vault-Token: $VAULT_TOKEN" $BAO_ADDR/v1/auth/approle/role/panda-app/role-id`                   |
| `/v1/auth/approle/role/<n>/secret-id` | POST            | mint secret_id        | `curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{}' $BAO_ADDR/v1/auth/approle/role/panda-app/secret-id` |
| `/v1/auth/approle/login`              | POST            | get token             | `curl -sS -X POST -d '{"role_id":"<R>","secret_id":"<S>"}' $BAO_ADDR/v1/auth/approle/login`                    |
| `/v1/auth/token/lookup-self`          | GET             | inspect current token | `curl -sS -H "X-Vault-Token: $APP_TOKEN" $BAO_ADDR/v1/auth/token/lookup-self`                                  |
| `/v1/auth/token/renew-self`           | POST            | renew current token   | `curl -sS -X POST -H "X-Vault-Token: $APP_TOKEN" -d '{}' $BAO_ADDR/v1/auth/token/renew-self`                   |
| `/v1/auth/token/revoke-self`          | POST            | revoke current token  | `curl -sS -X POST -H "X-Vault-Token: $APP_TOKEN" $BAO_ADDR/v1/auth/token/revoke-self`                          |

*(Not enabled here but common: `POST /v1/auth/kubernetes/login` `{"role":"..","jwt":".."}`,
`POST /v1/auth/userpass/login/<user>` `{"password":".."}`.)*

### B.3 Secrets engine endpoints

**KV v2** (`secret/`) — note `data/` / `metadata/` segments:

| Endpoint                  | Method   | Use case                   | curl                                                                                                                                        |
|---------------------------|----------|----------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `/v1/secret/data/<p>`     | GET      | read secret (`?version=N`) | `curl -sS -H "X-Vault-Token: $APP_TOKEN" $BAO_ADDR/v1/secret/data/panda/db`                                                                 |
| `/v1/secret/data/<p>`     | POST     | write/update (new version) | `curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{"data":{"username":"panda","password":"panda"}}' $BAO_ADDR/v1/secret/data/panda/db` |
| `/v1/secret/data/<p>`     | DELETE   | soft-delete latest         | `curl -sS -X DELETE -H "X-Vault-Token: $VAULT_TOKEN" $BAO_ADDR/v1/secret/data/panda/db`                                                     |
| `/v1/secret/metadata/<p>` | GET/LIST | versions / list keys       | `curl -sS -H "X-Vault-Token: $VAULT_TOKEN" $BAO_ADDR/v1/secret/metadata/panda/db`                                                           |
| `/v1/secret/metadata/<p>` | DELETE   | destroy all versions       | `curl -sS -X DELETE -H "X-Vault-Token: $VAULT_TOKEN" $BAO_ADDR/v1/secret/metadata/panda/db`                                                 |

**Other engines (reference):**

| Engine       | curl                                                                                                     | Use case                      |
|--------------|----------------------------------------------------------------------------------------------------------|-------------------------------|
| **database** | `curl -sS -H "X-Vault-Token: $T" $BAO_ADDR/v1/database/creds/<role>`                                     | dynamic, short-lived DB creds |
| **transit**  | `curl -sS -X POST -H "X-Vault-Token: $T" -d '{"plaintext":"<b64>"}' $BAO_ADDR/v1/transit/encrypt/<key>`  | encryption as a service       |
| **pki**      | `curl -sS -X POST -H "X-Vault-Token: $T" -d '{"common_name":"x.example"}' $BAO_ADDR/v1/pki/issue/<role>` | issue TLS certs               |

---

## Part C — What this project actually calls (full curl)

```bash
export BAO_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root>        # setup only

# ---------- SETUP (operator, one-time) ----------
curl -sS -X PUT  -d '{"secret_shares":5,"secret_threshold":3}' $BAO_ADDR/v1/sys/init
curl -sS -X PUT  -d '{"key":"<unseal-key-1>"}' $BAO_ADDR/v1/sys/unseal   # ×3
curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{"type":"kv","options":{"version":"2"}}' $BAO_ADDR/v1/sys/mounts/secret
curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{"data":{"username":"panda","password":"panda"}}' $BAO_ADDR/v1/secret/data/panda/db
curl -sS -X PUT  -H "X-Vault-Token: $VAULT_TOKEN" -d '{"policy":"path \"secret/data/panda/db\" { capabilities = [\"read\"] }"}' $BAO_ADDR/v1/sys/policies/acl/panda-app
curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{"type":"approle"}' $BAO_ADDR/v1/sys/auth/approle
curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{"token_policies":"panda-app","token_ttl":"1h","token_max_ttl":"4h"}' $BAO_ADDR/v1/auth/approle/role/panda-app
curl -sS -H "X-Vault-Token: $VAULT_TOKEN" $BAO_ADDR/v1/auth/approle/role/panda-app/role-id
curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -d '{}' $BAO_ADDR/v1/auth/approle/role/panda-app/secret-id

# ---------- RUNTIME (app, every startup — done by Spring Cloud Vault) ----------
APP_TOKEN=$(curl -sS -X POST -d '{"role_id":"<R>","secret_id":"<S>"}' $BAO_ADDR/v1/auth/approle/login \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")
curl -sS -H "X-Vault-Token: $APP_TOKEN" $BAO_ADDR/v1/secret/data/panda/db
curl -sS -X POST -H "X-Vault-Token: $APP_TOKEN" -d '{}' $BAO_ADDR/v1/auth/token/renew-self
```

> From inside the cluster, replace `127.0.0.1` with `192.168.64.1` (the host IP on the Lima vmnet).

See also: `PANDA-OPENBAO-REPORT.md` (overall system report) and `panda-app/README.md` (app runbook).
