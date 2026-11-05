package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// setup returns a secrets directory with dev.env and prod.env made from
// example.env, LLM_UPSTREAM_API_KEY filled in, and the server image to run
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
	filled := strings.Replace(string(example), "\nLLM_UPSTREAM_API_KEY=\n", "\nLLM_UPSTREAM_API_KEY=test\n", 1)
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
	if want := []string{"litellm-db", "litellm-secrets", "restate-secrets", "server-secrets"}; !slices.Equal(names(t, first), want) {
		t.Errorf("Secrets = %v, want %v", names(t, first), want)
	}
	for _, k := range []string{"JWT_PRIVATE_KEY", "STAFF_KEY", "RESTATE_IDENTITY_KEY", "LLM_API_KEY", "private.pem", "LITELLM_MASTER_KEY"} {
		if !strings.Contains(first, `"`+k+`"`) {
			t.Errorf("no %s in\n%s", k, first)
		}
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
