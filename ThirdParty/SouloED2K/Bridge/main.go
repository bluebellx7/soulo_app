package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	ed "github.com/monkeyWie/goed2k"
	"github.com/monkeyWie/goed2k/protocol"
	kad "github.com/monkeyWie/goed2k/protocol/kad"
	server "github.com/monkeyWie/goed2k/protocol/server"
)

type request struct {
	Action           string   `json:"action"`
	ID               string   `json:"id"`
	Hash             string   `json:"hash"`
	Size             int64    `json:"size"`
	Path             string   `json:"path"`
	Resume           string   `json:"resume"`
	Nodes            string   `json:"nodes"`
	Servers          string   `json:"servers"`
	Sources          []string `json:"sources"`
	DisableDiscovery bool     `json:"disableDiscovery"`
}
type snapshot struct {
	ID    string `json:"id"`
	Done  int64  `json:"done"`
	Total int64  `json:"total"`
	Speed int    `json:"speed"`
	Peers int    `json:"peers"`
	State string `json:"state"`
	Error string `json:"error"`
}
type result struct {
	Error string     `json:"error,omitempty"`
	Items []snapshot `json:"items,omitempty"`
}
type resumeRecord struct {
	Hash     string                       `json:"hash"`
	Size     int64                        `json:"size"`
	FileSize int64                        `json:"fileSize"`
	Modified int64                        `json:"modified"`
	Data     *protocol.TransferResumeData `json:"data"`
}
type job struct {
	request
	handle         ed.TransferHandle
	verifying      bool
	verified       bool
	lastCheckpoint time.Time
	lastSources    time.Time
	errorText      string
	cancel         context.CancelFunc
}

var engine = struct {
	sync.Mutex
	client *ed.Client
	dht    *ed.DHTTracker
	cancel context.CancelFunc
	jobs   map[string]*job
}{jobs: make(map[string]*job)}

//export SouloED2KCommand
func SouloED2KCommand(raw *C.char) (out *C.char) {
	defer func() {
		if r := recover(); r != nil {
			out = encode(result{Error: fmt.Sprint(r)})
		}
	}()
	if raw == nil {
		return encode(result{Error: "missing request"})
	}
	value := C.GoString(raw)
	if len(value) > 65536 {
		return encode(result{Error: "request too long"})
	}
	var req request
	if err := json.Unmarshal([]byte(value), &req); err != nil {
		return encode(result{Error: err.Error()})
	}
	engine.Lock()
	defer engine.Unlock()
	switch req.Action {
	case "start":
		if err := start(req); err != nil {
			return encode(result{Error: err.Error()})
		}
	case "poll":
		return encode(result{Items: poll()})
	case "pause", "remove":
		if err := remove(req.ID, req.Action == "pause"); err != nil {
			return encode(result{Error: err.Error()})
		}
	case "stop":
		var errs []error
		for id := range engine.jobs {
			if err := remove(id, true); err != nil {
				errs = append(errs, err)
			}
		}
		if len(errs) > 0 {
			return encode(result{Error: errors.Join(errs...).Error()})
		}
	default:
		return encode(result{Error: "unknown action"})
	}
	return encode(result{})
}

//export SouloED2KFree
func SouloED2KFree(value *C.char) { C.free(unsafe.Pointer(value)) }

func encode(value result) *C.char { b, _ := json.Marshal(value); return C.CString(string(b)) }

