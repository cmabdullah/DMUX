# OpenBao AppRole — runnable curls with REAL values (LOCAL ONLY)

> ⚠️ **DO NOT COMMIT.** This file is gitignored. It contains the live root token and
> secret_id in plaintext. For the shareable/redacted version see
> `APPROLE-AND-API-REFERENCE.md`.

**Host OpenBao:** `http://127.0.0.1:8200`  (from inside the RKE2 cluster use `http://192.168.64.1:8200`)

Real values used below:

- root token: `s.6xs6GECpriEbw3KUxTjZIG1s`   (setup only — revoke after)
- role_id:    `8284877b-8686-06f8-a13d-a150bfa64291`
- secret_id:  `5a410b39-3b31-d786-df29-795c14180a83`

Verified 2026-11-21: login returns policies `[default, panda-app]`, token TTL 3600s.

---

## Runtime flow (what the app does) — copy-paste runnable

### 1. Login (role_id + secret_id → token) — no auth header needed

```bash
curl -sS -X POST \
  -d '{"role_id":"8284877b-8686-06f8-a13d-a150bfa64291","secret_id":"5a410b39-3b31-d786-df29-795c14180a83"}' \
  http://127.0.0.1:8200/v1/auth/approle/login
```


response

```json
{
    "request_id": "03191e27-bf35-407a-6eb5-590cf610e08b",
    "lease_id": "",
    "renewable": false,
    "lease_duration": 0,
    "data": null,
    "wrap_info": null,
    "warnings": null,
    "auth": {
        "client_token": "s.jxWslO3BSjJ0XvI2opGFfV4i",
        "accessor": "UcBGHZhJQ7L7agtW9wbPQmoL",
        "policies": [
            "default",
            "panda-app"
        ],
        "token_policies": [
            "default",
            "panda-app"
        ],
        "metadata": {
            "role_name": "panda-app"
        },
        "lease_duration": 3600,
        "renewable": true,
        "entity_id": "98fe4396-ba5d-19e8-9b90-51c015fff161",
        "token_type": "service",
        "orphan": true,
        "mfa_requirement": null,
        "num_uses": 0
    }
}
```
Capture the returned token into a shell variable:

```bash
APP_TOKEN=$(curl -sS -X POST \
  -d '{"role_id":"8284877b-8686-06f8-a13d-a150bfa64291","secret_id":"5a410b39-3b31-d786-df29-795c14180a83"}' \
  http://127.0.0.1:8200/v1/auth/approle/login \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['auth']['client_token'])")
echo "$APP_TOKEN"
```

### 2. Read the DB credentials with that token (KV v2)

```bash
curl -sS -H "X-Vault-Token: $APP_TOKEN" \
  http://127.0.0.1:8200/v1/secret/data/panda/db
# -> {"data":{"data":{"username":"panda","password":"panda"},"metadata":{"version":1}}}
```


response

```json
{
    "request_id": "5807f8ee-9386-bea8-fccc-b043a6962ae0",
    "lease_id": "",
    "renewable": false,
    "lease_duration": 0,
    "data": {
        "data": {
            "password": "panda",
            "username": "panda"
        },
        "metadata": {
            "created_time": "2026-11-21T05:01:33.452000242Z",
            "custom_metadata": null,
            "deletion_time": "",
            "destroyed": false,
            "version": 1
        }
    },
    "wrap_info": null,
    "warnings": null,
    "auth": null
}
```

### 3. Renew the token (keep the session alive)

```bash
curl -sS -X POST -H "X-Vault-Token: $APP_TOKEN" -d '{}' \
  http://127.0.0.1:8200/v1/auth/token/renew-self
```

response

```json
{
    "request_id": "9a17b938-3788-499c-b0e2-130561f43f19",
    "lease_id": "",
    "renewable": false,
    "lease_duration": 0,
    "data": null,
    "wrap_info": null,
    "warnings": null,
    "auth": {
        "client_token": "s.jxWslO3BSjJ0XvI2opGFfV4i",
        "accessor": "UcBGHZhJQ7L7agtW9wbPQmoL",
        "policies": [
            "default",
            "panda-app"
        ],
        "token_policies": [
            "default",
            "panda-app"
        ],
        "metadata": {
            "role_name": "panda-app"
        },
        "lease_duration": 3600,
        "renewable": true,
        "entity_id": "98fe4396-ba5d-19e8-9b90-51c015fff161",
        "token_type": "service",
        "orphan": true,
        "mfa_requirement": null,
        "num_uses": 0
    }
}
```
---

