package core

import (
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"context"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/listener"
	D "github.com/miekg/dns"
	"strings"
)

func TestDelayPreparationAfterBootstrapStartAndVPNRunning(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	home := t.TempDir()
	if !handleInitClash(&InitParams{HomeDir: home, CachePath: filepath.Join(t.TempDir(), "cache.db")}) {
		t.Fatal("init failed")
	}
	defer handleShutdown()
	socket, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := socket.Addr().(*net.TCPAddr).Port
	socket.Close()
	data := []byte("proxies:\n  - {name: usable, type: direct}\n")
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := applyConfig(defaultSetupParams()); err != nil {
		t.Fatal(err)
	}
	currentConfig.General.MixedPort = port
	if !handleStartListener() || !isRunning.Load() || listener.GetPorts().MixedPort != port {
		t.Fatal("bootstrap listener not running")
	}
	// The extension lives in another process; its read-only snapshot has this digest.
	snapshot, err := delayTestConfiguration()
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Digest != delayConfigDigest(data) {
		t.Fatal("applied snapshot mismatch")
	}
	if err := prepareDelayTest(snapshot); err != nil {
		t.Fatalf("VPN running preparation: %v", err)
	}
	if isRunning.Load() || listener.GetPorts().MixedPort != 0 {
		t.Fatal("App retained forwarding listener")
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), time.Second)
	if err == nil {
		conn.Close()
		t.Fatal("old App listener still accepts connections")
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	defer server.Close()
	for range 2 {
		result, err := handleAvailableTestDelay(&TestDelayParams{ProxyName: "usable", TestUrl: server.URL})
		if err != nil || result == nil || result.Value < 0 {
			t.Fatalf("real HTTP HEAD failed: %v %v", result, err)
		}
	}
	if err := prepareDelayTest(snapshot); err != nil {
		t.Fatal(err)
	}
	handleStartListener()
	if err := prepareDelayTest(snapshot); err != nil || isRunning.Load() {
		t.Fatalf("restarted App escaped measurement demotion: %v", err)
	}
}

func TestDelayPreparationFakeIPKeepsRealResolver(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dns := &D.Server{PacketConn: udp, Handler: D.HandlerFunc(func(w D.ResponseWriter, r *D.Msg) {
		reply := new(D.Msg)
		reply.SetReply(r)
		if r.Question[0].Qtype == D.TypeA {
			reply.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: r.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60}, A: net.IPv4(127, 0, 0, 1)}}
		}
		w.WriteMsg(reply)
	})}
	go dns.ActivateAndServe()
	defer dns.Shutdown()
	home := t.TempDir()
	data := []byte("dns:\n  enable: true\n  enhanced-mode: fake-ip\n  fake-ip-range: 198.18.0.1/16\n  nameserver: [udp://" + udp.LocalAddr().String() + "]\nproxies:\n  - {name: usable, type: direct}\n")
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if !handleInitClash(&InitParams{HomeDir: home, CachePath: filepath.Join(t.TempDir(), "cache.db")}) {
		t.Fatal("init")
	}
	defer handleShutdown()
	if err := applyConfig(defaultSetupParams()); err != nil {
		t.Fatal(err)
	}
	handleStartListener()
	if err := prepareDelayTest(&delayPreparationParams{Digest: delayConfigDigest(data)}); err != nil {
		t.Fatal(err)
	}
	if !resolver.FakeIPEnabled() {
		t.Fatal("lost fake-IP compatibility")
	}
	ip, err := resolver.ResolveIPv4(context.Background(), "measurement.test")
	if err != nil || ip.String() != "127.0.0.1" {
		t.Fatalf("outbound resolver returned synthetic IP: %v %v", ip, err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	defer server.Close()
	target := strings.Replace(server.URL, "127.0.0.1", "measurement.test", 1)
	result, err := handleAvailableTestDelay(&TestDelayParams{ProxyName: "usable", TestUrl: target})
	if err != nil || result == nil || result.Value < 0 {
		t.Fatalf("fake-IP profile real HTTP HEAD: %v %v", result, err)
	}
}

func TestDelayPreparationSafeRejectionReasons(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	home := t.TempDir()
	params := &delayPreparationParams{Digest: "expected"}
	check := func(want string) {
		t.Helper()
		err := prepareDelayTest(params)
		if err == nil {
			t.Fatalf("accepted %s", want)
		}
		details, ok := asMethodError(err).Details.(map[string]any)
		if !ok || details["reason"] != want {
			t.Fatalf("want %s, got %#v", want, err)
		}
	}
	check("not_initialized")
	if !handleInitClash(&InitParams{HomeDir: home}) {
		t.Fatal("init")
	}
	defer handleShutdown()
	params.Digest = ""
	check("missing_digest")
	params.Digest = "expected"
	check("config_read_failed")
	for _, tc := range []struct{ data, reason string }{
		{"mode: rule\n", "digest_mismatch"},
		{"proxies: [", "config_decode_failed"},
		{"proxies:\n  - {name: invalid, type: unknown-type}\n", "config_parse_failed"},
	} {
		data := []byte(tc.data)
		if err := os.WriteFile(filepath.Join(home, "config.yaml"), data, 0600); err != nil {
			t.Fatal(err)
		}
		if tc.reason != "digest_mismatch" {
			params.Digest = delayConfigDigest(data)
		}
		check(tc.reason)
	}
}

func TestDelayPreparationRejectsRunningNonAppCore(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	home := t.TempDir()
	if !handleInitClash(&InitParams{HomeDir: home}) {
		t.Fatal("init failed")
	}
	defer handleShutdown()
	data := []byte("proxies:\n  - {name: usable, type: direct}\n")
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := applyConfig(defaultSetupParams()); err != nil {
		t.Fatal(err)
	}
	handleStartListener()
	err := prepareDelayTest(&delayPreparationParams{Digest: delayConfigDigest(data)})
	if err == nil || !isRunning.Load() {
		t.Fatal("running non-App core changed")
	}
	method := asMethodError(err)
	details, ok := method.Details.(map[string]any)
	if !ok || details["reason"] != "active_non_app_core" {
		t.Fatalf("missing safe reason: %#v", method)
	}
}