func start(req request) error {
	if req.ID == "" || req.Size <= 0 || req.Size > 1<<44 || !filepath.IsAbs(req.Path) || !filepath.IsAbs(req.Resume) {
		return errors.New("invalid file task")
	}
	hash, err := protocol.HashFromString(req.Hash)
	if err != nil {
		return err
	}
	if existing := engine.jobs[req.ID]; existing != nil {
		return nil
	}
	for _, existing := range engine.jobs {
		if existing.Hash == req.Hash {
			return errors.New("duplicate file hash")
		}
	}
	if len(engine.jobs) >= 3 {
		return errors.New("too many active tasks")
	}
	if info, err := os.Lstat(req.Path); err == nil && !info.Mode().IsRegular() {
		return errors.New("target is not a regular file")
	}
	if err := os.MkdirAll(filepath.Dir(req.Path), 0700); err != nil {
		return err
	}
	if engine.client == nil {
		settings := ed.NewSettings()
		settings.ClientName = "Soulo"
		settings.ModName = "Soulo"
		settings.ListenPort = 0
		settings.UDPPort = 0
		settings.EnableUPnP = false
		// Drive the session on our own serial loop. Discovery callbacks are
		// queued onto that loop, never mutating active transfers concurrently.
		settings.EnableDHT = false
		settings.ReconnectToServer = true
		settings.SessionConnectionsLimit = 16
		settings.BufferPoolSize = 32
		settings.MaxConnectionsPerSecond = 4
		settings.MaxUploadRateKB = 32
		settings.UploadSlots = 2
		settings.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
		client := ed.NewClient(settings)
		if err := client.Session().Listen(); err != nil {
			client.Close()
			return err
		}
		if !req.DisableDiscovery {
			tracker := ed.NewDHTTracker(0, 8*time.Second)
			if raw, e := os.ReadFile(req.Nodes); e == nil {
				if nodes, e := kad.ParseNodesDat(raw); e == nil {
					nodes.Contacts = nodes.Contacts[:min(len(nodes.Contacts), 512)]
					_ = tracker.ApplyNodesDat(nodes)
				}
			}
			if err := tracker.Start(); err == nil {
				engine.dht = tracker
			} else {
				tracker.Close()
			}
		}
		engine.client = client
		ctx, cancel := context.WithCancel(context.Background())
		engine.cancel = cancel
		go tick(ctx, client)
		if raw, err := os.ReadFile(req.Servers); err == nil {
			if met, err := server.ParseServerMet(raw); err == nil {
				addresses := met.Addresses()
				_ = client.ConnectServers(addresses[:min(len(addresses), 16)]...)
			}
		}
		// Refresh discovery data only while the user has active eD2K work.
		if !req.DisableDiscovery {
			go refreshDiscovery(ctx, client)
		}
	}
	file, err := os.OpenFile(req.Path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		if len(engine.jobs) == 0 {
			shutdown()
		}
		return err
	}
	params := ed.AddTransferParams{Hash: hash, Size: req.Size, FilePath: req.Path,
		Handler: &fixedFileHandler{file: file, path: req.Path}}
	if data, err := os.ReadFile(req.Resume); err == nil && len(data) <= 4*1024*1024 {
		var saved resumeRecord
		info, statErr := os.Stat(req.Path)
		if json.Unmarshal(data, &saved) == nil && saved.Hash == req.Hash && saved.Size == req.Size && statErr == nil && saved.Data != nil {
			params.ResumeData = restoreCheckpoint(file, saved, info)
		}
	}
	for _, source := range req.Sources {
		if len(req.Sources) > 32 {
			break
		}
		address, err := net.ResolveTCPAddr("tcp", source)
		if err != nil || address.Port <= 0 {
			continue
		}
		if params.ResumeData == nil {
			params.ResumeData = &protocol.TransferResumeData{}
		}
		params.ResumeData.Peers = append(params.ResumeData.Peers, protocol.EndpointFromInet(address))
	}
	handle, err := engine.client.AddTransfer(params)
	if err != nil {
		file.Close()
		if len(engine.jobs) == 0 {
			shutdown()
		}
		return err
	}
	engine.jobs[req.ID] = &job{request: req, handle: handle}
	return nil
}

// A process can stop after more bytes were written than the last checkpoint.
// Recheck the cached complete pieces instead of throwing all progress away.
func restoreCheckpoint(file *os.File, saved resumeRecord, info os.FileInfo) *protocol.TransferResumeData {
	resume := saved.Data
	parts := int((saved.Size + 9727999) / 9728000)
	if resume == nil || resume.Pieces.Len() > parts {
		return nil
	}
	if len(resume.Hashes) > 0 && !strings.EqualFold(protocol.HashFromHashSet(resume.Hashes).String(), saved.Hash) {
		return nil
	}
	if saved.FileSize == info.Size() && saved.Modified == info.ModTime().UnixNano() {
		return resume
	}
	verified := protocol.NewBitField(parts)
	buffer := make([]byte, 9728000)
	for index := 0; index < resume.Pieces.Len(); index++ {
		if !resume.Pieces.GetBit(index) {
			continue
		}
		begin := int64(index) * 9728000
		length := int64(9728000)
		if saved.Size-begin < length {
			length = saved.Size - begin
		}
		if begin+length > info.Size() {
			continue
		}
		if _, err := file.ReadAt(buffer[:length], begin); err != nil {
			continue
		}
		hash, _ := protocol.HashFromData(buffer[:length])
		expected := saved.Hash
		if index < len(resume.Hashes) {
			expected = resume.Hashes[index].String()
		} else if parts != 1 {
			continue
		}
		if strings.EqualFold(hash.String(), expected) {
			verified.SetBit(index)
		}
	}
	resume.Pieces = verified
	blocks := resume.DownloadedBlocks[:0]
	for _, block := range resume.DownloadedBlocks {
		if block.PieceIndex < 0 || block.PieceIndex >= parts || block.PieceBlock < 0 || block.PieceBlock >= 50 {
			continue
		}
		rangeValue := block.Range(saved.Size)
		if rangeValue.Right <= info.Size() && rangeValue.Right > rangeValue.Left {
			blocks = append(blocks, block)
		}
	}
	resume.DownloadedBlocks = blocks
	return resume
}

