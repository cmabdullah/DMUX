# panda-app — Go + Postgres + OpenBao on Kubernetes — Implementation Plan

A Go web service that exposes a **"Hello, World"** endpoint reporting that the
**Postgres connection is established**. The app runs as a **Docker image on
Kubernetes (RKE2)**, and its Postgres **username/password are loaded from OpenBao**
(not baked into the image or a plain K8s Secret).

- **Status:** ✅ Implemented — code + manifests written, image builds (`panda-app:0.1.0`, ~20MB). ⏳ K8s deploy pending (cluster was down at build time).
- **Date:** 2026-11-21
- **Branch:** `OpenBao`
- **DB credentials:** `POSTGRES_DB=panda`, `POSTGRES_USER=panda`, `POSTGRES_PASSWORD=panda`

---

## 1. Goal & success criteria

`GET /` returns something like:

```json
{
  "message": "Hello, World",
  "database": "connected",
  "db_name": "panda",
  "db_user_source": "openbao:secret/panda/db"
}
```

- App obtains the Postgres username/password from **OpenBao at startup** (and refreshes on token renewal).
- No DB password in the image, the Deployment YAML, or environment variables.
- Runs on Kubernetes; reachable via Service (and optionally Ingress).

---

## 2. Architecture

```
                    ┌──────────────────────────────────────────┐
                    │              RKE2 cluster                 │
                    │                                           │
  client ──HTTP──▶  │  Service ─▶ Deployment: panda-app (Go)    │
                    │                │   │                       │
                    │     (1) K8s SA │   │ (3) SQL (user/pass    │
                    │     JWT login  │   │     from OpenBao)      │
                    │                ▼   ▼                       │
                    │         ┌──────────┐   ┌───────────────┐   │
                    │         │ OpenBao  │   │  Postgres     │   │
                    │         │ (in-cl.) │   │  (panda DB)   │   │
                    │         └────┬─────┘   └───────────────┘   │
                    │   (2) reads  │ KV: secret/panda/db          │
                    │   {username, password}                     │
                    └──────────────────────────────────────────┘
```

**Secret flow**

1. Pod presents its **Kubernetes ServiceAccount JWT** to OpenBao's Kubernetes auth endpoint.
2. OpenBao validates it via the cluster TokenReview API, returns a client token scoped by policy; the app reads
   `secret/panda/db`.
3. App builds the Postgres DSN from those creds and connects.

---

## 3. Key design decisions

| Decision           | Choice                                                             | Why                                                                                                                                       |
|--------------------|--------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------|
| Where OpenBao runs | **In-cluster** (Helm `openbao/openbao`)                            | K8s auth needs TokenReview + in-cluster reachability. The existing Docker-Compose OpenBao is fine for local dev but awkward for pod auth. |
| Auth method        | **Kubernetes auth**                                                | Pods authenticate with their SA token — no static secret to distribute.                                                                   |
| Secret delivery    | **App reads directly via OpenBao Go client**                       | Most explicit/educational; no sidecar. Alternative: OpenBao Agent Injector (sidecar renders a file) — noted in §12.                       |
| Secret type        | **KV v2** static creds at `secret/panda/db`                        | Matches the fixed `panda/panda` creds. Upgrade path: OpenBao **database secrets engine** for dynamic, short-lived creds.                  |
| Postgres Go driver | **`github.com/jackc/pgx/v5`** (stdlib `database/sql` interface)    | Modern, well-maintained Postgres driver.                                                                                                  |
| OpenBao Go client  | **`github.com/openbao/openbao/api/v2`** + `api/auth/kubernetes/v2` | Official OpenBao client + K8s auth helper.                                                                                                |
| Image base         | **multi-stage → distroless/static**                                | Small, no shell, non-root.                                                                                                                |

---

## 4. Prerequisites

