package core

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/constant"
)

func TestAppPrivateCacheIsConfiguredBeforeParsing(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	home, private := t.TempDir(), t.TempDir()
	path := filepath.Join(private, "cache.db")
	initCall := `{"method":"initClash","arguments":{"home-dir":"` + home + `","cache-path":"` + path + `"}}`
	var call MethodCall
	if err := json.Unmarshal([]byte(initCall), &call); err != nil {
		t.Fatal(err)
	}
	response := handleMethodCall(&call)
	if !strings.Contains(string(response), `"result":true`) {
		t.Fatalf("init failed: %s", response)
	}
	cache := cachefile.Cache()
	if cache.DB == nil || cache.DB.Path() != path {
		t.Fatalf("unsafe first cache: %v", cache.DB)
	}
	if constant.Path.HomeDir() != home || constant.Path.Resolve("provider.yaml") != filepath.Join(home, "provider.yaml") {
		t.Fatal("private cache changed provider home")
	}
	if _, err := os.Stat(filepath.Join(home, "cache.db")); !os.IsNotExist(err) {
		t.Fatalf("shared cache was touched: %v", err)
	}
}

func TestDelayProviderFailureDoesNotPublishPreparedGeneration(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(500) }))
	defer server.Close()
	home := t.TempDir()
	data := []byte("proxy-providers:\n  bad:\n    type: http\n    url: " + server.URL + "\n    path: ./bad.yaml\nproxy-groups:\n  - {name: Proxy, type: select, use: [bad]}\n")
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), data, 0600); err != nil {
		t.Fatal(err)
	}
	handleInitClash(&InitParams{HomeDir: home})
	if err := prepareDelayTest(&delayPreparationParams{Digest: delayConfigDigest(data)}); err == nil {
		t.Fatal("provider error accepted")
	}
	if preparedDelayDigest != "" {
		t.Fatal("failed generation published")
	}
}

func TestDelayPreparedGenerationReusesProviders(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	home := t.TempDir()
	data := []byte("proxies:\n  - {name: reusable, type: direct}\n")
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), data, 0600); err != nil {
		t.Fatal(err)
	}
	handleInitClash(&InitParams{HomeDir: home})
	params := &delayPreparationParams{Digest: delayConfigDigest(data)}
	if err := prepareDelayTest(params); err != nil {
		t.Fatal(err)
	}
	previous := currentConfig
	if err := os.Remove(filepath.Join(home, "config.yaml")); err != nil {
		t.Fatal(err)
	}
	if err := prepareDelayTest(params); err != nil {
		t.Fatal(err)
	}
	if currentConfig != previous {
		t.Fatal("same generation reloaded")
	}
}

func TestDelayProviderOnlyFirstConcurrentBatch(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	home := t.TempDir()
	providerArrived := make(chan struct{}, 1)
	releaseProvider := make(chan struct{})
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		providerArrived <- struct{}{}
		<-releaseProvider
		w.Write([]byte("proxies:\n  - {name: provider-only, type: direct}\n"))
	}))
	defer provider.Close()
	data := []byte("proxy-providers:\n  remote:\n    type: http\n    url: " + provider.URL + "\n    path: ./remote.yaml\nproxy-groups:\n  - {name: Proxy, type: select, use: [remote]}\n")
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), data, 0600); err != nil {
		t.Fatal(err)
	}
	handleInitClash(&InitParams{HomeDir: home})
	done := make(chan error, 1)
	go func() { done <- prepareDelayTest(&delayPreparationParams{Digest: delayConfigDigest(data)}) }()
	<-providerArrived
	select {
	case err := <-done:
		close(releaseProvider)
		t.Fatalf("ready before provider finished: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	close(releaseProvider)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	arrived := make(chan struct{}, 10)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { arrived <- struct{}{}; <-release; w.WriteHeader(204) }))
	defer server.Close()
	var wg sync.WaitGroup
	for range 10 {
		wg.Go(func() {
			result, err := handleAvailableTestDelay(&TestDelayParams{ProxyName: "provider-only", TestUrl: server.URL})
			if err != nil || result == nil || result.Value < 0 {
				t.Errorf("provider-only first test: %v %v", result, err)
			}
		})
	}
	for range 10 {
		select {
		case <-arrived:
		case <-time.After(3 * time.Second):
			close(release)
			wg.Wait()
			t.Fatal("measurements did not run concurrently")
		}
	}
	close(release)
	wg.Wait()
}

func TestDelayGroupsNeverStartBackgroundHealthChecks(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1); w.WriteHeader(204) }))
	defer server.Close()
	home := t.TempDir()
	data := []byte("proxies:\n  - {name: explicit, type: direct}\nproxy-providers:\n  inline:\n    type: inline\n    payload:\n      - {name: provided, type: direct}\nproxy-groups:\n  - {name: Auto, type: url-test, proxies: [explicit], url: '" + server.URL + "', interval: 1, lazy: false}\n  - {name: Fallback, type: fallback, use: [inline], url: '" + server.URL + "', interval: 1, lazy: false}\n")
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), data, 0600); err != nil {
		t.Fatal(err)
	}
	handleInitClash(&InitParams{HomeDir: home})
	if err := prepareDelayTest(&delayPreparationParams{Digest: delayConfigDigest(data)}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(1200 * time.Millisecond)
	if got := requests.Load(); got != 0 {
		t.Fatalf("background health checks: %d", got)
	}
	result, err := handleAvailableTestDelay(&TestDelayParams{ProxyName: "explicit", TestUrl: server.URL})
	if err != nil || result == nil || result.Value < 0 {
		t.Fatalf("manual measurement disabled: %v %v", result, err)
	}
}
