# OpenBao — AppRole Setup (step by step) & API Endpoint Reference

**Date:** 2026-11-21
**Instance:** host OpenBao `http://127.0.0.1:8200` (v2.7.3), reached from the RKE2 cluster
at `http://192.168.64.1:8200`.

> **Security:** real `role_id`, `secret_id`, tokens, and unseal keys are **not** in this
> file. Examples use `<PLACEHOLDER>` / sample UUIDs from a throwaway `demo-role`. Live
> credentials live in gitignored files.

---

## Part A — AppRole, step by step

AppRole has **four** distinct concepts. Keep them straight:

| Concept       | Analogy                | Created when                    | Mutable?              | Secret?             |
|---------------|------------------------|---------------------------------|-----------------------|---------------------|
| **role**      | the account definition | you *write* the role            | only if rewritten     | no                  |
| **role_id**   | username               | auto, with the role             | stable                | low (useless alone) |
| **secret_id** | password               | each *write* to `.../secret-id` | new every call        | **yes**             |
| **token**     | session cookie         | at *login*                      | expires (`token_ttl`) | **yes**             |

All `bao` commands below run against the host container with the **root token** (setup only):

```bash
ROOT=<root-token>            # from openbao/CREDENTIALS.local.md
R() { docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$ROOT" openbao "$@"; }
```

---

### Step 0 — Prerequisite: enable AppRole + write the policy

**Enable the AppRole auth method** (mounts it at `auth/approle/`):

```bash
R bao auth enable approle
```

- HTTP: `POST /v1/sys/auth/approle`  body `{"type":"approle"}`
- Effect: a new auth backend appears (see `bao auth list`).

**Write the policy** the role will hand out (least-privilege read):

```bash
printf 'path "secret/data/panda/db" { capabilities = ["read"] }\n' \
  | docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$ROOT" \
      openbao bao policy write panda-app -
```

- HTTP: `PUT /v1/sys/policies/acl/panda-app`  body
  `{"policy":"path \"secret/data/panda/db\" {capabilities=[\"read\"]}"}`
- Note the `secret/data/...` prefix — KV **v2** stores data under `data/` (ACLs must match that).

---

### Step 1 — Create the role

```bash
R bao write auth/approle/role/panda-app \
  token_policies=panda-app \
  token_ttl=1h \
  token_max_ttl=4h
```

- **HTTP:** `POST /v1/auth/approle/role/panda-app`
- **Request body:**
  ```json
  { "token_policies": "panda-app", "token_ttl": "1h", "token_max_ttl": "4h" }
  ```
- **Response:** `204 No Content` (CLI prints `Success! Data written to: auth/approle/role/panda-app`)
- **What happens:** a login role named `panda-app` is created. A **role_id is auto-generated
  and stored with it**. Tokens issued via this role will carry the `panda-app` policy and
  live 1h (renewable up to 4h).

Key role parameters:

| Param                         | Meaning                             | Value here     | Prod suggestion    |
|-------------------------------|-------------------------------------|----------------|--------------------|
| `token_policies`              | policies granted to the login token | `panda-app`    | least-privilege    |
| `token_ttl` / `token_max_ttl` | token lifetime / cap                | 1h / 4h        | short              |
| `secret_id_ttl`               | how long a secret_id is valid       | `0` (never) ⚠️ | e.g. `24h`         |
| `secret_id_num_uses`          | max logins per secret_id            | `0` (∞) ⚠️     | `1` for single-use |
| `token_num_uses`              | max uses of issued token            | `0` (∞)        | limit if possible  |
| `secret_id_bound_cidrs`       | restrict secret_id by source IP     | —              | cluster subnet     |
| `token_bound_cidrs`           | restrict token use by source IP     | —              | cluster subnet     |

---

### Step 2 — Inspect the role (optional)

```bash
R bao read auth/approle/role/panda-app
```

