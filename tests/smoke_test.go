package tests

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"net"
	"net/http"
	"os"
	"testing"
	"time"

	"tailscale.com/derp"
	"tailscale.com/derp/derphttp"
	"tailscale.com/net/netmon"
	"tailscale.com/net/stun"
	"tailscale.com/types/key"
)

func required(t *testing.T, name string) string {
	t.Helper()
	v := os.Getenv(name)
	if v == "" {
		t.Fatalf("%s must be set by the smoke-test runner", name)
	}
	return v
}

func tlsConfig(t *testing.T) *tls.Config {
	t.Helper()
	pem, err := os.ReadFile(required(t, "DERP_CA"))
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pem) {
		t.Fatal("invalid test CA")
	}
	return &tls.Config{RootCAs: roots, ServerName: "localhost", MinVersion: tls.VersionTLS12}
}

func client(t *testing.T, url string) (*derphttp.Client, key.NodePublic) {
	t.Helper()
	k := key.NewNode()
	c, err := derphttp.NewClient(k, url+"/derp", t.Logf, netmon.NewStatic())
	if err != nil {
		t.Fatal(err)
	}
	c.TLSConfig = tlsConfig(t)
	// Recv has no context argument; closing the client also bounds failed tests.
	timer := time.AfterFunc(10*time.Second, func() { c.Close() })
	t.Cleanup(func() { timer.Stop(); c.Close() })
	return c, k.Public()
}

func connect(t *testing.T, c *derphttp.Client) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Connect(ctx); err != nil {
		t.Fatal(err)
	}
	m, err := c.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := m.(derp.ServerInfoMessage); !ok {
		t.Fatalf("expected server handshake, got %T", m)
	}
}

func TestTLSAndRelay(t *testing.T) {
	url := required(t, "DERP_URL")
	transport := &http.Transport{TLSClientConfig: tlsConfig(t)}
	defer transport.CloseIdleConnections()
	h := &http.Client{Transport: transport, Timeout: 5 * time.Second}
	r, err := h.Get(url + "/")
	if err != nil {
		t.Fatal(err)
	}
	r.Body.Close()
	if r.StatusCode != http.StatusOK {
		t.Fatalf("unexpected HTTPS status %d", r.StatusCode)
	}
	a, ka := client(t, url)
	b, kb := client(t, url)
	connect(t, a)
	connect(t, b)
	for _, pair := range []struct {
		from, to *derphttp.Client
		src, dst key.NodePublic
	}{{a, b, ka, kb}, {b, a, kb, ka}} {
		payload := []byte("DERP bidirectional smoke test")
		if err := pair.from.Send(pair.dst, payload); err != nil {
			t.Fatal(err)
		}
		for {
			m, err := pair.to.Recv()
			if err != nil {
				t.Fatal(err)
			}
			if packet, ok := m.(derp.ReceivedPacket); ok {
				if packet.Source != pair.src || !bytes.Equal(packet.Data, payload) {
					t.Fatal("relay changed payload or source")
				}
				break
			}
		}
	}
}

func TestSTUN(t *testing.T) {
	conn, err := net.DialTimeout("udp", required(t, "STUN_ADDR"), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	tx := stun.NewTxID()
	if _, err := conn.Write(stun.Request(tx)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 1500)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	got, addr, err := stun.ParseResponse(buf[:n])
	if err != nil || got != tx || !addr.IsValid() {
		t.Fatalf("invalid STUN response: tx=%v addr=%v err=%v", got, addr, err)
	}
}

func TestVerifyClientsFailsClosed(t *testing.T) {
	url := required(t, "DERP_VERIFY_URL")
	// Ensure TLS is healthy, so an unavailable server cannot pass this test.
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 5 * time.Second}, "tcp", required(t, "DERP_VERIFY_ADDR"), tlsConfig(t))
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	c, _ := client(t, url)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.Connect(ctx); err != nil {
		t.Fatal("connection failed before admission check:", err)
	}
	if m, err := c.Recv(); err == nil {
		t.Fatalf("client accepted without tailscaled: %T", m)
	}
}
