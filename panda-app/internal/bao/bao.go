package bao

import (
	"context"
	"fmt"

	k8sauth "github.com/openbao/openbao/api/auth/kubernetes/v2"
	openbao "github.com/openbao/openbao/api/v2"
)

type DBCreds struct {
	Username string
	Password string
}

// FetchDBCreds logs in to OpenBao using the pod's Kubernetes ServiceAccount
// token and reads the DB credentials from a KV v2 path.
//
//	addr      - OpenBao address, e.g. http://openbao.openbao.svc:8200 (from BAO_ADDR)
//	role      - the OpenBao Kubernetes auth role (e.g. "panda-app")
//	mount     - KV v2 mount (e.g. "secret")
//	secretKey - path under the mount (e.g. "panda/db")
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