- **HTTP:** `GET /v1/auth/approle/role/panda-app`
- **Response (abridged):**
  ```json
  { "data": { "token_policies": ["panda-app"], "token_ttl": 3600,
              "secret_id_ttl": 0, "secret_id_num_uses": 0 } }
  ```

---

### Step 3 — Read the role_id (stable)

```bash
R bao read auth/approle/role/panda-app/role-id
# Key      Value
# role_id  491a42ed-f8ef-be78-4145-4f24664fe559   (example)
```

- **HTTP:** `GET /v1/auth/approle/role/panda-app/role-id`
- **Response:** `{ "data": { "role_id": "491a42ed-..." } }`
- **Important:** reading is **idempotent** — same value every time, nothing is generated.
  The role_id is the stable *identifier* (like a username). Safe-ish to put in app config.

---

### Step 4 — Generate a secret_id (the credential)

```bash
R bao write -f auth/approle/role/panda-app/secret-id
# secret_id           2d43044c-93ba-a6ff-2e36-7d5df8428ad7   (example)
# secret_id_accessor  7294dad0-e0b2-bde9-d2c9-28184bd89ee8
```

- **HTTP:** `POST /v1/auth/approle/role/panda-app/secret-id`  (body `{}`; `-f` = force, no input)
- **Response:**
  ```json
  { "data": { "secret_id": "2d43044c-...", "secret_id_accessor": "7294dad0-...",
              "secret_id_ttl": 0, "secret_id_num_uses": 0 } }
  ```
- **Important:** **every call mints a NEW secret_id.** This is how you **rotate** — generate
  a fresh one, switch the app to it, then revoke the old. The `secret_id_accessor` lets you
  revoke a specific secret_id *without* knowing its value:
  ```bash
  R bao write auth/approle/role/panda-app/secret-id-accessor/destroy accessor=<accessor>
  # HTTP: POST /v1/auth/approle/role/panda-app/secret-id-accessor/destroy
  ```
- **Tip (prod):** add `-wrap-ttl=120s` to get a *response-wrapped* secret_id — a one-time
  unwrap token you hand to the app so the raw secret_id never sits in plaintext.

---

### Step 5 — Login (role_id + secret_id → token)

```bash
R bao write auth/approle/login \
  role_id=<ROLE_ID> secret_id=<SECRET_ID>
```

- **HTTP:** `POST /v1/auth/approle/login`
- **Request body:**
  ```json
  { "role_id": "<ROLE_ID>", "secret_id": "<SECRET_ID>" }
  ```
- **Response (token redacted):**
  ```json
  { "auth": {
      "client_token": "<REDACTED>",
      "accessor": "<REDACTED>",
      "token_policies": ["default", "panda-app"],
      "lease_duration": 3600,
      "renewable": true,
      "metadata": { "role_name": "panda-app" } } }
  ```
- **What happens:** both halves together prove identity → OpenBao returns a token carrying
  the role's policies. Neither role_id nor secret_id alone is sufficient (that split is the
  whole point of AppRole).

---

### Step 6 — Use the token to read the secret

```bash
R bao kv get secret/panda/db        # with X-Vault-Token: <client_token>
```

- **HTTP:** `GET /v1/secret/data/panda/db`  header `X-Vault-Token: <client_token>`
- **Response:** values nested at `.data.data` (KV v2):
  ```json
  { "data": { "data": { "username": "panda", "password": "panda" },
              "metadata": { "version": 1 } } }
  ```

> In production this whole chain (Steps 5–6, plus token renewal) is performed automatically
> by **Spring Cloud Vault** inside the app, using `BAO_ROLE_ID` / `BAO_SECRET_ID` from the
> `openbao-approle` Kubernetes Secret.

---

### Lifecycle: rotating a secret_id

