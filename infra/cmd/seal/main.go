// Command seal writes the SealedSecrets of one stack. From the umbrella:
//
//	go -C infra run ./cmd/seal dev|prod [-dry-run]
//
// It keeps the stack's keys in the git-ignored stack/secrets/<stack>.env and
// <stack>.restate.pem. On first use it copies example.env; every run makes
// the keys still missing, so a second run seals the same values. Then it
// writes seven Secrets, sealed by kubeseal for the cluster kubectl points at,
// to stack/secrets/<stack>/. -dry-run prints the plain Secrets instead and
// needs no cluster.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

type opts struct {
	dir     string // holds <stack>.env, <stack>.restate.pem and <stack>/
	example string // example.env
	image   string // the server image, which has /envgen
	dryRun  bool
}

func main() {
	var o opts
	flag.StringVar(&o.dir, "dir", "stack/secrets", "the secrets directory")
	flag.StringVar(&o.example, "example", "stack/secrets/example.env", "the example .env")
	flag.StringVar(&o.image, "image", "ghcr.io/shopnexus/server:main", "the server image, which runs /envgen")
	flag.BoolVar(&o.dryRun, "dry-run", false, "print the plain Secrets instead of sealing them")
	flag.Parse()
	// Flags may also follow the stack: seal dev -dry-run.
	stack := flag.Arg(0)
	if err := flag.CommandLine.Parse(flag.Args()[min(1, flag.NArg()):]); err != nil || flag.NArg() > 0 {
		fmt.Fprintln(os.Stderr, "usage: seal [flags] dev|prod [flags]")
		os.Exit(2)
	}
	if err := seal(stack, o, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "seal:", err)
		os.Exit(1)
	}
}