- RKE2 cluster reachable via `kubectl` (this repo already targets RKE2).
- A container registry the cluster can pull from (or import the image into RKE2's containerd).
- Helm 3 (for deploying OpenBao in-cluster).
- Go 1.23+ locally to build/test.

---

## 5. Repository layout (to create)

```
panda-app/
├── IMPLEMENTATION-PLAN.md        # this document
├── README.md                     # runbook (written during implementation)
├── go.mod
├── go.sum
├── main.go                       # HTTP server + OpenBao + Postgres wiring
├── internal/
│   ├── bao/bao.go                # OpenBao login (K8s auth) + read creds
│   └── db/db.go                  # Postgres connect + ping
├── Dockerfile
├── .dockerignore
└── deploy/
    ├── 00-namespace.yaml
    ├── 10-postgres.yaml          # Postgres Deployment + Service + PVC + bootstrap Secret
    ├── 20-serviceaccount.yaml    # SA for the app (bound in OpenBao role)
    ├── 30-deployment.yaml        # panda-app Deployment
    ├── 40-service.yaml           # ClusterIP Service
    └── 50-ingress.yaml           # optional Ingress (repo already uses ingress)
```

---

## 6. The Go application

### 6.1 `go.mod`

```
module github.com/ideascale/panda-app

go 1.25

require (
    github.com/jackc/pgx/v5 v5.13.0
    github.com/openbao/openbao/api/auth/kubernetes/v2 v2.7.0
    github.com/openbao/openbao/api/v2 v2.7.1
)
```

> **Resolved at implementation time** (`go mod tidy`). Note: the OpenBao
> `api/auth/kubernetes/v2` module requires **Go ≥ 1.25**, so `go.mod` uses `go 1.25`
> and the Dockerfile builder uses `golang:1.27` (§7).

### 6.2 `internal/bao/bao.go` — authenticate & read creds

```go
package bao

import (
    "context"
    "fmt"

    openbao "github.com/openbao/openbao/api/v2"
    k8sauth "github.com/openbao/openbao/api/auth/kubernetes/v2"
)

type DBCreds struct {
    Username string
    Password string
}

// FetchDBCreds logs in to OpenBao using the pod's Kubernetes ServiceAccount
// token and reads the DB credentials from a KV v2 path.
//
//   addr      - OpenBao address, e.g. http://openbao.openbao.svc:8200 (from BAO_ADDR)
//   role      - the OpenBao Kubernetes auth role (e.g. "panda-app")
//   mount     - KV v2 mount (e.g. "secret")
//   secretKey - path under the mount (e.g. "panda/db")
func FetchDBCreds(ctx context.Context, addr, role, mount, secretKey string) (DBCreds, error) {
    cfg := openbao.DefaultConfig() // honors BAO_ADDR if addr == ""
    if addr != "" {
        cfg.Address = addr
    }
    client, err := openbao.NewClient(cfg)
    if err != nil {
        return DBCreds{}, fmt.Errorf("new client: %w", err)
    }

    // Uses the SA token at /var/run/secrets/kubernetes.io/serviceaccount/token by default.
    k8s, err := k8sauth.NewKubernetesAuth(role)
    if err != nil {
        return DBCreds{}, fmt.Errorf("k8s auth: %w", err)
    }
    if _, err := client.Auth().Login(ctx, k8s); err != nil {
        return DBCreds{}, fmt.Errorf("login: %w", err)
    }

    secret, err := client.KVv2(mount).Get(ctx, secretKey)
    if err != nil {
        return DBCreds{}, fmt.Errorf("read secret: %w", err)
    }
    user, _ := secret.Data["username"].(string)
    pass, _ := secret.Data["password"].(string)
    if user == "" || pass == "" {
        return DBCreds{}, fmt.Errorf("username/password missing at %s/%s", mount, secretKey)
    }
    return DBCreds{Username: user, Password: pass}, nil
}
```

### 6.3 `internal/db/db.go` — connect & ping

```go
package db

import (
    "context"
    "fmt"

    "github.com/jackc/pgx/v5/pgxpool"
)

func Connect(ctx context.Context, host, port, name, user, pass string) (*pgxpool.Pool, error) {
    dsn := fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable",
        user, pass, host, port, name)
    pool, err := pgxpool.New(ctx, dsn)
    if err != nil {
        return nil, fmt.Errorf("pool: %w", err)
    }
    if err := pool.Ping(ctx); err != nil {
        pool.Close()
        return nil, fmt.Errorf("ping: %w", err)
    }
    return pool, nil
}
```

### 6.4 `main.go` — wire it together

```go
package main

import (
    "context"
    "encoding/json"
    "log"
    "net/http"
    "os"
    "time"

    "github.com/ideascale/panda-app/internal/bao"
    "github.com/ideascale/panda-app/internal/db"
)

func env(k, def string) string {
    if v := os.Getenv(k); v != "" {
        return v
    }
    return def
}

func main() {
    ctx := context.Background()

    baoAddr := env("BAO_ADDR", "http://openbao.openbao.svc:8200")
    baoRole := env("BAO_ROLE", "panda-app")
    kvMount := env("BAO_KV_MOUNT", "secret")
    kvPath := env("BAO_KV_PATH", "panda/db")

    dbHost := env("DB_HOST", "postgres.panda.svc")
    dbPort := env("DB_PORT", "5432")
    dbName := env("DB_NAME", "panda")

    // 1) Get DB creds from OpenBao
    creds, err := bao.FetchDBCreds(ctx, baoAddr, baoRole, kvMount, kvPath)
    if err != nil {
        log.Fatalf("openbao: %v", err)
    }

    // 2) Connect to Postgres
    cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
    defer cancel()
    pool, err := db.Connect(cctx, dbHost, dbPort, dbName, creds.Username, creds.Password)
    if err != nil {
        log.Fatalf("postgres: %v", err)
    }
    defer pool.Close()
    log.Printf("connected to postgres db=%s as user from openbao", dbName)

    // 3) HTTP handlers
    mux := http.NewServeMux()
    mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        status := "connected"
        if err := pool.Ping(r.Context()); err != nil {
            status = "error: " + err.Error()
        }
        w.Header().Set("Content-Type", "application/json")
        _ = json.NewEncoder(w).Encode(map[string]string{
            "message":        "Hello, World",
            "database":       status,
            "db_name":        dbName,
            "db_user_source": "openbao:" + kvMount + "/" + kvPath,
        })
    })
    mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
        if err := pool.Ping(r.Context()); err != nil {
            http.Error(w, "db down", http.StatusServiceUnavailable)
            return
        }
        w.WriteHeader(http.StatusOK)
    })

    addr := ":" + env("PORT", "8080")
    log.Printf("listening on %s", addr)
    log.Fatal(http.ListenAndServe(addr, mux))
}
```

> **Note on bootstrapping:** `pgxpool` connects lazily; the explicit `Ping` on
> startup fails fast if creds are wrong. If OpenBao or Postgres may be slow to come
> up, wrap steps 1–2 in a short retry loop before `log.Fatal`.

---

## 7. Dockerfile (multi-stage, distroless)

```dockerfile
# ---- build ----
FROM golang:1.27 AS build   # Go >= 1.25 required by OpenBao's k8s-auth module
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /panda-app ./

# ---- runtime ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /panda-app /panda-app
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/panda-app"]
```

`.dockerignore`:

```
.git
deploy/
*.md
```

**Build & make available to RKE2:**

```bash
cd panda-app
docker build -t panda-app:0.1.0 .
# If using a registry:
docker tag panda-app:0.1.0 <registry>/panda-app:0.1.0 && docker push <registry>/panda-app:0.1.0
# Or import straight into RKE2 containerd (no registry):
docker save panda-app:0.1.0 | sudo k3s ctr images import -   # RKE2: /var/lib/rancher/rke2/bin/ctr
```

---

## 8. Postgres in Kubernetes — `deploy/10-postgres.yaml`

A minimal single-replica Postgres with a PVC. Postgres needs its password at
init time (chicken/egg), so it is bootstrapped from a small K8s Secret created
from the same `panda` values. (In a hardened setup, sync this from OpenBao via the
Agent Injector or the Secrets Operator instead — see §12.)

```yaml
apiVersion: v1
kind: Namespace
metadata: { name: panda }
---
apiVersion: v1
kind: Secret
metadata: { name: postgres-bootstrap, namespace: panda }
type: Opaque
stringData:
  POSTGRES_DB: panda
  POSTGRES_USER: panda
  POSTGRES_PASSWORD: panda
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: postgres-data, namespace: panda }
spec:
  accessModes: [ "ReadWriteOnce" ]
  resources: { requests: { storage: 2Gi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: postgres, namespace: panda }
spec:
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      containers:
        - name: postgres
          image: postgres:16
          envFrom:
            - secretRef: { name: postgres-bootstrap }
          ports: [ { containerPort: 5432 } ]
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data }
          readinessProbe:
            exec: { command: [ "pg_isready","-U","panda" ] }
            initialDelaySeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: postgres-data }
---
apiVersion: v1
kind: Service
metadata: { name: postgres, namespace: panda }
spec:
  selector: { app: postgres }
  ports: [ { port: 5432, targetPort: 5432 } ]
```

---

## 9. App Kubernetes manifests

### 9.1 `deploy/20-serviceaccount.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: panda-app
  namespace: panda
```

### 9.2 `deploy/30-deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: panda-app, namespace: panda }
spec:
  replicas: 1
  selector: { matchLabels: { app: panda-app } }
  template:
    metadata: { labels: { app: panda-app } }
    spec:
      serviceAccountName: panda-app          # identity OpenBao binds its role to
      containers:
        - name: panda-app
          image: panda-app:0.1.0             # or <registry>/panda-app:0.1.0
          ports: [ { containerPort: 8080 } ]
          env:
            - { name: BAO_ADDR,  value: "http://openbao.openbao.svc:8200" }
            - { name: BAO_ROLE,  value: "panda-app" }
            - { name: BAO_KV_MOUNT, value: "secret" }
            - { name: BAO_KV_PATH,  value: "panda/db" }
            - { name: DB_HOST,   value: "postgres.panda.svc" }
            - { name: DB_PORT,   value: "5432" }
            - { name: DB_NAME,   value: "panda" }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 5