```bash
# 1. mint a new secret_id
NEW=$(R bao write -f -field=secret_id auth/approle/role/panda-app/secret-id)
# 2. update the K8s Secret
kubectl -n panda create secret generic openbao-approle \
  --from-literal=role-id=<ROLE_ID> --from-literal=secret-id="$NEW" \
  --dry-run=client -o yaml | ./rke2-mac.sh kubectl apply -f -
# 3. restart the app to pick it up
./rke2-mac.sh kubectl -n panda rollout restart deploy/panda-app
# 4. (optional) destroy the old secret_id by its accessor
```

---

## Part B — OpenBao API endpoint reference

OpenBao exposes a Vault-compatible HTTP API, all under `/v1/...`. Three broad families:
**system** (`sys/*`), **auth methods** (`auth/<method>/*`), and **secrets engines**
(`<mount>/*`). `LIST` is a real HTTP verb here (or `GET ...?list=true`).

### Live state on this instance

```
Secrets engines (bao secrets list):   cubbyhole/  identity/  kubernetes/  secret/(kv v2)  sys/
Auth methods   (bao auth list):       approle/    token/
Policies       (bao policy list):     default  panda-app  root
```

### B.1 System endpoints (`/v1/sys/*`) — control plane

| Endpoint                                 | Method         | Use case                                                          | Used here?          |
|------------------------------------------|----------------|-------------------------------------------------------------------|---------------------|
| `/v1/sys/health`                         | GET            | Health/readiness: initialized, sealed, active/standby             | ✅ reachability test |
| `/v1/sys/seal-status`                    | GET            | Seal state + unseal progress                                      | —                   |
| `/v1/sys/init`                           | GET/PUT        | Check init status / initialize (returns unseal keys + root token) | ✅ init              |
| `/v1/sys/unseal`                         | PUT            | Submit an unseal key (repeat to threshold)                        | ✅ unseal ×3         |
| `/v1/sys/seal`                           | POST           | Manually re-seal                                                  | —                   |
| `/v1/sys/mounts`                         | GET/LIST       | List secrets engines                                              | ✅ (list)            |
| `/v1/sys/mounts/<path>`                  | POST/DELETE    | Enable/disable a secrets engine                                   | ✅ enable kv v2      |
| `/v1/sys/auth`                           | GET/LIST       | List auth methods                                                 | ✅ (list)            |
| `/v1/sys/auth/<path>`                    | POST/DELETE    | Enable/disable an auth method                                     | ✅ enable approle    |
| `/v1/sys/policies/acl`                   | LIST           | List ACL policies                                                 | ✅                   |
| `/v1/sys/policies/acl/<name>`            | GET/PUT/DELETE | Read/write/delete a policy                                        | ✅ write panda-app   |
| `/v1/sys/leases/*`                       | POST           | Look up / renew / revoke leases                                   | — (SCV renews)      |
| `/v1/sys/audit` / `/v1/sys/audit/<path>` | GET/PUT/DELETE | Manage audit log devices                                          | ⬜ recommended       |
| `/v1/sys/storage/raft/*`                 | GET/POST       | Raft config, join, snapshot (backup/restore)                      | ⬜ recommended       |
| `/v1/sys/capabilities-self`              | POST           | What can my token do on a path?                                   | —                   |
| `/v1/sys/tools/*`                        | POST           | Random bytes, hashing utilities                                   | —                   |

### B.2 Auth method endpoints (`/v1/auth/*`)

**AppRole** (`auth/approle/`) — used by the app:

| Endpoint                                                  | Method               | Use case                               |
|-----------------------------------------------------------|----------------------|----------------------------------------|
| `/v1/auth/approle/role/<name>`                            | POST/GET/DELETE/LIST | Create/read/delete/list roles          |
| `/v1/auth/approle/role/<name>/role-id`                    | GET/POST             | Read (or set) the stable role_id       |
| `/v1/auth/approle/role/<name>/secret-id`                  | POST                 | Generate a new secret_id               |
| `/v1/auth/approle/role/<name>/secret-id/lookup`           | POST                 | Inspect a secret_id (by value)         |
| `/v1/auth/approle/role/<name>/secret-id-accessor/destroy` | POST                 | Revoke a secret_id by accessor         |
| `/v1/auth/approle/login`                                  | POST                 | Exchange role_id+secret_id for a token |

