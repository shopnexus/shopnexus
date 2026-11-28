package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// setup returns a secrets directory with dev.env and prod.env made from
// example.env, OPENROUTER_API_KEY and LLM_UPSTREAM_API_KEY filled in, and the server image to run
// envgen from (SERVER_IMAGE, or the one CI pushes).
func setup(t *testing.T) (opts, string) {
	t.Helper()
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("seal runs envgen in Docker")
	}
	dir := t.TempDir()
	example, err := os.ReadFile("../../stack/secrets/example.env")
	if err != nil {
		t.Fatal(err)
	}
	filled := strings.Replace(string(example), "\nOPENROUTER_API_KEY=\n", "\nOPENROUTER_API_KEY=test\n", 1)
	filled = strings.Replace(filled, "\nLLM_UPSTREAM_API_KEY=\n", "\nLLM_UPSTREAM_API_KEY=test\n", 1)
	for _, s := range []string{"dev", "prod"} {
		if err := os.WriteFile(filepath.Join(dir, s+".env"), []byte(filled), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	image := os.Getenv("SERVER_IMAGE")
	if image == "" {
		image = "ghcr.io/shopnexus/server:main"
	}
	return opts{dir: dir, example: "../../stack/secrets/example.env", image: image, dryRun: true}, dir
}

func dryRun(t *testing.T, o opts, stack string) string {
	t.Helper()
	var out bytes.Buffer
	if err := seal(stack, o, &out); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

// names returns the names of the Secrets in a dry run's output.
func names(t *testing.T, out string) []string {
	t.Helper()
	var got []string
	for doc := range strings.SplitSeq(strings.TrimPrefix(out, "---\n"), "---\n") {
		var s struct {
			Kind     string
			Metadata struct{ Name string }
		}
		if err := json.Unmarshal([]byte(doc), &s); err != nil {
			t.Fatalf("%v in\n%s", err, doc)
		}
		if s.Kind == "Secret" {
			got = append(got, s.Metadata.Name)
		}
	}
	slices.Sort(got)
	return got
}

func TestSealKeepsItsKeys(t *testing.T) {
	o, _ := setup(t)

	first := dryRun(t, o, "dev")
	second := dryRun(t, o, "dev")

	if first != second {
		t.Error("a second run changed the secrets")
	}
	if want := []string{"agent-secrets", "bifrost-db", "bifrost-secrets", "garage-secrets", "restate-secrets", "server-secrets"}; !slices.Equal(names(t, first), want) {
		t.Errorf("Secrets = %v, want %v", names(t, first), want)
	}
	for _, k := range []string{"JWT_PRIVATE_KEY", "CONSOLE_KEY", "RESTATE_IDENTITY_KEY", "private.pem",
		"BIFROST_ADMIN_PASSWORD", "BIFROST_ENCRYPTION_KEY", "LLM_UPSTREAM_API_KEY", "OPENROUTER_API_KEY",
		"AGENT_KEY", "AGENT_WORKSPACES_ACCESS_KEY"} {
		if !strings.Contains(first, `"`+k+`"`) {
			t.Errorf("no %s in\n%s", k, first)
		}
	}
	// Bifrost makes the callers' keys; no Secret holds one.
	for _, k := range []string{"LLM_API_KEY", "AGENT_LLM_API_KEY", "EMBED_INDEX_API_KEY", "LITELLM_MASTER_KEY"} {
		if strings.Contains(first, `"`+k+`"`) {
			t.Errorf("%s in\n%s", k, first)
		}
	}
}

// An older dev.env has RustFS's keys, which are no Garage key IDs: the
// server and Restate get new ones. Its AGENT_RUNTIME_KEY becomes AGENT_KEY.
func TestSealRemakesRustFSKeys(t *testing.T) {
	o, dir := setup(t)
	f, err := os.OpenFile(filepath.Join(dir, "dev.env"), os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("OBJECT_STORE_ACCESS_KEY=oldkey\nOBJECT_STORE_SECRET_KEY=oldsecret\nAGENT_RUNTIME_KEY=oldagentkey\n"); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}

	data := map[string]map[string]string{}
	for doc := range strings.SplitSeq(strings.TrimPrefix(dryRun(t, o, "dev"), "---\n"), "---\n") {
		var s struct {
			Metadata struct{ Name string }
			Data     map[string]string
		}
		if err := json.Unmarshal([]byte(doc), &s); err != nil {
			t.Fatal(err)
		}
		data[s.Metadata.Name] = s.Data
	}
	b64 := func(v string) string { return base64.StdEncoding.EncodeToString([]byte(v)) }
	unb64 := func(v string) string { b, _ := base64.StdEncoding.DecodeString(v); return string(b) }
	for _, got := range []string{data["server-secrets"]["OBJECT_STORE_ACCESS_KEY"], data["restate-secrets"]["AWS_ACCESS_KEY_ID"], data["agent-secrets"]["AGENT_WORKSPACES_ACCESS_KEY"]} {
		if k := unb64(got); len(k) != 26 || !strings.HasPrefix(k, "GK") {
			t.Errorf("a key = %q, want GK and 24 hex digits", k)
		}
	}
	if s := unb64(data["server-secrets"]["OBJECT_STORE_SECRET_KEY"]); s == "oldsecret" || len(s) != 64 {
		t.Errorf("the server's secret = %q, want a new one of 64 hex digits", s)
	}
	if data["garage-secrets"]["SNAPSHOTS_ACCESS_KEY"] != data["restate-secrets"]["AWS_ACCESS_KEY_ID"] {
		t.Error("the snapshot jobs and Restate have different keys")
	}
	if k := data["agent-secrets"]["AGENT_WORKSPACES_ACCESS_KEY"]; k == "" || k != data["garage-secrets"]["AGENT_WORKSPACES_ACCESS_KEY"] {
		t.Error("the workspaces job and the agent have different keys")
	}
	if data["garage-secrets"]["GARAGE_RPC_SECRET"] == "" || data["garage-secrets"]["GARAGE_ADMIN_TOKEN"] == "" {
		t.Error("garage-secrets lacks the RPC secret or the admin token")
	}
	if k := data["agent-secrets"]["AGENT_KEY"]; k != b64("oldagentkey") || k != data["server-secrets"]["AGENT_KEY"] {
		t.Error("the server and the agent do not share the older AGENT_RUNTIME_KEY")
	}
}

func TestSealKeepsTheEnvFilePrivate(t *testing.T) {
	o, dir := setup(t)
	if err := os.Chmod(filepath.Join(dir, "dev.env"), 0o644); err != nil {
		t.Fatal(err)
	}

	dryRun(t, o, "dev")

	info, err := os.Stat(filepath.Join(dir, "dev.env"))
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Errorf("dev.env mode = %o, want 600", mode)
	}
}

// APP_ENV=prod refuses to only log pushes.
func TestSealRefusesProdWithoutFCMCredentials(t *testing.T) {
	o, _ := setup(t)

	err := seal("prod", o, &bytes.Buffer{})

	if err == nil || !strings.Contains(err.Error(), "FCM_CREDENTIALS") {
		t.Fatalf("err = %v, want one naming FCM_CREDENTIALS", err)
	}
}

// EMAIL_SENDER=resend in prod needs Resend's key.
func TestSealRefusesProdWithoutResendKey(t *testing.T) {
	o, dir := setup(t)
	env := filepath.Join(dir, "prod.env")
	b, err := os.ReadFile(env)
	if err != nil {
		t.Fatal(err)
	}
	filled := strings.Replace(string(b), "\nFCM_CREDENTIALS=\n", "\nFCM_CREDENTIALS=e30=\n", 1)
	if err = os.WriteFile(env, []byte(filled), 0o600); err != nil {
		t.Fatal(err)
	}

	err = seal("prod", o, &bytes.Buffer{})

	if err == nil || !strings.Contains(err.Error(), "RESEND_API_KEY") {
		t.Fatalf("err = %v, want one naming RESEND_API_KEY", err)
	}
}

// A restored .env without its .pem must stop, not rotate the Restate key.
func TestSealRefusesAMissingPem(t *testing.T) {
	o, dir := setup(t)
	dryRun(t, o, "dev")
	before, err := os.ReadFile(filepath.Join(dir, "dev.env"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(dir, "dev.restate.pem")); err != nil {
		t.Fatal(err)
	}

	err = seal("dev", o, &bytes.Buffer{})

	if err == nil || !strings.Contains(err.Error(), "dev.restate.pem") {
		t.Fatalf("err = %v, want one naming dev.restate.pem", err)
	}
	after, err := os.ReadFile(filepath.Join(dir, "dev.env"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Error("dev.env changed")
	}
}

func TestSealRefusesAnotherStack(t *testing.T) {
	t.Parallel()

	err := seal("qa", opts{}, &bytes.Buffer{})

	if err == nil || !strings.Contains(err.Error(), "dev or prod") {
		t.Fatalf("err = %v, want one naming dev or prod", err)
	}
}
