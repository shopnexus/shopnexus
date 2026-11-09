package main

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestJPEGIsADataURLOfTheSize(t *testing.T) {
	var out bytes.Buffer
	if err := run([]string{"jpeg", "64"}, &out); err != nil {
		t.Fatal(err)
	}
	s := strings.TrimSpace(out.String())
	b64, ok := strings.CutPrefix(s, "data:image/jpeg;base64,")
	if !ok {
		t.Fatalf("not a JPEG data URL: %.40s", s)
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatal(err)
	}
	img, err := jpeg.Decode(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	if b := img.Bounds(); b.Dx() != 64 || b.Dy() != 64 {
		t.Errorf("size %v, want 64x64", b)
	}
}

func TestLargeJPEGIsLarge(t *testing.T) {
	var out bytes.Buffer
	if err := run([]string{"jpeg", "1200"}, &out); err != nil {
		t.Fatal(err)
	}
	if n := out.Len(); n < 700_000 {
		t.Errorf("a 1200 px noise JPEG gave %d bytes, want at least 700 kB", n)
	}
}

func TestWAVIsSilentPCM(t *testing.T) {
	path := filepath.Join(t.TempDir(), "s.wav")
	if err := run([]string{"wav", "2", path}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(b[0:4]) != "RIFF" || string(b[8:12]) != "WAVE" {
		t.Fatalf("no RIFF/WAVE header")
	}
	if rate := binary.LittleEndian.Uint32(b[24:28]); rate != 16000 {
		t.Errorf("rate %d, want 16000", rate)
	}
	if got, want := len(b), 44+2*16000*2; got != want {
		t.Errorf("%d bytes, want %d", got, want)
	}
	for _, x := range b[44:] {
		if x != 0 {
			t.Fatal("the samples are not silent")
		}
	}
}

func TestBadArguments(t *testing.T) {
	for _, args := range [][]string{nil, {"jpeg"}, {"jpeg", "0"}, {"wav", "1"}, {"png", "8"}} {
		if err := run(args, &bytes.Buffer{}); err == nil {
			t.Errorf("run(%q) gave no error", args)
		}
	}
}
