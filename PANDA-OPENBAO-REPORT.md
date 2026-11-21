# panda-app + OpenBao on RKE2 — Detailed Implementation Report

**Date:** 2026-11-21
**Scope:** A Spring Boot app running in an RKE2 (Lima VM) Kubernetes cluster that loads
its Postgres credentials from **OpenBao** and connects to **Postgres** — both OpenBao and
Postgres running on the **host machine**.

> **Security note:** real tokens, unseal keys, `role_id`, and `secret_id` are **not**
> reproduced here. They live in gitignored files (`openbao/CREDENTIALS.local.md`,
> `panda-app/deploy/APPROLE.local.md`). All examples below use `<PLACEHOLDER>` values.

---

## 0. End-state architecture

```
                 HOST MACHINE (macOS, 192.168.64.1 on vmnet)
   ┌──────────────────────────────────────────────────────────────┐
   │   Docker (OrbStack)                                           │
   │   ┌─────────────────────┐        ┌──────────────────────┐    │
   │   │ OpenBao  :8200       │        │ panda-postgres :5432 │    │
   │   │  - raft storage      │        │  db=panda            │    │
   │   │  - KV v2: secret/    │        │  user=panda          │    │
   │   │    panda/db          │        └──────────────────────┘    │
   │   │  - AppRole auth      │                                     │
   │   └─────────▲───────────┘                                     │
   └─────────────┼────────────────────────────────────────────────┘
                 │  (1) AppRole login + (2) read KV      (3) JDBC
                 │  http://192.168.64.1:8200             192.168.64.1:5432
   ┌─────────────┼────────────────────────────────────────────────┐
   │   RKE2 cluster (Lima VM, node 192.168.64.2)                   │
   │   ┌─────────┴──────────────────────────────────┐             │
   │   │ Deployment: panda-app (Spring Boot)         │             │
   │   │  env: BAO_ADDR, DB_HOST = 192.168.64.1      │             │
   │   │  env: BAO_ROLE_ID / BAO_SECRET_ID  ◀── Secret: openbao-approle
   │   │  Spring Cloud Vault → login → read secret   │             │
   │   └──────────────────▲──────────────────────────┘             │
   │   Service panda-app (ClusterIP :80)                           │
   │   Ingress (Traefik) path /panda ── StripPrefix ──▶ app "/"    │
   └──────────────────────┼───────────────────────────────────────┘
                          │  http://192.168.64.2/panda
                       (browser / curl)
```

**Access endpoint:** `http://192.168.64.2/panda`

---

## 1. How OpenBao is configured

OpenBao runs as a Docker Compose service on the host (`openbao/` in the repo).

### 1.1 Compose + server config

`openbao/docker-compose.yml` (key parts): image `openbao/openbao:latest`, `command: server`
(**no** `-config` flag — the image entrypoint already appends `-config=/openbao/config`;
passing it again double-loads the listener and crash-loops with a false
`bind: address already in use`), `cap_add: IPC_LOCK`, port `8200:8200`, volumes for
`config/`, `data/`, `logs/`.

`openbao/config/openbao.hcl`:

```hcl
ui = true
storage "raft" {               # integrated storage; file backend was removed in OpenBao 2.7
  path    = "/openbao/data"
  node_id = "openbao-node-1"
}
listener "tcp" {
  address     = "0.0.0.0:8200" # 0.0.0.0 so the cluster VM can reach it
  tls_disable = true           # DEV ONLY
}
api_addr      = "http://127.0.0.1:8200"
cluster_addr  = "http://127.0.0.1:8201"   # required for raft, even single-node
disable_mlock = true
```

### 1.2 One-time bring-up sequence (what was run)