```

### 9.3 `deploy/40-service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata: { name: panda-app, namespace: panda }
spec:
  selector: { app: panda-app }
  ports: [ { port: 80, targetPort: 8080 } ]
```

### 9.4 `deploy/50-ingress.yaml` (optional — repo already uses ingress)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: panda-app
  namespace: panda
spec:
  rules:
    - host: panda.local            # adjust to your ingress setup
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: panda-app, port: { number: 80 } }
```

---

## 10. OpenBao configuration (the secret + K8s auth)

> Assumes OpenBao is deployed **in-cluster** in namespace `openbao` and reachable at
> `http://openbao.openbao.svc:8200`. Run `bao` commands via
> `kubectl exec -n openbao <openbao-pod> -- ...` or a local CLI with `BAO_ADDR` set
> and `BAO_TOKEN` = root (for setup only).

**10.1 Store the DB credentials (KV v2):**

```bash
bao secrets enable -path=secret kv-v2            # if not already enabled
bao kv put secret/panda/db username=panda password=panda
```

**10.2 Policy granting read on just that path — `panda-app-policy.hcl`:**

```hcl
path "secret/data/panda/db" {
  capabilities = ["read"]
}
```

```bash
bao policy write panda-app panda-app-policy.hcl
```

**10.3 Enable & configure Kubernetes auth:**

