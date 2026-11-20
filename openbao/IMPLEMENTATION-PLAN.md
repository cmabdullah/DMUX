# OpenBao — Docker Compose Implementation Plan

Plan to self-host **OpenBao** (the Linux Foundation / open-source fork of HashiCorp
Vault) via Docker Compose, using integrated **Raft** storage with persistence.

- **Status:** ✅ Implemented & verified (OpenBao v2.7.3, 2026-11-20)
- **Date:** 2026-11-20
- **Branch:** `OpenBao`
- **Target UI / API:** http://localhost:8200

---

## 1. What is OpenBao (and how it differs from Vault)

OpenBao is a fork of HashiCorp Vault maintained under the Linux Foundation. It keeps
the **same HCL config format and HTTP API**, so Vault knowledge transfers directly.
The differences that matter for this setup:

| Aspect                  | HashiCorp Vault               | OpenBao                                              |
|-------------------------|-------------------------------|------------------------------------------------------|
| Docker image            | `hashicorp/vault`             | `openbao/openbao`                                    |
| CLI binary              | `vault`                       | `bao`                                                |
| Env var prefix          | `VAULT_*` (e.g. `VAULT_ADDR`) | `BAO_*` (e.g. `BAO_ADDR`)                            |
| In-container config dir | `/vault/config`               | `/openbao/config`                                    |
| In-container logs dir   | `/vault/logs`                 | `/openbao/logs`                                      |
| Storage backends        | `file`, `raft`, …             | `raft` (the `file` backend was **removed in 2.7.0**) |

> **Verified facts** (Nov 2026): image `openbao/openbao`; binary `bao`; config dir
> `/openbao/config`; logs `/openbao/logs`. The Alpine/UBI entrypoint auto-appends
> `-config=/openbao/config` for the `server` subcommand (see §6). Sources listed at the end.

---

## 2. Goals & scope

**In scope**

- Single-node OpenBao server in Docker Compose
- Integrated Raft storage with a persistent host volume
- Web UI + API reachable on the host
- Initialize → unseal → enable KV v2 → write/read a test secret
- Documented daily operations and a production hardening checklist

**Out of scope (noted for later)**

- Multi-node Raft HA cluster
- TLS termination (plan runs with `tls_disable = true`; reverse proxy / certs are a follow-up)
- Auto-unseal (KMS / Transit)
- Auth methods (AppRole, Kubernetes, OIDC) beyond the root token

---

## 3. Prerequisites

- Docker Engine + Docker Compose v2 (`docker compose version`)
- Free TCP port **8200** on the host (8201 used internally for Raft cluster traffic)
- ~1 GB free disk for the image + data

---

## 4. Target directory layout

```
openbao/
├── docker-compose.yml          # OpenBao service definition
├── config/
│   └── openbao.hcl             # server config: listener, raft storage, UI
├── data/                       # Raft storage — persisted (DO NOT COMMIT)
├── logs/                       # audit / server logs
├── IMPLEMENTATION-PLAN.md      # this document
└── README.md                   # user guide (created during implementation)
```

---

## 5. Files to create

### 5.1 `openbao/config/openbao.hcl`

```hcl
ui = true

storage "raft" {
  path    = "/openbao/data"
  node_id = "openbao-node-1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true          # dev/internal only — add TLS before exposing (see §9)
}

api_addr      = "http://127.0.0.1:8200"
cluster_addr  = "http://127.0.0.1:8201"   # REQUIRED for raft, even single-node
disable_mlock = true
```

### 5.2 `openbao/docker-compose.yml`

```yaml
services:
  openbao:
    image: openbao/openbao:latest
    container_name: openbao
    restart: unless-stopped
    ports:
      - "8200:8200"
    cap_add:
      - IPC_LOCK
    environment:
      BAO_ADDR: "http://127.0.0.1:8200"
    volumes:
      - ./config:/openbao/config
      - ./data:/openbao/data
      - ./logs:/openbao/logs
    command: server            # NB: do NOT add -config here — see §6
```

---

## 6. Critical gotcha: do **not** pass `-config` in `command`

The Alpine/UBI image entrypoint, for the `server` subcommand, already runs:

```sh
set -- bao server -config="$BAO_CONFIG_DIR" ...   # BAO_CONFIG_DIR=/openbao/config
```

So `/openbao/config` is **always** loaded. If you also write
`command: server -config=/openbao/config/openbao.hcl`, OpenBao loads the same file
**twice**, defines the listener twice, and crash-loops with:

```
Error initializing listener of type tcp: listen tcp4 0.0.0.0:8200: bind: address already in use
```