| Step           | Command (via `bao` CLI in the container)                                                       | Effect                                    |
|----------------|------------------------------------------------------------------------------------------------|-------------------------------------------|
| Init           | `bao operator init` (5 shares / threshold 3)                                                   | Generates 5 unseal keys + root token      |
| Unseal         | `bao operator unseal <key>` ×3                                                                 | Moves from sealed → unsealed              |
| Enable KV      | `bao secrets enable -path=secret kv-v2`                                                        | KV v2 engine mounted at `secret/`         |
| Store secret   | `bao kv put secret/panda/db username=panda password=panda`                                     | DB creds stored                           |
| Policy         | `bao policy write panda-app <hcl>`                                                             | Read-only on `secret/data/panda/db`       |
| Enable AppRole | `bao auth enable approle`                                                                      | AppRole auth method mounted at `approle/` |
| Create role    | `bao write auth/approle/role/panda-app token_policies=panda-app token_ttl=1h token_max_ttl=4h` | Binds a login role to the policy          |
| role_id        | `bao read auth/approle/role/panda-app/role-id`                                                 | Stable role identifier                    |
| secret_id      | `bao write -f auth/approle/role/panda-app/secret-id`                                           | Credential (like a password)              |

Policy (`panda-app/deploy/openbao/panda-app-policy.hcl`) — least privilege:

```hcl
path "secret/data/panda/db" {
  capabilities = ["read"]
}
```

> **Why AppRole, not Kubernetes auth?** Kubernetes auth requires OpenBao to validate pod
> ServiceAccount tokens via the cluster's TokenReview API. Since OpenBao lives **outside**
> the cluster (on the host), AppRole is the correct, self-contained choice: the pod presents
> a `role_id` + `secret_id` and gets a scoped token.

---

## 2. OpenBao APIs used — use cases, payloads, request/response

OpenBao exposes the Vault-compatible HTTP API under `/v1/...`. Below are the endpoints
actually exercised, with **real** (redacted) responses captured from this instance.

### 2.1 Health check — liveness probe for the pod→host path

- **Use case:** confirm pods can reach OpenBao and it's unsealed/active.
- `GET /v1/sys/health`

```json
{
  "initialized": true,
  "sealed": false,
  "standby": false,
  "version": "2.7.3",
  "cluster_name": "vault-cluster-ab194ed2",
  "cluster_id": "d2dfecdb-...-75f07fbad901"
}
```

### 2.2 AppRole login — the app authenticates

- **Use case:** the app exchanges `role_id`+`secret_id` for a short-lived token.
- `POST /v1/auth/approle/login`
- **Request body:**

```json
{
  "role_id": "<ROLE_ID>",
  "secret_id": "<SECRET_ID>"
}
```

- **Response (token/accessor redacted):**

```json
{
  "auth": {
    "client_token": "<REDACTED>",
    "accessor": "<REDACTED>",
    "token_policies": [
      "default",
      "panda-app"
    ],
    "metadata": {
      "role_name": "panda-app"
    },
    "lease_duration": 3600,
    "renewable": true,
    "token_type": "service",
    "orphan": true,
    "num_uses": 0
  }
}
```

The `client_token` (TTL 3600s, renewable) is used as `X-Vault-Token` for subsequent calls.

### 2.3 Read KV v2 secret — the app fetches DB creds