func checkpoint(j *job) error {
	if file := j.handle.GetFile(); file != nil {
		if err := file.Sync(); err != nil {
			return err
		}
	}
	info, err := os.Stat(j.Path)
	if err != nil {
		return err
	}
	saved := resumeRecord{Hash: j.Hash, Size: j.Size, FileSize: info.Size(), Modified: info.ModTime().UnixNano(), Data: j.handle.GetResumeData()}
	raw, err := json.Marshal(saved)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(j.Resume), 0700); err != nil {
		return err
	}
	temp := j.Resume + ".tmp"
	if err := os.WriteFile(temp, raw, 0600); err != nil {
		return err
	}
	return os.Rename(temp, j.Resume)
}

func remove(id string, save bool) error {
	j := engine.jobs[id]
	if j == nil {
		return nil
	}
	if j.cancel != nil {
		j.cancel()
	}
	j.handle.Pause()
	err := drainDisk(engine.client.Session())
	if save {
		err = errors.Join(err, checkpoint(j))
	}
	_ = engine.client.RemoveTransfer(j.handle.GetHash(), false)
	err = errors.Join(err, drainDisk(engine.client.Session()))
	delete(engine.jobs, id)
	if len(engine.jobs) == 0 {
		shutdown()
	}
	return err
}
func shutdown() {
	if engine.cancel != nil {
		engine.cancel()
		engine.cancel = nil
	}
	if engine.client != nil {
		engine.client.Close()
		engine.client = nil
	}
	if engine.dht != nil {
		engine.dht.Close()
		engine.dht = nil
	}
}
func poll() []snapshot {
	rows := make([]snapshot, 0, len(engine.jobs))
	for _, j := range engine.jobs {
		s := j.handle.GetStatus()
		row := snapshot{ID: j.ID, Done: s.TotalDone, Total: j.Size, Speed: s.DownloadRate, Peers: s.NumPeers, State: string(s.State), Error: j.errorText}
		if j.verified {
			row.State = "FINISHED"
		} else if j.verifying {
			row.State = "VERIFYING"
		} else if j.handle.IsFinished() && j.errorText == "" {
			j.verifying = true
			row.State = "VERIFYING"
			ctx, cancel := context.WithCancel(context.Background())
			j.cancel = cancel
			go verify(ctx, j)
		}
		if s.Paused && j.errorText == "" && !j.verified {
			row.Error = "file task paused after an I/O failure"
		}
		rows = append(rows, row)
		// Checkpoint every poll interval only when the engine reports changes.
		if !j.handle.IsFinished() && j.handle.NeedResumeDataSave() && time.Since(j.lastCheckpoint) >= 10*time.Second {
			if err := checkpoint(j); err != nil {
				row.Error = err.Error()
				rows[len(rows)-1] = row
			}
			j.lastCheckpoint = time.Now()
		}
	}
	return rows
}

func verify(ctx context.Context, j *job) {
	err := verifyFile(ctx, j.Path, j.Hash, j.Size)
	engine.Lock()
	defer engine.Unlock()
	if engine.jobs[j.ID] != j || ctx.Err() != nil {
		return
	}
	j.verifying = false
	if err != nil {
		j.errorText = err.Error()
		j.handle.Pause()
	} else {
		j.verified = true
	}
}

// Verify the final file independently of peer-provided hashsets and resume bits.
func verifyFile(ctx context.Context, path, expected string, size int64) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	if info.Size() != size {
		return errors.New("file length mismatch")
	}
	const partSize = 9728000
	buffer := make([]byte, partSize)
	hashes := []protocol.Hash{}
	for remaining := size; remaining > 0; {
		if err := ctx.Err(); err != nil {
			return err
		}
		n := int64(partSize)
		if remaining < n {
			n = remaining
		}
		if _, err := io.ReadFull(f, buffer[:n]); err != nil {
			return err
		}
		hash, _ := protocol.HashFromData(buffer[:n])
		hashes = append(hashes, hash)
		remaining -= n
	}
	if strings.EqualFold(protocol.HashFromHashSet(hashes).String(), expected) {
		return nil
	}
	if size%partSize == 0 {
		empty, _ := protocol.HashFromData(nil)
		hashes = append(hashes, empty)
		if strings.EqualFold(protocol.HashFromHashSet(hashes).String(), expected) {
			return nil
		}
	}
	return errors.New("ED2K file hash mismatch")
}