## Setup flow (operator, root token) — with real values

> Steps 1–6 were ALREADY run on this host. Re-running `init`/`unseal`/`enable` will error
> (already initialized / path in use). Shown for reference and reproducibility.

```bash
export BAO_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=s.6xs6GECpriEbw3KUxTjZIG1s
```

### 1. Initialize (ALREADY DONE)

```bash
curl -sS -X PUT -d '{"secret_shares":5,"secret_threshold":3}' \
  http://127.0.0.1:8200/v1/sys/init
```

### 2. Unseal ×3 (ALREADY DONE — keys in CREDENTIALS.local.md)

```bash
curl -sS -X PUT -d '{"key":"<unseal-key-1>"}' http://127.0.0.1:8200/v1/sys/unseal
curl -sS -X PUT -d '{"key":"<unseal-key-2>"}' http://127.0.0.1:8200/v1/sys/unseal
curl -sS -X PUT -d '{"key":"<unseal-key-3>"}' http://127.0.0.1:8200/v1/sys/unseal
```

### 3. Enable KV v2 (ALREADY DONE)

```bash
curl -sS -X POST -H "X-Vault-Token: s.6xs6GECpriEbw3KUxTjZIG1s" \
  -d '{"type":"kv","options":{"version":"2"}}' \
  http://127.0.0.1:8200/v1/sys/mounts/secret
```

### 4. Store the DB credentials

```bash
curl -sS -X POST -H "X-Vault-Token: s.6xs6GECpriEbw3KUxTjZIG1s" \
  -d '{"data":{"username":"panda","password":"panda"}}' \
  http://127.0.0.1:8200/v1/secret/data/panda/db
```

### 5. Write the read-only policy

```bash
curl -sS -X PUT -H "X-Vault-Token: s.6xs6GECpriEbw3KUxTjZIG1s" \
  -d '{"policy":"path \"secret/data/panda/db\" { capabilities = [\"read\"] }"}' \
  http://127.0.0.1:8200/v1/sys/policies/acl/panda-app
```

### 6. Enable AppRole (ALREADY DONE)

```bash
curl -sS -X POST -H "X-Vault-Token: s.6xs6GECpriEbw3KUxTjZIG1s" \
  -d '{"type":"approle"}' \
  http://127.0.0.1:8200/v1/sys/auth/approle
```

### 7. Create the role

```bash
curl -sS -X POST -H "X-Vault-Token: s.6xs6GECpriEbw3KUxTjZIG1s" \
  -d '{"token_policies":"panda-app","token_ttl":"1h","token_max_ttl":"4h"}' \
  http://127.0.0.1:8200/v1/auth/approle/role/panda-app
```

### 8. Read role_id

```bash
curl -sS -H "X-Vault-Token: s.6xs6GECpriEbw3KUxTjZIG1s" \
  http://127.0.0.1:8200/v1/auth/approle/role/panda-app/role-id
# -> {"data":{"role_id":"8284877b-8686-06f8-a13d-a150bfa64291"}}
```

### 9. Generate a NEW secret_id (rotation)

```bash
curl -sS -X POST -H "X-Vault-Token: s.6xs6GECpriEbw3KUxTjZIG1s" -d '{}' \
  http://127.0.0.1:8200/v1/auth/approle/role/panda-app/secret-id
# -> {"data":{"secret_id":"<new>","secret_id_accessor":"<acc>", ...}}
```

---

## From inside the cluster

Same calls, host IP instead of localhost:

```bash
curl -sS -X POST \
  -d '{"role_id":"8284877b-8686-06f8-a13d-a150bfa64291","secret_id":"5a410b39-3b31-d786-df29-795c14180a83"}' \
  http://192.168.64.1:8200/v1/auth/approle/login
```

(This is exactly what the panda-app pod does, via Spring Cloud Vault, using the
`openbao-approle` K8s Secret.)