```bash
bao auth enable kubernetes

# From inside a pod, OpenBao can auto-discover these; otherwise set explicitly:
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
```

**10.4 Bind the app's ServiceAccount to the policy via a role:**

```bash
bao write auth/kubernetes/role/panda-app \
  bound_service_account_names=panda-app \
  bound_service_account_namespaces=panda \
  policies=panda-app \
  ttl=1h
```

Now a pod running as ServiceAccount `panda-app` in namespace `panda` can log in to
OpenBao and read `secret/panda/db` — nothing else.

---

## 11. Deployment sequence

```bash
# 0. Deploy OpenBao in-cluster (Helm) if not already there
helm repo add openbao https://openbao.github.io/openbao-helm && helm repo update
helm install openbao openbao/openbao -n openbao --create-namespace
#   then: init + unseal the openbao-0 pod (see openbao/README.md flow, using bao)

# 1. OpenBao: store secret + configure K8s auth (§10)
# 2. Postgres
kubectl apply -f panda-app/deploy/10-postgres.yaml
# 3. App SA, Deployment, Service
kubectl apply -f panda-app/deploy/20-serviceaccount.yaml
kubectl apply -f panda-app/deploy/30-deployment.yaml
kubectl apply -f panda-app/deploy/40-service.yaml
# 4. (optional) Ingress
kubectl apply -f panda-app/deploy/50-ingress.yaml
```