func refreshDiscovery(ctx context.Context, client *ed.Client) {
	httpClient := &http.Client{Timeout: 12 * time.Second}
	for _, kind := range []string{"server.met", "nodes.dat"} {
		req, err := http.NewRequestWithContext(ctx, "GET", "https://upd.emule-security.org/"+kind, nil)
		if err != nil {
			return
		}
		response, err := httpClient.Do(req)
		if err != nil {
			continue
		}
		raw, err := io.ReadAll(io.LimitReader(response.Body, 1024*1024+1))
		response.Body.Close()
		if err != nil || response.StatusCode != 200 || len(raw) > 1024*1024 {
			continue
		}
		engine.Lock()
		if engine.client == client && ctx.Err() == nil {
			if kind == "server.met" {
				if met, e := server.ParseServerMet(raw); e == nil {
					addresses := met.Addresses()
					_ = client.ConnectServers(addresses[:min(len(addresses), 16)]...)
				}
			} else {
				if nodes, e := kad.ParseNodesDat(raw); e == nil && engine.dht != nil {
					nodes.Contacts = nodes.Contacts[:min(len(nodes.Contacts), 512)]
					_ = engine.dht.ApplyNodesDat(nodes)
				}
			}
		}
		engine.Unlock()
	}
}

type sourceResult struct {
	job   *job
	peers []protocol.Endpoint
}

var sourceResults = make(chan sourceResult, 64)

func tick(ctx context.Context, client *ed.Client) {
	timer := time.NewTicker(10 * time.Millisecond)
	defer timer.Stop()
	previous := time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		engine.Lock()
		if engine.client != client || ctx.Err() != nil {
			engine.Unlock()
			return
		}
		for len(sourceResults) > 0 {
			result := <-sourceResults
			if engine.jobs[result.job.ID] == result.job {
				if transfer := client.Session().LookupTransfer(result.job.handle.GetHash()); transfer != nil {
					for _, peer := range result.peers {
						_ = transfer.AddPeer(peer, int(ed.PeerDHT))
					}
				}
			}
		}
		now := time.Now()
		elapsed := now.Sub(previous).Milliseconds()
		previous = now
		if elapsed < 1 {
			elapsed = 1
		}
		ed.UpdateCachedTime()
		client.Session().SecondTick(ed.CurrentTime(), elapsed)
		if engine.dht != nil {
			for _, j := range engine.jobs {
				if time.Since(j.lastSources) < time.Minute {
					continue
				}
				j.lastSources = time.Now()
				current := j
				engine.dht.SearchSources(j.handle.GetHash(), j.Size, func(entries []kad.SearchEntry) {
					peers := make([]protocol.Endpoint, 0, len(entries))
					for _, entry := range entries {
						if peer, ok := entry.SourceEndpoint(); ok && peer.Defined() {
							peers = append(peers, peer)
						}
					}
					select {
					case sourceResults <- sourceResult{job: current, peers: peers}:
					default:
					}
				})
			}
		}
		engine.Unlock()
	}
}

// Drain queued writes/hashes before checkpointing or closing the session.
type diskBarrier struct{ done chan struct{} }

func (b *diskBarrier) Transfer() *ed.Transfer        { return nil }
func (b *diskBarrier) Call() ed.AsyncOperationResult { return b }
func (b *diskBarrier) OnCompleted()                  { close(b.done) }
func (b *diskBarrier) Code() ed.BaseErrorCode        { return ed.NoError }
func drainDisk(session *ed.Session) error {
	barrier := &diskBarrier{done: make(chan struct{})}
	session.SubmitDiskTask(barrier)
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		ed.UpdateCachedTime()
		session.SecondTick(ed.CurrentTime(), 10)
		select {
		case <-barrier.done:
			return nil
		default:
			time.Sleep(5 * time.Millisecond)
		}
	}
	return errors.New("timed out saving file progress")
}

type fixedFileHandler struct {
	file   *os.File
	path   string
	closed atomic.Bool
}

func (h *fixedFileHandler) File() *os.File {
	if h.closed.Load() {
		return nil
	}
	return h.file
}
func (h *fixedFileHandler) Path() string { return h.path }
func (h *fixedFileHandler) Close() error {
	if h.closed.Swap(true) {
		return nil
	}
	return h.file.Close()
}
func (h *fixedFileHandler) DeleteFile() error { _ = h.Close(); return os.Remove(h.path) }

func main() {}
