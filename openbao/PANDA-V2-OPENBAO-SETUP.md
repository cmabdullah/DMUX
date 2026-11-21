# Configuring `panda-v2` for OpenBao — step-by-step (curl)

How to onboard a **second application (`panda-v2`)** to the same host OpenBao, with its
own secret, its own least-privilege policy, and its own AppRole identity — fully isolated
from `panda-app`. Every step is a `curl` with the real request/response captured from this
instance (2026-11-21).

- **OpenBao:** `http://127.0.0.1:8200` (host) · `http://192.168.64.1:8200` (from the cluster)
- **Secret path:** `secret/panda-v2/db`
- **Policy:** `panda-v2` (read-only on `secret/data/panda-v2/db`)
- **AppRole role:** `panda-v2`

> **Security:** the **root token** and **secret_id** are redacted here (`<ROOT_TOKEN>`,
> `<SECRET_ID>`). The runnable version with real values is in the gitignored
> `openbao/PANDA-V2-CURLS.local.md`. The `role_id` is shown (it is not secret on its own).

---

## Block diagram

```
                              HOST (192.168.64.1)
   ┌──────────────────────────────────────────────────────────────────────┐
   │  OpenBao  :8200                                                        │
   │                                                                        │
   │   auth/approle/                         secret/ (KV v2)                │
   │   ├── role: panda-app   ──policy──▶ panda-app  ──reads──▶ panda/db     │
   │   └── role: panda-v2    ──policy──▶ panda-v2   ──reads──▶ panda-v2/db  │
   │                                                                        │
   │   Isolation: panda-v2's token can read ONLY secret/data/panda-v2/db.   │
   │              It is DENIED secret/data/panda/db (and vice-versa).       │
   └───────────────▲─────────────────────────────────────────▲────────────┘
                   │ (1) login role_id+secret_id              │ (3) JDBC
                   │ (2) read secret/panda-v2/db              │
   ┌───────────────┼──────────────────────────────┐    ┌─────┴───────────┐
   │ panda-v2 app                                  │    │ Postgres :5432  │
   │  role_id + secret_id (from a K8s Secret)      │    │  db: panda      │
   │  Spring Cloud Vault → login → read → datasource     └─────────────────┘
   └──────────────────────────────────────────────┘
```

### AppRole login → read flow (sequence)

```
 panda-v2 app                         OpenBao                         Postgres
     │  POST /v1/auth/approle/login      │                               │
     │  {role_id, secret_id}  ─────────▶ │  validate → mint token         │
     │  ◀── client_token (TTL 1h) ────── │  (policies: default, panda-v2) │
     │  GET /v1/secret/data/panda-v2/db  │                               │
     │  X-Vault-Token: <token> ────────▶ │  ACL check (panda-v2 policy)   │
     │  ◀── {username, password} ─────── │                               │
     │  JDBC connect(username,password) ───────────────────────────────▶ connected
```

---

## Prerequisites (already satisfied on this host)

The KV v2 engine (`secret/`) and the AppRole auth method (`auth/approle/`) are already
enabled (shared with `panda-app`). If starting fresh:

```bash
# enable KV v2
curl -sS -X POST -H "X-Vault-Token: <ROOT_TOKEN>" \
  -d '{"type":"kv","options":{"version":"2"}}' \
  http://127.0.0.1:8200/v1/sys/mounts/secret

# enable AppRole
curl -sS -X POST -H "X-Vault-Token: <ROOT_TOKEN>" \
  -d '{"type":"approle"}' \
  http://127.0.0.1:8200/v1/sys/auth/approle
```

---

## Step 1 — Store the secret at `secret/panda-v2/db`

```bash
curl -sS -X POST \
  -H "X-Vault-Token: <ROOT_TOKEN>" \
  -d '{"data":{"username":"panda","password":"panda"}}' \
  http://127.0.0.1:8200/v1/secret/data/panda-v2/db
```

**Response** (KV v2 returns version metadata):

