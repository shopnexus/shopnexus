// Command sample writes the files that infra's probes and model smoke test
// send: a noise JPEG as a data URL, the form the server sends embed-image,
// and a silent WAV for stt.
//
//	go -C infra run ./probes/sample jpeg <px>
//	go -C infra run ./probes/sample wav <seconds> <path>
package main

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"io"
	"math/rand/v2"
	"os"
	"strconv"
)

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "sample:", err)
		os.Exit(2)
	}
}

func run(args []string, out io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: sample jpeg <px> | sample wav <seconds> <path>")
	}
	switch args[0] {
	case "jpeg":
		if len(args) != 2 {
			return errors.New("usage: sample jpeg <px>")
		}
		px, err := strconv.Atoi(args[1])
		if err != nil || px < 1 {
			return fmt.Errorf("px %q is not a positive integer", args[1])
		}
		// Noise does not compress, so the size of the file follows px.
		r := rand.New(rand.NewPCG(1, 2))
		img := image.NewRGBA(image.Rect(0, 0, px, px))
		for y := range px {
			for x := range px {
				img.Set(x, y, color.RGBA{uint8(r.UintN(256)), uint8(r.UintN(256)), uint8(r.UintN(256)), 255})
			}
		}
		var b bytes.Buffer
		if err := jpeg.Encode(&b, img, &jpeg.Options{Quality: 90}); err != nil {
			return err
		}
		_, err = fmt.Fprintf(out, "data:image/jpeg;base64,%s\n", base64.StdEncoding.EncodeToString(b.Bytes()))
		return err
	case "wav":
		if len(args) != 3 {
			return errors.New("usage: sample wav <seconds> <path>")
		}
		sec, err := strconv.Atoi(args[1])
		if err != nil || sec < 1 {
			return fmt.Errorf("seconds %q is not a positive integer", args[1])
		}
		const rate, bytesPerSample = 16000, 2
		data := sec * rate * bytesPerSample
		var b bytes.Buffer
		b.WriteString("RIFF")
		_ = binary.Write(&b, binary.LittleEndian, uint32(36+data))
		b.WriteString("WAVEfmt ")
		for _, v := range []any{uint32(16), uint16(1), uint16(1), uint32(rate), uint32(rate * bytesPerSample), uint16(bytesPerSample), uint16(16)} {
			_ = binary.Write(&b, binary.LittleEndian, v)
		}
		b.WriteString("data")
		_ = binary.Write(&b, binary.LittleEndian, uint32(data))
		b.Write(make([]byte, data))
		return os.WriteFile(args[2], b.Bytes(), 0o644)
	default:
		return fmt.Errorf("unknown sample %q", args[0])
	}
}
