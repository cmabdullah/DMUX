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
