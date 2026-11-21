# panda-app (Spring Boot)

A Spring Boot web service that returns **"Hello, World"** plus a **Postgres
connection** status. The Postgres username/password are loaded from **OpenBao** at
startup via **Spring Cloud Vault** — never baked into the image, env, or manifests.

**Architecture (as deployed here):**

- **App** runs in the **RKE2 Kubernetes cluster**.
- **OpenBao** and **Postgres** run on the **host machine** (Docker Compose / container).
- The app reaches both over the host IP, authenticates to OpenBao with **AppRole**,
  reads `secret/panda/db`, and connects to the host Postgres with those creds.

```
   RKE2 cluster                         Host machine
  ┌──────────────┐   AppRole login     ┌──────────────┐
  │  panda-app   │ ──────────────────▶ │  OpenBao      │  secret/panda/db
  │ (Spring Boot)│ ◀── user/password ──│  :8200        │
  │              │                     ├──────────────┤
  │              │ ─── JDBC (user/pw) ▶│  Postgres     │  db: panda
  └──────────────┘                     │  :5432        │
                                       └──────────────┘
```

---

## Status

- ✅ **Deployed and verified in the RKE2 cluster** (2026-11-21). Pod `Running 1/1`; the
  in-cluster app does AppRole login to host OpenBao (`192.168.64.1:8200`), reads
  `secret/panda/db`, and connects to host Postgres (`192.168.64.1:5432`).
- ✅ Reachable at **`http://192.168.64.2/panda`** (path-based Traefik routing, no Host
  header — same style as `ingress-three-apps.yaml`) returns
  `{"message":"Hello, World","database":"connected",...}`.
- ✅ Image `panda-app:0.2.0` (linux/arm64) imported into the VM's RKE2 containerd.

### Environment specifics (this host)

- Cluster: RKE2 in a Lima VM (`rke2`), node `lima-rke2` @ `192.168.64.2`.
- Host (Mac) on the vmnet: `192.168.64.1` — used for `BAO_ADDR` and `DB_HOST`.
- kubectl: use `./rke2-mac.sh kubectl ...` (its kubeconfig), not the default context.

---

## Endpoints

| Path | Response |
|---|---|
| `GET /` | JSON: `message`, `database` (connected/error), `db_name`, `db_user_source` |
| `GET /actuator/health` | Spring actuator health (used by probes) |

Example `/`:

```json
{ "message": "Hello, World", "database": "connected", "db_name": "panda", "db_user_source": "openbao:secret/panda/db" }
```

---

## Layout

```
panda-app/
├── pom.xml                                   # Spring Boot 3.3 + Spring Cloud Vault + pg driver
├── src/main/java/com/ideascale/pandaapp/
│   ├── PandaAppApplication.java
│   └── HelloController.java                  # GET / -> hello + SELECT 1 check
├── src/main/resources/application.yml        # Vault AppRole + datasource wiring
├── Dockerfile                                # maven:3.9-temurin-21 -> temurin:21-jre
├── .dockerignore
└── deploy/
    ├── 00-namespace.yaml
    ├── 15-openbao-approle.yaml   # Secret: role-id + secret-id (placeholders; create imperatively)
    ├── 30-deployment.yaml        # app Deployment (host IP + AppRole secret refs)
    ├── 40-service.yaml
    ├── 50-ingress.yaml           # optional
    └── openbao/panda-app-policy.hcl   # least-privilege read on secret/data/panda/db
```

---

## Configuration (env vars)

| Var | Purpose |
|---|---|
| `BAO_ADDR` | OpenBao URL on the host, e.g. `http://<HOST_IP>:8200` |
| `BAO_ROLE_ID` | AppRole role_id (from the `openbao-approle` Secret) |
| `BAO_SECRET_ID` | AppRole secret_id (from the `openbao-approle` Secret) |
| `DB_HOST` | Postgres host, e.g. `<HOST_IP>` |
| `DB_PORT` | `5432` |
| `DB_NAME` | `panda` |
| `PORT` | HTTP port (default 8080) |

The DB `username`/`password` are **not** env vars — Spring Cloud Vault injects them
from `secret/panda/db`.

---

## Build

```bash
cd panda-app
docker build -t panda-app:0.2.0 .
```

Make the image available to RKE2 (no registry):

```bash
docker save panda-app:0.2.0 | sudo /var/lib/rancher/rke2/bin/ctr -a /run/k3s/containerd/containerd.sock images import -
# or push to a registry and set the image in deploy/30-deployment.yaml
```

---

## OpenBao (host) — one-time setup  ✅ already done on this host

```bash
export BAO_ADDR=http://127.0.0.1:8200   # root token for setup only
bao kv put secret/panda/db username=panda password=panda
bao policy write panda-app deploy/openbao/panda-app-policy.hcl
bao auth enable approle
bao write auth/approle/role/panda-app token_policies=panda-app token_ttl=1h token_max_ttl=4h
bao read  auth/approle/role/panda-app/role-id          # -> role_id
bao write -f auth/approle/role/panda-app/secret-id     # -> secret_id
```

> On this host the AppRole already exists; role_id/secret_id were generated and saved
> (see the session credentials file). Regenerate secret_id anytime with the last command.

---

## Deploy (when the cluster is up)

```bash
# 0. Find a HOST_IP the pods can reach (verify for your RKE2 network topology)
#    candidates on this host: 192.168.64.1 (VM gateway), 172.20.10.3 (LAN)

# 1. Namespace
kubectl apply -f deploy/00-namespace.yaml

# 2. AppRole credentials Secret (don't commit real values)
kubectl -n panda create secret generic openbao-approle \
  --from-literal=role-id=<ROLE_ID> \
  --from-literal=secret-id=<SECRET_ID>

# 3. Set the host IP in deploy/30-deployment.yaml (BAO_ADDR + DB_HOST), then:
kubectl apply -f deploy/30-deployment.yaml
kubectl apply -f deploy/40-service.yaml
kubectl apply -f deploy/50-ingress.yaml   # optional
```

---

## Verify

```bash
kubectl -n panda get pods
kubectl -n panda logs deploy/panda-app          # Spring boot up, Vault AppRole login OK
kubectl -n panda port-forward svc/panda-app 8080:80
curl localhost:8080/        # -> {"message":"Hello, World","database":"connected",...}
```

---

## Networking note (important)

Pods **cannot** use `localhost` to reach host OpenBao/Postgres. `BAO_ADDR` and
`DB_HOST` must be an address routable from inside the cluster to the host:

- If RKE2 runs in a VM, use the **host's address on the VM network** (e.g. `192.168.64.1`).
- If nodes are on the LAN, the host's **LAN IP** (e.g. `172.20.10.3`) may work.
- Confirm with a quick pod test: `kubectl -n panda run t --rm -it --image=busybox -- \
  wget -qO- http://<HOST_IP>:8200/v1/sys/health`.

Also ensure host OpenBao listens on `0.0.0.0:8200` (it does) and Postgres accepts
connections from the cluster subnet (`panda-postgres` publishes `0.0.0.0:5432`).

---

## Follow-ups

- **secret_id rotation**: AppRole secret_ids should be short-lived / rotated; consider
  a response-wrapped secret_id delivery instead of a long-lived K8s Secret.
- **TLS**: enable TLS on OpenBao and Postgres; use `https://` and `sslmode=require`.
- **Dynamic DB creds**: upgrade from static KV to the OpenBao database secrets engine.
