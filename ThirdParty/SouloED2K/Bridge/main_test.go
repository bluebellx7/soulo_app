package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	ed "github.com/monkeyWie/goed2k"
	"github.com/monkeyWie/goed2k/disk"
	"github.com/monkeyWie/goed2k/protocol"
)

func TestTransferPauseRestartVerifyAndShutdown(t *testing.T) {
	// Local payload only: no public servers or third-party media are involved.
	payload := bytes.Repeat([]byte("Soulo-verified-ed2k-"), 600000)
	hashes := []protocol.Hash{}
	for offset := 0; offset < len(payload); offset += 9728000 {
		end := offset + 9728000
		if end > len(payload) {
			end = len(payload)
		}
		h, _ := protocol.HashFromData(payload[offset:end])
		hashes = append(hashes, h)
	}
	hash := protocol.HashFromHashSet(hashes)
	folder := t.TempDir()
	seedPath := filepath.Join(folder, "seed.bin")
	if err := os.WriteFile(seedPath, payload, 0600); err != nil {
		t.Fatal(err)
	}
	settings := ed.NewSettings()
	settings.ListenPort = 0
	settings.EnableUPnP = false
	seed := ed.NewSession(settings)
	if err := seed.Listen(); err != nil {
		t.Fatal(err)
	}
	defer seed.CloseListener()
	defer seed.DisconnectFrom()
	bits := protocol.NewBitField(len(hashes))
	for i := range hashes {
		bits.SetBit(i)
	}
	_, err := seed.AddTransferParams(ed.AddTransferParams{Hash: hash, Size: int64(len(payload)), FilePath: seedPath,
		Handler: disk.NewDesktopFileHandler(seedPath), ResumeData: &protocol.TransferResumeData{Hashes: hashes, Pieces: bits}})
	if err != nil {
		t.Fatal(err)
	}
	req := request{ID: "fixture", Hash: hash.String(), Size: int64(len(payload)), Path: filepath.Join(folder, "download.bin"),
		Resume: filepath.Join(folder, "resume.json"), Sources: []string{fmt.Sprintf("127.0.0.1:%d", seed.GetListenPort())}, DisableDiscovery: true}
	engine.Lock()
	err = start(req)
	engine.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { engine.Lock(); _ = remove(req.ID, false); engine.Unlock() }()
	paused, resumed, finished := false, false, false
	var last snapshot
	lastLog := time.Now()
	var progressAtPause int64
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		ed.UpdateCachedTime()
		seed.SecondTick(ed.CurrentTime(), 10)
		engine.Lock()
		rows := poll()
		if len(rows) > 0 {
			row := rows[0]
			last = row
			if time.Since(lastLog) > 3*time.Second {
				t.Logf("progress %+v", row)
				lastLog = time.Now()
			}
			if row.Error != "" {
				engine.Unlock()
				t.Fatal(row.Error)
			}
			if !paused && row.Done > 0 && row.Done < req.Size {
				progressAtPause = row.Done
				if err := remove(req.ID, true); err != nil {
					engine.Unlock()
					t.Fatal(err)
				}
				if engine.client != nil {
					engine.Unlock()
					t.Fatal("network must stop when no jobs remain")
				}
				var saved resumeRecord
				raw, _ := os.ReadFile(req.Resume)
				if json.Unmarshal(raw, &saved) != nil || saved.Data == nil {
					engine.Unlock()
					t.Fatal("missing resume checkpoint")
				}
				paused = true
				if err := start(req); err != nil {
					engine.Unlock()
					t.Fatal(err)
				}
			} else if paused && row.Done >= progressAtPause {
				resumed = true
			}
			if row.State == "FINISHED" {
				finished = true
			}
		}
		engine.Unlock()
		if finished {
			break
		}
		time.Sleep(8 * time.Millisecond)
	}
	if !paused || !resumed || !finished {
		t.Fatalf("pause=%v resumed=%v finished=%v last=%+v", paused, resumed, finished, last)
	}
	actual, err := os.ReadFile(req.Path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actual, payload) {
		t.Fatal("payload differs after restart")
	}
	t.Logf("real eD2K peer transfer: %d bytes; pause/restart restored %d bytes; final hash verified", len(payload), progressAtPause)
}

func TestVerificationRejectsCorruptFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "file.bin")
	correct := []byte("correct payload")
	hash, _ := protocol.HashFromData(correct)
	_ = os.WriteFile(p, []byte("corrupt payload"), 0600)
	if verifyFile(context.Background(), p, hash.String(), int64(len(correct))) == nil {
		t.Fatal("corruption accepted")
	}
}

func TestStaleCheckpointKeepsVerifiedPiecesAndRejectsChangedBytes(t *testing.T) {
	first := bytes.Repeat([]byte("x"), 9728000)
	hash1, _ := protocol.HashFromData(first)
	hash2, _ := protocol.HashFromData([]byte("tail"))
	hashes := []protocol.Hash{hash1, hash2}
	p := filepath.Join(t.TempDir(), "partial.bin")
	if err := os.WriteFile(p, append(first, []byte("tail")...), 0600); err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(p, os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	info, _ := f.Stat()
	bits := protocol.NewBitField(2)
	bits.SetBit(0)
	saved := resumeRecord{Hash: protocol.HashFromHashSet(hashes).String(), Size: 9728004, FileSize: 9728000,
		Data: &protocol.TransferResumeData{Hashes: hashes, Pieces: bits}}
	restored := restoreCheckpoint(f, saved, info)
	if restored == nil || !restored.Pieces.GetBit(0) {
		t.Fatal("valid cached piece lost after later writes")
	}
	_, _ = f.WriteAt([]byte("y"), 0)
	info, _ = f.Stat()
	restored = restoreCheckpoint(f, saved, info)
	if restored.Pieces.GetBit(0) {
		t.Fatal("modified piece trusted")
	}
}

func TestRejectsSymlinkTargetAndLargeFileMetadata(t *testing.T) {
	folder := t.TempDir()
	target := filepath.Join(folder, "target")
	link := filepath.Join(folder, "link")
	_ = os.WriteFile(target, []byte("keep"), 0600)
	_ = os.Symlink(target, link)
	req := request{ID: "large", Hash: "6CC0B357A958A18260D45D47B9D4C8DF", Size: 5263316776, Path: link, Resume: filepath.Join(folder, "resume"), DisableDiscovery: true}
	engine.Lock()
	err := start(req)
	engine.Unlock()
	if err == nil {
		t.Fatal("symlink target accepted")
	}
	req.Path = filepath.Join(folder, "large.mp4")
	engine.Lock()
	err = start(req)
	if err == nil && engine.jobs[req.ID].Size != 5263316776 {
		err = fmt.Errorf("size truncated")
	}
	_ = remove(req.ID, false)
	engine.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(target)
	if string(raw) != "keep" {
		t.Fatal("target changed")
	}
}