```json
{
  "data": {
    "created_time": "2026-11-21T10:26:16.443808231Z",
    "custom_metadata": null,
    "deletion_time": "",
    "destroyed": false,
    "version": 1
  }
}
```

> KV v2 nests the payload under `data` → the write body is `{"data":{...}}`, and reads come
> back at `.data.data`.

---

## Step 2 — Write the least-privilege policy `panda-v2`

The policy allows **read only** on this app's path (`secret/data/...` because KV v2):

```bash
curl -sS -X PUT \
  -H "X-Vault-Token: <ROOT_TOKEN>" \
  -d '{"policy":"path \"secret/data/panda-v2/db\" { capabilities = [\"read\"] }"}' \
  http://127.0.0.1:8200/v1/sys/policies/acl/panda-v2
```

**Response:** `HTTP 204 No Content` (success, empty body).

Verify:

```bash
curl -sS -H "X-Vault-Token: <ROOT_TOKEN>" \
  http://127.0.0.1:8200/v1/sys/policies/acl/panda-v2
# {"data":{"name":"panda-v2","policy":"path \"secret/data/panda-v2/db\" { capabilities = [\"read\"] }"}}
```

---

## Step 3 — Create the AppRole role `panda-v2`

Binds the login role to the `panda-v2` policy and sets token lifetimes:

```bash
curl -sS -X POST \
  -H "X-Vault-Token: <ROOT_TOKEN>" \
  -d '{"token_policies":"panda-v2","token_ttl":"1h","token_max_ttl":"4h"}' \
  http://127.0.0.1:8200/v1/auth/approle/role/panda-v2
```

**Response:** `HTTP 204 No Content`. A `role_id` is auto-generated with the role.

---

## Step 4 — Read the `role_id` (stable identifier)

```bash
curl -sS -H "X-Vault-Token: <ROOT_TOKEN>" \
  http://127.0.0.1:8200/v1/auth/approle/role/panda-v2/role-id
```

**Response:**

```json
{
  "request_id": "dd318433-e56a-2650-27a8-2b130d5159e2",
  "lease_id": "",
  "renewable": false,
  "lease_duration": 0,
  "data": {
    "role_id": "7f96af3a-1e06-41ab-4314-aa732bd03f65"
  },
  "wrap_info": null,
  "warnings": null,
  "auth": null
}
```

---

## Step 5 — Generate a `secret_id` (the credential)

```bash
curl -sS -X POST \
  -H "X-Vault-Token: <ROOT_TOKEN>" \
  -d '{}' \
  http://127.0.0.1:8200/v1/auth/approle/role/panda-v2/secret-id
```

**Response** (secret_id redacted — see the local file for the real value):

```json
{
  "request_id": "86a65685-8dbd-0859-eabc-534e03e8907b",
  "lease_id": "",
  "renewable": false,
  "lease_duration": 0,
  "data": {
    "secret_id": "1a61a8bb-5085-aab3-081e-7fe41237d66b",
    "secret_id_accessor": "cd1aeb6a-ef98-d22a-7a83-cd929d5e764e",
    "secret_id_num_uses": 0,
    "secret_id_ttl": 0
  },
  "wrap_info": null,
  "warnings": null,
  "auth": null
}
```