This looks like a port conflict but is not — it reproduces on *any* port. Many
online OpenBao tutorials get this wrong. **Use `command: server` with no `-config`.**
(This is the same bug pattern as HashiCorp Vault's image, which shares the entrypoint lineage.)

---

## 7. Implementation steps

1. **Create the tree**
   ```bash
   mkdir -p openbao/config openbao/data openbao/logs
   ```
2. **Write** `openbao/config/openbao.hcl` and `openbao/docker-compose.yml` (§5).
3. **Ignore data/logs in git** — append to `.gitignore`:
   ```
   openbao/data/
   openbao/logs/
   ```
4. **Start**
   ```bash
   cd openbao
   docker compose up -d
   docker compose ps                 # expect STATUS "Up"
   docker compose logs --tail 20 openbao   # expect "==> OpenBao server started!"
   ```
5. **Initialize (one time)** — production mode (5 shares, threshold 3):
   ```bash
   docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao \
     bao operator init
   ```
   Save the **unseal keys** and **root token** securely — shown only once.
   (For a throwaway test, use `-key-shares=1 -key-threshold=1`.)
6. **Unseal** — repeat until threshold met (3× for 5/3, 1× for test):
   ```bash
   docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao \
     bao operator unseal <UNSEAL_KEY>
   ```
7. **Smoke test** — enable KV v2 and round-trip a secret:
   ```bash
   docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN=<ROOT_TOKEN> openbao \
     bao secrets enable -path=secret kv-v2

   docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN=<ROOT_TOKEN> openbao \
     bao kv put secret/myapp username=admin password=s3cr3t

   docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN=<ROOT_TOKEN> openbao \
     bao kv get secret/myapp
   ```
8. **UI check** — open http://localhost:8200, log in with the root token.
9. **Write `README.md`** documenting the daily commands (start/stop/unseal/status).

---

## 8. Verification / acceptance criteria

- [ ] `docker compose ps` shows `openbao` **Up** (not restarting).
- [ ] Logs contain `==> OpenBao server started!` and no `address already in use`.
- [ ] `bao status` shows `Initialized true`, `Sealed false` after unseal.
- [ ] `bao kv get secret/myapp` returns the written values.
- [ ] Data survives `docker compose restart` (re-unseal required — expected).
- [ ] UI reachable at http://localhost:8200.

---

## 9. Production hardening (follow-up, after basic bring-up works)

- [ ] Initialize with **5 key shares / threshold 3**; store keys in a real secret manager, never git.
- [ ] **Revoke the root token** after setup; use least-privilege tokens + ACL policies.
- [ ] **Enable TLS** — set `tls_cert_file` / `tls_key_file` in the listener, or front it
  with a TLS-terminating reverse proxy (nginx / Traefik); drop `tls_disable`.
- [ ] **Auto-unseal** via cloud KMS or the Transit engine (avoids manual unseal on restart).
- [ ] **Auth methods**: AppRole (apps), Kubernetes auth (pods — ties into this repo's RKE2 cluster), OIDC (humans).
- [ ] **Audit logging**: `bao audit enable file file_path=/openbao/logs/audit.log`.
- [ ] **Raft backups** on a schedule: `bao operator raft snapshot save /openbao/data/backup.snap`.
- [ ] Consider **multi-node Raft HA** (3 or 5 nodes) for real availability.

---

## 10. Rollback

OpenBao is fully self-contained under `openbao/`:

```bash
cd openbao
docker compose down          # stop + remove container (data persists in ./data)
# full removal:
docker compose down
rm -rf openbao/              # deletes config AND data — unseal keys become useless
```

No host services or other repo components are touched.

---

## 11. Open decisions (confirm before/while implementing)

1. **Port** — plan uses the OpenBao default **8200**. Change the mapping and the
   `listener`/`api_addr` if 8200 is taken (edit all three together).
2. **Init profile** — production 5/3 vs. a quick 1/1 test instance for first bring-up.
3. **Scope now** — single node for this pass, or go straight to multi-node HA?

---

## Sources

- [OpenBao Docker image — Docker Hub](https://hub.docker.com/r/openbao/openbao)
- [OpenBao configuration docs](https://openbao.org/docs/configuration/)
- [How to install OpenBao with Docker and Raft storage — Jacar](https://jacar.es/en/how-to-install-openbao-with-docker/)
- [Self-Hosted OpenBao (HashiCorp Vault Fork) — cloudvox.at](https://cloudvox.at/a/self-hosted-openbao-hashicorp-vault-fork/)