---

## 12. Verification / acceptance criteria

- [ ] `kubectl -n panda get pods` → `postgres` and `panda-app` both `Running`/`Ready`.
- [ ] App logs show `connected to postgres db=panda as user from openbao` and no auth errors.
- [ ] `kubectl -n panda port-forward svc/panda-app 8080:80` then `curl localhost:8080/`
  returns `"message":"Hello, World"` and `"database":"connected"`.
- [ ] Removing/renaming the OpenBao role makes the app fail to start → proves creds
  really come from OpenBao, not the manifest.
- [ ] No DB password present in the image, Deployment YAML, or app env.

**Alternative secret-delivery (no app-side Bao code) — OpenBao Agent Injector:**
annotate the Deployment (`vault.hashicorp.com/agent-inject`, role, secret path); a
sidecar renders creds to `/vault/secrets/db` and the app just reads the file. Trades
app simplicity for a sidecar + annotations. Direct-client (above) is the default here.

---

## 13. Security hardening (follow-ups)

- [ ] Replace static KV creds with the **OpenBao database secrets engine** (dynamic,
  short-TTL Postgres roles; app gets a fresh user per lease).
- [ ] Enable **TLS** on OpenBao and Postgres; set `sslmode=require` in the DSN.
- [ ] Set resource `requests`/`limits`; run app as non-root (distroless `nonroot` already).
- [ ] NetworkPolicies: only `panda-app` may reach Postgres and OpenBao.
- [ ] Don't store the Postgres bootstrap password in a plain K8s Secret long-term —
  sync from OpenBao (injector/operator) or rotate.
- [ ] Token renewal: add a goroutine to renew the OpenBao token lease (the K8s auth
  helper returns a renewable token).

---

## 14. Rollback

```bash
kubectl delete -f panda-app/deploy/ --ignore-not-found
# OpenBao cleanup (optional):
bao delete auth/kubernetes/role/panda-app
bao policy delete panda-app
bao kv delete secret/panda/db
```

---

## 15. Open decisions (confirm before implementing)

1. **OpenBao location** — deploy in-cluster via Helm (recommended, assumed here) vs.
   reuse the existing Docker-Compose instance (needs the app to reach the host and a
   non-K8s auth method like AppRole).
2. **Image distribution** — push to a registry vs. import into RKE2 containerd directly.
3. **Secret delivery** — direct Go client (assumed) vs. OpenBao Agent Injector sidecar.
4. **Postgres** — the in-cluster Deployment above vs. the existing `panda-postgres`
   container you already have running.
5. **Credential model** — static KV (assumed, matches `panda/panda`) vs. dynamic
   database secrets engine.

---

## Sources

- [OpenBao Go client — pkg.go.dev `github.com/openbao/openbao/api/v2`](https://pkg.go.dev/github.com/openbao/openbao/v2)
- [OpenBao Kubernetes auth method](https://openbao.org/docs/auth/kubernetes/)
- [OpenBao client libraries](https://openbao.org/docs/api/libraries/)
- [OpenBao developer quick start](https://openbao.org/docs/2.6.x/get-started/developer-qs/)
- [pgx — PostgreSQL driver for Go](https://github.com/jackc/pgx)
