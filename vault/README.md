# HashiCorp Vault — Self-Hosted (Docker Compose)

A self-hosted HashiCorp Vault running in Docker with the integrated **Raft** storage
backend (persistent, HA-capable). This guide covers starting, initializing,
unsealing, and using Vault.

- **UI / API:** http://localhost:8220
- **Storage:** Raft (data persisted in `./data`)
- **Image:** `hashicorp/vault:latest`

---

## 1. Layout

```
vault/
├── docker-compose.yml      # Vault service definition
├── config/
│   └── vault.hcl           # Vault server config (listener, storage, UI)
├── data/                   # Raft storage — real secrets live here (DO NOT COMMIT)
├── logs/                   # Audit / server logs
└── README.md               # This guide
```

---

## 2. Start the server

```bash
cd vault
docker compose up -d
docker compose ps            # STATUS should be "Up"
docker compose logs -f vault # watch logs (Ctrl-C to stop watching)
```

A healthy start ends with `==> Vault server started!` in the logs.

---

## 3. Initialize (one time only)

Vault starts **uninitialized and sealed**. Initialize it **once** to generate the
unseal keys and the root token.

**Production (recommended) — 5 key shares, any 3 required to unseal:**

```bash
docker exec -e VAULT_ADDR=http://127.0.0.1:8220 vault \
  vault operator init
```

**Quick test — single key:**

```bash
docker exec -e VAULT_ADDR=http://127.0.0.1:8220 vault \
  vault operator init -key-shares=1 -key-threshold=1
```

> ⚠️ **Save the unseal key(s) and the root token immediately and securely.**
> They are shown **only once** and cannot be recovered. Without them your data is
> permanently inaccessible.

---

## 4. Unseal

Vault is **sealed on every start/restart** and must be unsealed before use. Run the
unseal command once per key until the threshold is met (e.g. 3 times for the default
5/3 setup, 1 time for the test setup):

```bash
docker exec -e VAULT_ADDR=http://127.0.0.1:8220 vault \
  vault operator unseal <UNSEAL_KEY>
```

Unsealed when `Sealed  false` appears in the output.

> To avoid manual unsealing on every restart, configure **auto-unseal**
> (cloud KMS or the Transit secrets engine). See section 9.

---

## 5. Log in

```bash
docker exec -it -e VAULT_ADDR=http://127.0.0.1:8220 vault \
  vault login <ROOT_TOKEN>
```

Or set the token for a single command via `-e VAULT_TOKEN=<ROOT_TOKEN>`.

---

## 6. Store and read secrets (KV v2)

```bash
# enable the key/value engine (one time)
docker exec -e VAULT_ADDR=http://127.0.0.1:8220 -e VAULT_TOKEN=<ROOT_TOKEN> vault \
  vault secrets enable -path=secret kv-v2

# write a secret
docker exec -e VAULT_ADDR=http://127.0.0.1:8220 -e VAULT_TOKEN=<ROOT_TOKEN> vault \
  vault kv put secret/myapp username=admin password=s3cr3t

# read it back
docker exec -e VAULT_ADDR=http://127.0.0.1:8220 -e VAULT_TOKEN=<ROOT_TOKEN> vault \
  vault kv get secret/myapp

# read a single field
docker exec -e VAULT_ADDR=http://127.0.0.1:8220 -e VAULT_TOKEN=<ROOT_TOKEN> vault \
  vault kv get -field=password secret/myapp
```

You can also use the web UI at **http://localhost:8220** — log in with the root token.

---

## 7. Everyday commands

```bash
cd vault

docker compose up -d        # start
docker compose stop         # stop (keeps data)
docker compose down         # stop + remove container (data persists in ./data)
docker compose logs -f vault
docker compose restart vault

# status (works even when sealed)
docker exec -e VAULT_ADDR=http://127.0.0.1:8220 vault vault status
```

**Tip:** to avoid repeating `-e VAULT_ADDR=...`, open a shell inside the container:

```bash
docker exec -it vault sh
export VAULT_ADDR=http://127.0.0.1:8220
export VAULT_TOKEN=<ROOT_TOKEN>
vault status
```

---

## 8. Configuration reference (`config/vault.hcl`)

```hcl
ui = true

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-node-1"
}

listener "tcp" {
  address     = "0.0.0.0:8220"
  tls_disable = true          # dev/internal only — see section 9
}

api_addr      = "http://127.0.0.1:8220"
cluster_addr  = "http://127.0.0.1:8221"
disable_mlock = true
```

> **Why `command: server` (not `server -config=...`)** in `docker-compose.yml`:
> the official image's entrypoint already appends `-config=/vault/config`.
> Passing `-config` again loads the same file twice, which defines the listener
> twice and fails with `bind: address already in use`. Let the entrypoint handle it.

---

## 9. Production checklist

- [ ] **Initialize with 5 key shares / threshold 3** (not the single-key test mode).
- [ ] **Store unseal keys and root token** in a secure secret manager; never in git.
- [ ] **Revoke the root token** after initial setup; use least-privilege tokens/policies.
- [ ] **Enable TLS** — set `tls_cert_file` / `tls_key_file` in the listener, or put a
      TLS-terminating reverse proxy (nginx/Traefik) in front. Remove `tls_disable`.
- [ ] **Enable auto-unseal** (cloud KMS or Transit) so restarts don't require manual unsealing.
- [ ] **Enable an auth method** (AppRole for apps, Kubernetes auth for pods, OIDC for humans).
- [ ] **Write ACL policies** granting only the paths each consumer needs.
- [ ] **Enable audit logging:**
      `vault audit enable file file_path=/vault/logs/audit.log`
- [ ] **Back up Raft** on a schedule:
      `vault operator raft snapshot save /vault/data/backup.snap`
- [ ] **Add `vault/data/` and `vault/logs/` to `.gitignore`.**

---

## 10. Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `bind: address already in use` (even on a free port) | `command:` passes `-config` and the entrypoint also adds it → listener loaded twice. Use `command: server`. |
| Container restart-loops immediately | Check `docker compose logs vault` — usually bad HCL or a storage/permission error. |
| `Error initializing storage ... no such file or directory` | `./data` not mounted, or Vault can't write it. Ensure the `./data` volume is mounted (and writable by UID 100). |
| `permission denied` on `/vault/data` | `sudo chown -R 100:1000 ./data` (Vault runs as UID 100). |
| `Vault is sealed` after restart | Expected — run `vault operator unseal` again, or configure auto-unseal. |
| `server not yet initialized` | Run `vault operator init` once, then unseal. |
| UI/API unreachable | Confirm the `8220:8220` port mapping and that the listener binds `0.0.0.0`, not `127.0.0.1`. |

---

## Reference

- Vault docs: https://developer.hashicorp.com/vault/docs
- Docker image: https://hub.docker.com/r/hashicorp/vault
- Integrated (Raft) storage: https://developer.hashicorp.com/vault/docs/configuration/storage/raft