- **Use case:** read `username`/`password` for Postgres.
- `GET /v1/secret/data/panda/db`  (note the `data/` segment — that's KV **v2**)
- **Header:** `X-Vault-Token: <client_token>`
- **Response:**

```json
{
  "data": {
    "data": {
      "password": "panda",
      "username": "panda"
    },
    "metadata": {
      "version": 1,
      "created_time": "2026-11-21T05:01:33Z",
      "destroyed": false
    }
  }
}
```

The actual values are at `.data.data` (KV v2 nests payload under `data`, metadata alongside).

### 2.4 Setup-time endpoints (invoked by the `bao` CLI, for reference)

| Endpoint                                    | Method | Payload (abridged)                                                     | Purpose            |
|---------------------------------------------|--------|------------------------------------------------------------------------|--------------------|
| `/v1/sys/init`                              | PUT    | `{"secret_shares":5,"secret_threshold":3}`                             | Initialize         |
| `/v1/sys/unseal`                            | PUT    | `{"key":"<unseal-key>"}`                                               | Unseal (×3)        |
| `/v1/sys/mounts/secret`                     | POST   | `{"type":"kv","options":{"version":"2"}}`                              | Enable KV v2       |
| `/v1/secret/data/panda/db`                  | POST   | `{"data":{"username":"panda","password":"panda"}}`                     | Write secret       |
| `/v1/sys/policies/acl/panda-app`            | PUT    | `{"policy":"path \"secret/data/panda/db\" {capabilities=[\"read\"]}"}` | Write policy       |
| `/v1/sys/auth/approle`                      | POST   | `{"type":"approle"}`                                                   | Enable AppRole     |
| `/v1/auth/approle/role/panda-app`           | POST   | `{"token_policies":"panda-app","token_ttl":"1h"}`                      | Create role        |
| `/v1/auth/approle/role/panda-app/role-id`   | GET    | —                                                                      | Read role_id       |
| `/v1/auth/approle/role/panda-app/secret-id` | POST   | `{}`                                                                   | Generate secret_id |

> In the app, **steps 2.2 and 2.3 are performed by Spring Cloud Vault automatically** at
> startup (configured in `application.yml`); the app code never calls these directly.

---

## 3. How the Docker image was prepared and moved to RKE2

### 3.1 Build (multi-stage, inside Docker — no local JDK/Maven needed)

`panda-app/Dockerfile`:

```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build      # compile + package
WORKDIR /src
COPY pom.xml .
RUN mvn -q -B dependency:go-offline             # cached layer (deps)
COPY src ./src
RUN mvn -q -B clean package -DskipTests         # -> target/panda-app.jar

FROM eclipse-temurin:21-jre                      # small runtime
WORKDIR /app
COPY --from=build /src/target/panda-app.jar /app/app.jar
EXPOSE 8080
USER 1000:1000
ENTRYPOINT ["java","-jar","/app/app.jar"]
```

```bash
docker build -t panda-app:0.2.0 .     # produced linux/arm64 image (~544MB), matches VM arch
```

### 3.2 Move into the RKE2 node's containerd

RKE2 does **not** use the host Docker; it has its own containerd inside the Lima VM. The
image was exported and imported directly (no registry):

```bash
# 1. export from host Docker
docker save panda-app:0.2.0 -o panda-app.tar          # ~139MB

# 2. stream into the VM's RKE2 containerd (namespace k8s.io)
cat panda-app.tar | limactl shell rke2 sudo \
  /var/lib/rancher/rke2/bin/ctr \
  -a /run/k3s/containerd/containerd.sock -n k8s.io images import -

# 3. verify
limactl shell rke2 sudo /var/lib/rancher/rke2/bin/ctr \
  -a /run/k3s/containerd/containerd.sock -n k8s.io images ls | grep panda-app
# docker.io/library/panda-app:0.2.0  ... 139.2 MiB linux/arm64
```

The Deployment uses `image: panda-app:0.2.0` with `imagePullPolicy: IfNotPresent`, so the
kubelet uses the locally-imported image instead of pulling from a registry.

---

## 4. How the OpenBao key/value is loaded into Kubernetes — full flow

**Key principle:** the **database credentials are never stored in Kubernetes.** Only the
AppRole *bootstrap* credentials (`role_id`, `secret_id`) live in a K8s Secret; the actual
`username`/`password` are fetched from OpenBao at runtime and held only in the app's memory.

### 4.1 Sequence diagram

```
 Operator (host)         Kubernetes (RKE2)            panda-app pod            OpenBao (host)        Postgres (host)
     │                        │                            │                       │                     │
     │ bao kv put secret/panda/db username/password ───────────────────────────▶  │ store KV v2         │
     │ bao write approle role + get role_id/secret_id ─────────────────────────▶  │                     │
     │                        │                            │                       │                     │
     │ kubectl create secret openbao-approle               │                       │                     │
     │   (role-id, secret-id) ─▶ [K8s Secret]              │                       │                     │
     │                        │                            │                       │                     │
     │ kubectl apply deployment                            │                       │                     │
     │                        │ schedules pod ───────────▶ │ start                 │                     │
     │                        │ injects env BAO_ROLE_ID /  │                       │                     │
     │                        │ BAO_SECRET_ID from Secret ▶│                       │                     │
     │                        │                            │ (1) POST /v1/auth/approle/login ─────────▶  │
     │                        │                            │     {role_id, secret_id}                    │
     │                        │                            │ ◀── client_token (TTL 1h) ───────────────   │
     │                        │                            │ (2) GET /v1/secret/data/panda/db ────────▶  │
     │                        │                            │     X-Vault-Token: client_token             │
     │                        │                            │ ◀── {username:panda, password:panda} ─────  │
     │                        │                            │ (3) JDBC connect user/pass ───────────────────────────▶ connected
     │                        │                            │ GET / → {"database":"connected"}            │
```

### 4.2 Where each piece is configured

- **K8s Secret** (`panda` namespace), created imperatively so real values aren't committed:

  ```bash
  kubectl -n panda create secret generic openbao-approle \
    --from-literal=role-id=<ROLE_ID> \
    --from-literal=secret-id=<SECRET_ID>
  ```

- **Deployment env** (`panda-app/deploy/30-deployment.yaml`):

  ```yaml
  env:
    - { name: BAO_ADDR, value: "http://192.168.64.1:8200" }
    - { name: DB_HOST,  value: "192.168.64.1" }
    - { name: DB_PORT,  value: "5432" }
    - { name: DB_NAME,  value: "panda" }
    - name: BAO_ROLE_ID
      valueFrom: { secretKeyRef: { name: openbao-approle, key: role-id } }
    - name: BAO_SECRET_ID
      valueFrom: { secretKeyRef: { name: openbao-approle, key: secret-id } }
  ```

- **App config** (`panda-app/src/main/resources/application.yml`) — Spring Cloud Vault does
  the login + read, maps the secret keys to datasource properties:

  ```yaml
  spring:
    config:
      import: "vault://secret/panda/db"      # -> provides `username`, `password`
    cloud:
      vault:
        uri: ${BAO_ADDR}
        authentication: APPROLE
        app-role:
          role-id: ${BAO_ROLE_ID}
          secret-id: ${BAO_SECRET_ID}
        fail-fast: true                      # crash startup if OpenBao unreachable
    datasource:
      url: jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}
      username: ${username}                   # injected from OpenBao
      password: ${password}                   # injected from OpenBao
  ```

### 4.3 Ingress routing (how the browser reaches it)

`panda-app/deploy/50-ingress.yaml` — path-based on the default host (matching
`ingress-three-apps.yaml`), with a StripPrefix middleware because the app serves at `/`:

```
http://192.168.64.2/panda  ──▶ Traefik ──▶ StripPrefix(/panda) ──▶ Service panda-app:80 ──▶ pod :8080 "/"
```

---

## 5. Things likely NOT on your radar yet (gaps & risks)

Ordered roughly by importance.

### Security

1. **secret_id never expires.** The role was created with `secret_id_ttl=0` → the bootstrap
   credential is effectively permanent. Rotate it; use short TTLs and/or **response-wrapped**
   secret_id delivery (`-wrap-ttl`) so a leaked K8s Secret has limited value.
2. **K8s Secrets are base64, not encrypted** unless **etcd encryption-at-rest** is enabled.
   Anyone with cluster read access can decode `openbao-approle`.
3. **No TLS anywhere.** OpenBao (`tls_disable`), Postgres (`sslmode=disable`), and the
   ingress are plaintext. Credentials traverse the network in the clear. Enable TLS +
   `sslmode=require` before anything real.
4. **Unseal keys + root token are in a scratchpad / local files.** That's a full compromise
   path. Move to a proper custody solution; **revoke the root token** after setup.
5. **`panda` Postgres user is a superuser.** The app should use a least-privilege role.
6. **No audit logging** (`bao audit enable file ...`) and **no NetworkPolicies** restricting
   who can reach OpenBao/Postgres.

### Availability / operations

7. **OpenBao re-seals on restart** and `fail-fast: true` means the app **won't start** until
   OpenBao is manually unsealed. Configure **auto-unseal** (KMS/Transit) for unattended restart.
8. **Single points of failure everywhere:** 1 OpenBao node, 1 Postgres container, 1 app
   replica. No HA, no readiness gating on dependencies beyond fail-fast.
9. **Token lease renewal.** The app token has TTL 1h; Spring Cloud Vault renews it, but if
   renewal fails (OpenBao down) behavior must be understood/tested for long-running pods.
10. **No OpenBao backups** (`bao operator raft snapshot save`). Losing `openbao/data` + keys
    = unrecoverable secrets.

### Architecture / portability

11. **Host-IP coupling.** `192.168.64.1` is the Lima vmnet gateway on *this* machine. It
    changes with the VM/network setup. Pods break if it changes. Consider a headless
    Service+Endpoints or ExternalName to abstract it, or run OpenBao/Postgres in-cluster.
12. **Image is hand-imported into containerd**, not pulled from a registry. This doesn't
    scale to multiple nodes and isn't reproducible in CI. Use a registry (even a local one).
13. **Postgres & OpenBao on the host** is a dev convenience. Production wants managed/HA
    Postgres and in-cluster (or dedicated) OpenBao.
14. **Static KV credentials.** Upgrade to the OpenBao **database secrets engine** for
    dynamic, short-lived, per-pod Postgres credentials (auto-rotated, auto-revoked).

### Delivery / quality

15. **No resource requests/limits** on the Deployment → no scheduling guarantees / risk of
    noisy-neighbor eviction.
16. **No observability:** metrics, structured logs, tracing, alerting are absent.
17. **No CI/CD:** build/import/deploy are manual. A pipeline should build, scan, push, and
    roll out.
18. **Image size ~544MB.** Consider a JRE-trimmed or jlink/native-image (GraalVM) build, or
    distroless Java, to shrink and reduce attack surface.

---

## 6. Appendix — file map & verification evidence

### Repo layout (relevant)

```
openbao/
  docker-compose.yml, config/openbao.hcl        # OpenBao server
  CREDENTIALS.local.md        (gitignored)      # unseal keys + root token
panda-app/
  pom.xml, src/main/java/.../HelloController.java, PandaAppApplication.java
  src/main/resources/application.yml            # Spring Cloud Vault + datasource
  Dockerfile, .dockerignore
  deploy/
    00-namespace.yaml
    15-openbao-approle.yaml                      # Secret template (placeholders)
    30-deployment.yaml                           # app + env + secret refs
    40-service.yaml
    50-ingress.yaml                              # /panda path + StripPrefix
    openbao/panda-app-policy.hcl
    APPROLE.local.md            (gitignored)     # role_id + secret_id
PANDA-OPENBAO-REPORT.md                          # this report
```

### Verified working (2026-11-21)

- Pod→host reachability: `GET /v1/sys/health` OK, Postgres `5432` open (busybox test pod).
- App in cluster: pod `Running 1/1`, Spring Boot started (AppRole login succeeded).
- End-to-end: `http://192.168.64.2/panda` →
  `{"message":"Hello, World","database":"connected","db_name":"panda","db_user_source":"openbao:secret/panda/db"}`
- Least privilege: the AppRole token is **denied** write to `secret/panda/db`.

### Access

| Method                 | URL / command                                                                                  |
|------------------------|------------------------------------------------------------------------------------------------|
| Ingress (browser/curl) | `http://192.168.64.2/panda`                                                                    |
| In-cluster Service     | `http://panda-app.panda.svc/`                                                                  |
| Port-forward           | `./rke2-mac.sh kubectl -n panda port-forward svc/panda-app 8080:80` → `http://localhost:8080/` |
| kubectl                | `./rke2-mac.sh kubectl -n panda ...` (uses the Lima kubeconfig)                                |
