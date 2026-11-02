// Copyright (c) 2026 Soulo. Distributed under the MIT license in LICENSE.
package goed2k

import (
	"context"
	"net"
	"sync"
	"time"
)

// Dial completion is handed to the session loop; socket and protocol state are
// never mutated by the dial goroutine. Closing also closes an undelivered socket.
type connectionDial struct {
	mu        sync.Mutex
	cancelled bool
	cancel    context.CancelFunc
	result    chan dialResult
}
type dialResult struct {
	conn net.Conn
	err  error
}

func (c *Connection) startDial(address *net.TCPAddr) error {
	if c.pendingDial != nil {
		c.pendingDial.close()
	}
	timeout := 5 * time.Second
	if c.session != nil && c.session.settings.PeerConnectionTimeout > 0 {
		timeout = time.Duration(c.session.settings.PeerConnectionTimeout) * time.Second
		if timeout > 10*time.Second {
			timeout = 10 * time.Second
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	pending := &connectionDial{cancel: cancel, result: make(chan dialResult, 1)}
	c.pendingDial = pending
	go func() {
		conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", address.String())
		pending.mu.Lock()
		defer pending.mu.Unlock()
		if pending.cancelled {
			if conn != nil {
				_ = conn.Close()
			}
			return
		}
		pending.result <- dialResult{conn: conn, err: err}
	}()
	return nil
}

func (c *Connection) finishDial() {
	pending := c.pendingDial
	if pending == nil {
		return
	}
	select {
	case result := <-pending.result:
		pending.cancel()
		c.pendingDial = nil
		if result.err != nil {
			c.Close(IOException)
			return
		}
		c.socket = result.conn
		c.lastReceive = CurrentTime()
	default:
	}
}

func (p *connectionDial) close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cancelled {
		return
	}
	p.cancelled = true
	p.cancel()
	select {
	case result := <-p.result:
		if result.conn != nil {
			_ = result.conn.Close()
		}
	default:
	}
}