**Token** (`auth/token/`) — always present:

| Endpoint                     | Method | Use case                                  |
|------------------------------|--------|-------------------------------------------|
| `/v1/auth/token/lookup-self` | GET    | Inspect the current token (policies, TTL) |
| `/v1/auth/token/renew-self`  | POST   | Renew the current token's lease           |
| `/v1/auth/token/create`      | POST   | Mint a child token                        |
| `/v1/auth/token/revoke`      | POST   | Revoke a token                            |

**Other common auth methods** (not enabled here, for reference):
`auth/kubernetes/login` (pod SA-token login — would be used if OpenBao ran *in* the cluster),
`auth/userpass/login/<user>`, `auth/ldap/login/<user>`, `auth/jwt|oidc/login`.

### B.3 Secrets engine endpoints

**KV v2** (`secret/`) — used by the app. Note the `data/` / `metadata/` segments:

| Endpoint                     | Method   | Use case                             |
|------------------------------|----------|--------------------------------------|
| `/v1/secret/data/<path>`     | GET      | Read latest (or `?version=N`) secret |
| `/v1/secret/data/<path>`     | POST     | Write/update a secret (new version)  |
| `/v1/secret/data/<path>`     | DELETE   | Soft-delete latest version           |
| `/v1/secret/metadata/<path>` | GET/LIST | Versions/metadata; list keys         |
| `/v1/secret/metadata/<path>` | DELETE   | Permanently delete all versions      |
| `/v1/secret/destroy/<path>`  | POST     | Destroy specific versions            |
| `/v1/secret/config`          | GET/POST | Engine config (max versions, etc.)   |

> KV **v1** (if mounted) is flat: `GET/POST/DELETE /v1/<mount>/<path>` (no `data/`).

**Other engines worth knowing** (not used here):

| Engine        | Representative endpoint          | Use case                                                                                             |
|---------------|----------------------------------|------------------------------------------------------------------------------------------------------|
| **database**  | `GET /v1/database/creds/<role>`  | **Dynamic**, short-lived DB credentials (rotated per lease) — the recommended upgrade from static KV |
| **transit**   | `POST /v1/transit/encrypt/<key>` | Encryption-as-a-service (no key exposure); also for auto-unseal                                      |
| **pki**       | `POST /v1/pki/issue/<role>`      | Issue short-lived TLS certs                                                                          |
| **cubbyhole** | `GET/POST /v1/cubbyhole/<path>`  | Per-token private scratch (used for response-wrapping)                                               |
| **identity**  | `/v1/identity/*`                 | Entities/groups across auth methods                                                                  |

---

## Part C — What this project actually calls

```
SETUP (operator, root token, one-time)
  PUT  /v1/sys/init                      -> keys + root token
  PUT  /v1/sys/unseal            (×3)    -> unsealed
  POST /v1/sys/mounts/secret            -> enable KV v2
  POST /v1/secret/data/panda/db         -> store {username,password}
  PUT  /v1/sys/policies/acl/panda-app   -> read-only policy
  POST /v1/sys/auth/approle             -> enable AppRole
  POST /v1/auth/approle/role/panda-app  -> create role
  GET  /v1/auth/approle/role/panda-app/role-id    -> role_id
  POST /v1/auth/approle/role/panda-app/secret-id  -> secret_id

RUNTIME (app via Spring Cloud Vault, every startup)
  POST /v1/auth/approle/login           -> client_token (TTL 1h)
  GET  /v1/secret/data/panda/db         -> username/password
  POST /v1/auth/token/renew-self        -> keep token alive
```

See also: `PANDA-OPENBAO-REPORT.md` (overall system report) and
`panda-app/README.md` (app runbook).
