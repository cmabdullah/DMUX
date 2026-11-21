# panda-app

A Go web service that returns **"Hello, World"** plus a **Postgres connection**
status. Its Postgres username/password are loaded from **OpenBao** at startup
(via Kubernetes auth) — never baked into the image, env, or manifests.

See [`IMPLEMENTATION-PLAN.md`](./IMPLEMENTATION-PLAN.md) for the full design.

---

## Status

- ✅ Go app, Dockerfile, and K8s manifests implemented.
- ✅ Image **builds** (`panda-app:0.1.0`, ~20 MB distroless) — Go code compiles
  against the real OpenBao + pgx modules.
- ⏳ **Not yet deployed** — the RKE2 cluster was unreachable at build time
  (`127.0.0.1:26443` refused). Deploy steps below are ready to run once it's up.

---

## Endpoints

| Path           | Response                                                                   |
|----------------|----------------------------------------------------------------------------|
| `GET /`        | JSON: `message`, `database` (connected/error), `db_name`, `db_user_source` |
| `GET /healthz` | 200 if DB reachable, 503 otherwise (readiness probe)                       |

Example `/` response:

```json
{
  "message": "Hello, World",
  "database": "connected",
  "db_name": "panda",
  "db_user_source": "openbao:secret/panda/db"
}
```

---

## Layout

```
panda-app/
├── main.go                  # HTTP server, wires OpenBao -> Postgres
├── internal/bao/bao.go      # OpenBao K8s-auth login + KV v2 read
├── internal/db/db.go        # pgx pool connect + ping
├── go.mod / go.sum          # pinned deps (openbao/api v2.7.1, pgx v5.13.0)
├── Dockerfile               # multi-stage: golang:1.27 -> distroless
├── .dockerignore
└── deploy/
    ├── 00-namespace.yaml
    ├── 10-postgres.yaml          # Postgres Deployment + Service + PVC + bootstrap Secret
    ├── 20-serviceaccount.yaml    # SA 'panda-app' (bound in the OpenBao role)
    ├── 30-deployment.yaml
    ├── 40-service.yaml
    ├── 50-ingress.yaml           # optional
    └── openbao/panda-app-policy.hcl   # least-privilege read on secret/data/panda/db
```

---

## Configuration (env vars)

| Var            | Default                           | Purpose                                   |
|----------------|-----------------------------------|-------------------------------------------|
| `BAO_ADDR`     | `http://openbao.openbao.svc:8200` | OpenBao address                           |
| `BAO_ROLE`     | `panda-app`                       | OpenBao Kubernetes auth role              |
| `BAO_KV_MOUNT` | `secret`                          | KV v2 mount                               |
| `BAO_KV_PATH`  | `panda/db`                        | secret path holding `username`/`password` |
| `DB_HOST`      | `postgres.panda.svc`              | Postgres host                             |
| `DB_PORT`      | `5432`                            | Postgres port                             |
| `DB_NAME`      | `panda`                           | database name                             |
| `PORT`         | `8080`                            | HTTP listen port                          |

---

## Build

```bash
cd panda-app
docker build -t panda-app:0.1.0 .
```

> Requires **Go ≥ 1.25** in the builder (OpenBao's `api/auth/kubernetes/v2`
> module demands it) — the Dockerfile uses `golang:1.27`.

Make the image available to RKE2 (no registry):

```bash
docker save panda-app:0.1.0 | sudo /var/lib/rancher/rke2/bin/ctr -a /run/k3s/containerd/containerd.sock images import -
# or push to a registry and set the image in deploy/30-deployment.yaml
```

---

## Deploy (once the cluster + OpenBao are up)

```bash
# 1. OpenBao (in-cluster) — store secret + configure Kubernetes auth
bao secrets enable -path=secret kv-v2            # if not already
bao kv put secret/panda/db username=panda password=panda
bao policy write panda-app deploy/openbao/panda-app-policy.hcl
bao auth enable kubernetes
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
bao write auth/kubernetes/role/panda-app \
  bound_service_account_names=panda-app \
  bound_service_account_namespaces=panda \
  policies=panda-app ttl=1h

# 2. Namespace, Postgres, app
kubectl apply -f deploy/00-namespace.yaml
kubectl apply -f deploy/10-postgres.yaml
kubectl apply -f deploy/20-serviceaccount.yaml
kubectl apply -f deploy/30-deployment.yaml
kubectl apply -f deploy/40-service.yaml
kubectl apply -f deploy/50-ingress.yaml   # optional
```

---

## Verify

```bash
kubectl -n panda get pods
kubectl -n panda logs deploy/panda-app      # expect "connected to postgres db=panda ..."
kubectl -n panda port-forward svc/panda-app 8080:80
curl localhost:8080/        # -> {"message":"Hello, World","database":"connected",...}
```

**Proof the creds really come from OpenBao:** delete the role
(`bao delete auth/kubernetes/role/panda-app`) and restart the pod — it will fail to
start, because the password exists nowhere else.

---

## Notes / follow-ups

- **OpenBao location:** this assumes OpenBao runs **in-cluster** (Helm) so Kubernetes
  auth can validate pod tokens. The separate `../openbao/` Docker-Compose instance is
  for local dev and would need AppRole instead of K8s auth.
- **Postgres bootstrap:** Postgres needs its password at init, so it's seeded from a
  small K8s Secret with the same `panda` values. Hardening path: sync it from OpenBao
  (Agent Injector / Secrets Operator) — see plan §13.
- **Dynamic creds:** upgrade from static KV to the OpenBao **database secrets engine**
  for short-lived, per-pod Postgres credentials.
