# OpenBao — Credentials & Operational Reference (LOCAL ONLY)

> ⚠️ **DO NOT COMMIT THIS FILE.** It is listed in `.gitignore`.
> These are the master credentials for this OpenBao instance. Anyone with the
> unseal keys + root token has full control of every secret stored here.
> Move them to a real secret manager and delete this file when done testing.

- **Instance:** local Docker Compose (`openbao/docker-compose.yml`)
- **Address:** http://localhost:8200
- **Version:** OpenBao v2.7.3
- **Initialized:** 2026-11-20 (5 key shares, threshold 3)

---

## Root token

```
s.6xs6GECpriEbw3KUxTjZIG1s
```

> Revoke this after setting up a proper auth method:
> `bao token revoke <token>` — see §Production in `README.md`.

## Unseal keys (5 total — any 3 required to unseal)

```
key1: CdxV1723FLMJPXdIg2OoOwsB1Qo2L4uuHPLSNoVneWSK
key2: +s6VhwSzMU4vumaoABn4qfQ+9Mvn+H/NCuvKeckx68cU
key3: FM/CR87PxSyhZiRS8rYYV1sxdH8DGnv9vewpzNfFTd7y
key4: D6rRKFrSWAbDrOdoIRnB6LrbVCSzE11Z1PITzvzWfisv
key5: iAsRsVsL8xveGRwJn4NJ33YN6c7NnefdcOIB6zteIYmM
```

---

## Quick operational commands

Set these once in your shell to shorten the commands below:

```bash
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=s.6xs6GECpriEbw3KUxTjZIG1s
```

### Start / status

```bash
cd openbao && docker compose up -d
docker exec -e BAO_ADDR=$BAO_ADDR openbao bao status
```

### Unseal after every restart (run 3 times, 3 different keys)

```bash
docker exec -e BAO_ADDR=$BAO_ADDR openbao bao operator unseal CdxV1723FLMJPXdIg2OoOwsB1Qo2L4uuHPLSNoVneWSK
docker exec -e BAO_ADDR=$BAO_ADDR openbao bao operator unseal +s6VhwSzMU4vumaoABn4qfQ+9Mvn+H/NCuvKeckx68cU
docker exec -e BAO_ADDR=$BAO_ADDR openbao bao operator unseal FM/CR87PxSyhZiRS8rYYV1sxdH8DGnv9vewpzNfFTd7y
```

### Log in (CLI / UI)

```bash
docker exec -it -e BAO_ADDR=$BAO_ADDR openbao bao login s.6xs6GECpriEbw3KUxTjZIG1s
# UI: open http://localhost:8200 and paste the root token
```

### Read / write secrets (KV v2, mounted at secret/)

```bash
docker exec -e BAO_ADDR=$BAO_ADDR -e BAO_TOKEN=$BAO_TOKEN openbao bao kv put secret/myapp username=admin password=s3cr3t
docker exec -e BAO_ADDR=$BAO_ADDR -e BAO_TOKEN=$BAO_TOKEN openbao bao kv get secret/myapp
```

---

## Current state (as of 2026-11-20)

- Status: Initialized ✅, Unsealed ✅, HA Mode `active`
- KV v2 engine enabled at `secret/`
- Test secret present at `secret/myapp` (username=admin, password=s3cr3t)
