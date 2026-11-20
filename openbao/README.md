# OpenBao — Self-Hosted (Docker Compose)

Self-hosted [OpenBao](https://openbao.org) (the Linux Foundation fork of HashiCorp
Vault) running in Docker with integrated **Raft** storage (persistent, HA-capable).

- **UI / API:** http://localhost:8200
- **Storage:** Raft (data persisted in `./data`)
- **Image:** `openbao/openbao:latest` (verified running: v2.7.3)
- **CLI inside container:** `bao`

> OpenBao uses the same HCL config and API as Vault, but the binary is `bao`,
> env vars are `BAO_*`, and in-container paths are under `/openbao`.

---

## 1. Layout

```
openbao/
├── docker-compose.yml      # OpenBao service (command: server — see §6 below)
├── config/
│   └── openbao.hcl         # listener, raft storage, UI
├── data/                   # Raft storage — real secrets live here (DO NOT COMMIT)
├── logs/                   # audit / server logs
├── IMPLEMENTATION-PLAN.md  # the plan this was built from
└── README.md               # this guide
```

`openbao/data/` and `openbao/logs/` are in `.gitignore`.

---

## 2. Start

```bash
cd openbao
docker compose up -d
docker compose ps                        # STATUS should be "Up"
docker compose logs -f openbao           # expect "==> OpenBao server started!"
```

---

## 3. Initialize (one time only)

OpenBao starts **uninitialized and sealed**. Initialize **once**:

```bash
docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao \
  bao operator init
```

This prints **5 unseal keys** and a **root token**.

> ⚠️ **Save the unseal keys and root token immediately and securely** — they are
> shown only once and cannot be recovered. Losing them = losing the data.

(Quick throwaway test instead: add `-key-shares=1 -key-threshold=1`.)

---

## 4. Unseal (required after every start/restart)

Run once per key until the threshold is met (3× for the default 5/3 setup):

```bash
docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao \
  bao operator unseal <UNSEAL_KEY>
```

Unsealed when the output shows `Sealed  false`.

---

## 5. Use it

```bash
ADDR="-e BAO_ADDR=http://127.0.0.1:8200"
TOKEN="-e BAO_TOKEN=<ROOT_TOKEN>"

# enable the KV v2 engine (one time)
docker exec $ADDR $TOKEN openbao bao secrets enable -path=secret kv-v2

# write / read a secret
docker exec $ADDR $TOKEN openbao bao kv put secret/myapp username=admin password=s3cr3t
docker exec $ADDR $TOKEN openbao bao kv get secret/myapp
docker exec $ADDR $TOKEN openbao bao kv get -field=password secret/myapp
```

Or use the **web UI** at http://localhost:8200 and log in with the root token.

Tip — interactive shell inside the container:

```bash
docker exec -it openbao sh
export BAO_ADDR=http://127.0.0.1:8200
export BAO_TOKEN=<ROOT_TOKEN>
bao status
```

---

## 6. Everyday commands

```bash
cd openbao
docker compose up -d           # start
docker compose stop            # stop (keeps data)
docker compose down            # stop + remove container (data persists in ./data)
docker compose restart openbao
docker compose logs -f openbao
docker exec -e BAO_ADDR=http://127.0.0.1:8200 openbao bao status
```

---

## 7. Important gotcha (already handled here)

`docker-compose.yml` uses `command: server` — **not** `server -config=...`.

The image entrypoint already appends `-config=/openbao/config` for the `server`
command. Passing `-config` again loads the same file twice, defines the listener
twice, and crash-loops with `bind: address already in use` (on *any* port, not just
8200). Leave `command: server` as-is.

---

## 8. Production checklist

- [ ] Initialize with **5 key shares / threshold 3** (done); store keys in a secret manager, never git.
- [ ] **Revoke the root token** after setup; use least-privilege tokens + ACL policies.
- [ ] **Enable TLS** — set `tls_cert_file` / `tls_key_file` in the listener, or a TLS reverse proxy in front; remove `tls_disable`.
- [ ] **Auto-unseal** (cloud KMS or Transit) so restarts don't need manual unsealing.
- [ ] **Auth methods**: AppRole (apps), Kubernetes auth (pods — ties into this repo's RKE2 cluster), OIDC (humans).
- [ ] **Audit logging:** `bao audit enable file file_path=/openbao/logs/audit.log`
- [ ] **Raft backups:** `bao operator raft snapshot save /openbao/data/backup.snap`

---

## 9. Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `bind: address already in use` (even on a free port) | `command:` passed `-config` and the entrypoint also adds it → duplicate listener. Use `command: server`. |
| `failed to connect to the docker API ... orbstack` | OrbStack/Docker daemon not running. Start it: `orb start`. |
| Host port 8200 in use | A leftover container (e.g. an old `vault`) may hold it: `docker rm -f <name>`. |
| `OpenBao is sealed` after restart | Expected — run `bao operator unseal` again, or configure auto-unseal. |
| `server not yet initialized` | Run `bao operator init` once, then unseal. |
| `permission denied` on `/openbao/data` | `sudo chown -R 100:1000 ./data` (container runs as UID 100). |

---

## Reference

- OpenBao docs: https://openbao.org/docs/
- Docker image: https://hub.docker.com/r/openbao/openbao
- Raft storage: https://openbao.org/docs/configuration/storage/raft/