func seal(stack string, o opts, out io.Writer) error {
	if stack != "dev" && stack != "prod" {
		return fmt.Errorf("stack %q: want dev or prod", stack)
	}
	dir, err := filepath.Abs(o.dir)
	if err != nil {
		return err
	}
	example, err := filepath.Abs(o.example)
	if err != nil {
		return err
	}
	envFile := filepath.Join(dir, stack+".env")
	pemFile := filepath.Join(dir, stack+".restate.pem")

	// envgen copies example.env on first use and fills in the server's keys:
	// JWT_KEY_ID, JWT_PRIVATE_KEY, CONSOLE_KEY, OTP_KEY, CARRIER_TOKEN_KEY,
	// AGENT_KEY and RESTATE_IDENTITY_KEY, with the pem. It refuses a RESTATE_IDENTITY_KEY whose pem is gone: a new pair would
	// sign Restate's requests with a key the running server does not know.
	// It runs as this user, so the files stay this user's.
	envgen := exec.Command("docker", "run", "--rm",
		"--user", strconv.Itoa(os.Getuid())+":"+strconv.Itoa(os.Getgid()),
		"-v", dir+":/out", "-v", example+":/example.env:ro",
		"--entrypoint", "/envgen", o.image,
		"-env", "/out/"+stack+".env", "-example", "/example.env", "-restate", "/out/"+stack+".restate.pem")
	var stderr bytes.Buffer
	envgen.Stderr = &stderr
	if err := envgen.Run(); err != nil {
		return fmt.Errorf("envgen in %s: %w: %s", o.image, err, strings.TrimSpace(stderr.String()))
	}
	// The keys are for this user only; this also repairs an older file at 644.
	if err := os.Chmod(envFile, 0o600); err != nil {
		return err
	}

	env, err := readEnv(envFile)
	if err != nil {
		return err
	}
	// OBJECT_STORE_ACCESS_KEY used to be RustFS's root key. An older
	// <stack>.env keeps it as the root key, and the server gets a key of its own.
	if env.get("OBJECT_STORE_ROOT_ACCESS_KEY") == "" && env.get("OBJECT_STORE_ACCESS_KEY") != "" {
		env.set("OBJECT_STORE_ROOT_ACCESS_KEY", env.get("OBJECT_STORE_ACCESS_KEY"))
		env.set("OBJECT_STORE_ROOT_SECRET_KEY", env.get("OBJECT_STORE_SECRET_KEY"))
		env.set("OBJECT_STORE_ACCESS_KEY", "")
		env.set("OBJECT_STORE_SECRET_KEY", "")
	}
	// AGENT_KEY used to be AGENT_RUNTIME_KEY; the running agent keeps it.
	if old := env.get("AGENT_RUNTIME_KEY"); old != "" {
		env.set("AGENT_KEY", old)
		env.set("AGENT_RUNTIME_KEY", "")
	}
	for _, k := range []struct {
		name, prefix string
		bytes        int
	}{
		{"OBJECT_STORE_ROOT_ACCESS_KEY", "", 12}, // RustFS's root
		{"OBJECT_STORE_ROOT_SECRET_KEY", "", 24},
		{"OBJECT_STORE_ACCESS_KEY", "", 12}, // the server's user, bucket shopnexus only
		{"OBJECT_STORE_SECRET_KEY", "", 24},
		{"SNAPSHOTS_ACCESS_KEY", "", 12}, // Restate's user, bucket restate-snapshots only
		{"SNAPSHOTS_SECRET_KEY", "", 24},
		{"AGENT_WORKSPACES_ACCESS_KEY", "", 12}, // the agent runtime's user, bucket agent-workspaces only
		{"AGENT_WORKSPACES_SECRET_KEY", "", 24},
		{"AGENT_KEY", "", 32},              // what the server sends the agent
		{"BIFROST_ADMIN_PASSWORD", "", 24}, // Bifrost's admin API and UI; the server signs in with it
		{"BIFROST_ENCRYPTION_KEY", "", 32}, // fixed once set: Bifrost's stored keys are encrypted with it
		{"BIFROST_DB_PASSWORD", "", 24},
	} {
		if env.get(k.name) == "" {
			b := make([]byte, k.bytes)
			_, _ = rand.Read(b)
			env.set(k.name, k.prefix+hex.EncodeToString(b))
		}
	}
	if err := env.write(); err != nil {
		return err
	}

	for _, k := range []string{"OPENROUTER_API_KEY", "LLM_UPSTREAM_API_KEY"} {
		if env.get(k) == "" {
			return fmt.Errorf("%s: set %s", envFile, k)
		}
	}
	if stack == "prod" && env.get("FCM_CREDENTIALS") == "" {
		return fmt.Errorf("%s: prod needs FCM_CREDENTIALS (APP_ENV=prod refuses to only log pushes)", envFile)
	}
	if stack == "prod" && env.get("RESEND_API_KEY") == "" {
		return fmt.Errorf("%s: prod needs RESEND_API_KEY (EMAIL_SENDER=resend)", envFile)
	}
	pem, err := os.ReadFile(pemFile)
	if err != nil {
		return err
	}

	ns := "shopnexus-" + stack
	secrets := []secret{
		{name: "server-secrets", namespace: ns, data: env.pick(
			"JWT_KEY_ID", "JWT_PRIVATE_KEY", "CONSOLE_KEY", "RESTATE_IDENTITY_KEY",
			"OBJECT_STORE_ACCESS_KEY", "OBJECT_STORE_SECRET_KEY", "FCM_CREDENTIALS", "OTP_KEY", "CARRIER_TOKEN_KEY",
			"RESEND_API_KEY", "GHTK_PARTNER_TOKEN", "GHTK_WEBHOOK_SECRET", "GHN_PARTNER_TOKEN", "GHN_WEBHOOK_SECRET",
			"AGENT_KEY")},
		// The agent: the key the server calls it with, and its RustFS user.
		// Its gateway key comes with each turn.
		{name: "agent-secrets", namespace: ns, data: env.pick("AGENT_KEY", "AGENT_WORKSPACES_ACCESS_KEY", "AGENT_WORKSPACES_SECRET_KEY")},
		{name: "restate-secrets", namespace: "restate-" + stack, data: map[string]string{
			"private.pem":           string(pem),
			"AWS_ACCESS_KEY_ID":     env.get("SNAPSHOTS_ACCESS_KEY"),
			"AWS_SECRET_ACCESS_KEY": env.get("SNAPSHOTS_SECRET_KEY"),
		}},
		// RustFS's root keys, for rustfs and the objectstore-init jobs, which
		// also make Restate's user and the agent's.
		{name: "rustfs-secrets", namespace: ns, data: map[string]string{
			"RUSTFS_ACCESS_KEY":           env.get("OBJECT_STORE_ROOT_ACCESS_KEY"),
			"RUSTFS_SECRET_KEY":           env.get("OBJECT_STORE_ROOT_SECRET_KEY"),
			"SNAPSHOTS_ACCESS_KEY":        env.get("SNAPSHOTS_ACCESS_KEY"),
			"SNAPSHOTS_SECRET_KEY":        env.get("SNAPSHOTS_SECRET_KEY"),
			"AGENT_WORKSPACES_ACCESS_KEY": env.get("AGENT_WORKSPACES_ACCESS_KEY"),
			"AGENT_WORKSPACES_SECRET_KEY": env.get("AGENT_WORKSPACES_SECRET_KEY"),
		}},
		{name: "bifrost-secrets", namespace: ns, data: env.pick("BIFROST_ADMIN_PASSWORD", "BIFROST_ENCRYPTION_KEY", "LLM_UPSTREAM_API_KEY", "OPENROUTER_API_KEY")},
		// CNPG reads a managed role's password from a basic-auth Secret.
		{name: "bifrost-db", namespace: ns, typ: "kubernetes.io/basic-auth", data: map[string]string{
			"username": "bifrost",
			"password": env.get("BIFROST_DB_PASSWORD"),
		}},
	}

	if !o.dryRun {
		if err := os.MkdirAll(filepath.Join(dir, stack), 0o755); err != nil {
			return err
		}
	}
	for _, s := range secrets {
		doc, err := s.json()
		if err != nil {
			return err
		}
		if o.dryRun {
			fmt.Fprintf(out, "---\n%s\n", doc)
			continue
		}
		var sealed bytes.Buffer
		kubeseal := exec.Command("kubeseal", "--format", "yaml")
		kubeseal.Stdin, kubeseal.Stdout, kubeseal.Stderr = bytes.NewReader(doc), &sealed, os.Stderr
		if err := kubeseal.Run(); err != nil {
			return fmt.Errorf("kubeseal %s: %w", s.name, err)
		}
		if err := os.WriteFile(filepath.Join(dir, stack, s.name+".yaml"), sealed.Bytes(), 0o644); err != nil {
			return err
		}
	}
	if !o.dryRun {
		fmt.Fprintf(out, "sealed into %s; commit and push\n", filepath.Join(dir, stack))
	}
	return nil
}