> Each call mints a NEW secret_id (that's how you rotate). `secret_id_ttl: 0` = never
> expires — fine for dev, set a TTL for prod.

---

## Step 6 — Login (role_id + secret_id → token)

This is what the app does. **No auth header** — this call *obtains* the token:

```bash
curl -sS -X POST \
  -d '{"role_id":"4ae1f81e-4674-db12-14a8-5a67381690ee","secret_id":"<SECRET_ID>"}' \
  http://127.0.0.1:8200/v1/auth/approle/login
```

**Response** (client_token/accessor redacted):

```json
{
  "request_id": "67b8a1f6-3a19-66c7-b4c9-54e7de761443",
  "lease_id": "",
  "renewable": false,
  "lease_duration": 0,
  "data": null,
  "wrap_info": null,
  "warnings": null,
  "auth": {
    "client_token": "s.QKozlsExdbkmjxJZwtt9D4nq",
    "accessor": "nkMNe7T9zxzQEzbvshwQVqkJ",
    "policies": [
      "default",
      "panda-v3"
    ],
    "token_policies": [
      "default",
      "panda-v3"
    ],
    "metadata": {
      "role_name": "panda-v3"
    },
    "lease_duration": 3600,
    "renewable": true,
    "entity_id": "d842f4c1-9f73-53f4-c7b9-fa530f5d882e",
    "token_type": "service",
    "orphan": true,
    "mfa_requirement": null,
    "num_uses": 0
  }
}
```

Capture it for the next call:

```bash
APP_TOKEN=$(curl -sS -X POST \
  -d '{"role_id":"4ae1f81e-4674-db12-14a8-5a67381690ee","secret_id":"<SECRET_ID>"}' \
  http://127.0.0.1:8200/v1/auth/approle/login \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")
```

---

## Step 7 — Read the secret with the app token

```bash
curl -sS -H "X-Vault-Token: $APP_TOKEN" \
  http://127.0.0.1:8200/v1/secret/data/panda-v2/db
```

**Response:**

```json
{
  "data": {
    "data": {
      "password": "panda",
      "username": "panda"
    },
    "metadata": {
      "version": 1,
      "destroyed": false
    }
  }
}
```

---

## Step 8 — Verify isolation (the whole point)

The `panda-v2` token must be **denied** `panda-app`'s secret:

```bash
curl -sS -H "X-Vault-Token: $APP_TOKEN" \
  http://127.0.0.1:8200/v1/secret/data/panda/db
```

**Response (verified):**

```json
{
  "errors": [
    "1 error occurred:\n\t* permission denied\n\n"
  ]
}
```

✅ Confirmed: `panda-v2` can read `secret/data/panda-v2/db` only. `panda-app` likewise
cannot read `panda-v2`'s secret. Each app is scoped to its own path by its own policy.

---

## Step 9 — Wire it into an app (Kubernetes)

Same pattern as `panda-app` — only the names/paths change:

```bash
# 1. K8s Secret with panda-v2's AppRole creds (don't commit real values)
./rke2-mac.sh kubectl -n panda create secret generic openbao-approle-v2 \
  --from-literal=role-id=4ae1f81e-4674-db12-14a8-5a67381690ee \
  --from-literal=secret-id=<SECRET_ID>
```

Spring Cloud Vault config for the panda-v2 app (`application.yml`):

```yaml
spring:
  config:
    import: "vault://secret/panda-v2/db"     # <-- v2 path
  cloud:
    vault:
      uri: ${BAO_ADDR:http://192.168.64.1:8200}
      authentication: APPROLE
      app-role:
        role-id: ${BAO_ROLE_ID}              # from openbao-approle-v2 Secret
        secret-id: ${BAO_SECRET_ID}
  datasource:
    url: jdbc:postgresql://${DB_HOST}:${DB_PORT:5432}/${DB_NAME:panda}
    username: ${username}
    password: ${password}
```

---

## Summary of what was created for `panda-v2`

| Object    | Value                                    | API endpoint                          |
|-----------|------------------------------------------|---------------------------------------|
| Secret    | `secret/panda-v2/db` (username/password) | `POST /v1/secret/data/panda-v2/db`    |
| Policy    | `panda-v2` (read-only)                   | `PUT /v1/sys/policies/acl/panda-v2`   |
| Role      | `panda-v2` (token_ttl 1h)                | `POST /v1/auth/approle/role/panda-v2` |
| role_id   | `4ae1f81e-4674-db12-14a8-5a67381690ee`   | `GET .../role/panda-v2/role-id`       |
| secret_id | `<in PANDA-V2-CURLS.local.md>`           | `POST .../role/panda-v2/secret-id`    |

See also: `APPROLE-AND-API-REFERENCE.md` (all endpoints) · `PANDA-OPENBAO-REPORT.md`
(overall system) · `PANDA-V2-CURLS.local.md` (real runnable values, gitignored).