type secret struct {
	name, namespace, typ string
	data                 map[string]string
}

func (s secret) json() ([]byte, error) {
	typ := s.typ
	if typ == "" {
		typ = "Opaque"
	}
	data := map[string]string{}
	for k, v := range s.data {
		data[k] = base64.StdEncoding.EncodeToString([]byte(v))
	}
	return json.Marshal(map[string]any{
		"apiVersion": "v1",
		"kind":       "Secret",
		"metadata":   map[string]string{"name": s.name, "namespace": s.namespace},
		"type":       typ,
		"data":       data,
	})
}

// envFile is a .env file's lines. get reads the first line of a name, and set
// replaces that line or appends one, so an empty KEY= line gets its value in
// place.
type envFile struct {
	path  string
	lines []string
}

func readEnv(path string) (*envFile, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return &envFile{path: path, lines: strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")}, nil
}

func (e *envFile) get(key string) string {
	for _, l := range e.lines {
		if v, ok := strings.CutPrefix(l, key+"="); ok {
			return v
		}
	}
	return ""
}

func (e *envFile) set(key, value string) {
	for i, l := range e.lines {
		if strings.HasPrefix(l, key+"=") {
			e.lines[i] = key + "=" + value
			return
		}
	}
	e.lines = append(e.lines, key+"="+value)
}

func (e *envFile) pick(keys ...string) map[string]string {
	m := map[string]string{}
	for _, k := range keys {
		m[k] = e.get(k)
	}
	return m
}

func (e *envFile) write() error {
	if err := os.WriteFile(e.path, []byte(strings.Join(e.lines, "\n")+"\n"), 0o600); err != nil {
		return errors.Join(fmt.Errorf("write %s", e.path), err)
	}
	return nil
}
