package core

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"

	"github.com/metacubex/mihomo/constant"
)

func isolatedDelayTest(t *testing.T) bool {
	t.Helper()
	if os.Getenv("FLCLASH_DELAY_TEST_CHILD") == "1" {
		return false
	}
	command := exec.Command(os.Args[0], "-test.run=^"+t.Name()+"$", "-test.timeout=20s")
	command.Env = append(os.Environ(), "FLCLASH_DELAY_TEST_CHILD=1")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("measurement subprocess: %v\n%s", err, output)
	}
	return true
}

func TestPrepareDelayTestAfterAppRelaunch(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	home := t.TempDir()
	previousHome := constant.Path.HomeDir()
	t.Cleanup(func() { handleShutdown(); constant.SetHomeDir(previousHome) })
	yaml := []byte("proxies:\n  - {name: usable, type: direct}\nproxy-groups:\n  - {name: Proxy, type: select, proxies: [usable]}\nrules:\n  - MATCH,Proxy\n")
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), yaml, 0600); err != nil {
		t.Fatal(err)
	}
	handleInitClash(&InitParams{HomeDir: home, CachePath: filepath.Join(t.TempDir(), "cache.db")})
	digest := sha256.Sum256(yaml)
	params := &delayPreparationParams{Digest: hex.EncodeToString(digest[:])}
	if err := prepareDelayTest(params); err != nil {
		t.Fatal(err)
	}
	if currentConfig.General.MixedPort != 0 || currentConfig.General.Tun.Enable || len(currentConfig.Rules) != 0 {
		t.Fatal("measurement core retained forwarding state")
	}
	if isRunning.Load() {
		t.Fatal("measurement preparation started listeners")
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer server.Close()
	response := handleMethodCall(&MethodCall{Method: asyncTestDelayMethod, Arguments: json.RawMessage(`{"proxy-name":"usable","test-url":"` + server.URL + `"}`)})
	var decoded struct {
		Result *Delay
		Error  *MethodError
	}
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Error != nil || decoded.Result == nil || decoded.Result.Value < 0 {
		t.Fatalf("usable node failed: %s", response)
	}
	got, err := os.ReadFile(filepath.Join(home, "config.yaml"))
	if err != nil || string(got) != string(yaml) {
		t.Fatal("preparation modified shared config")
	}
}

func TestPrepareDelayTestRejectsStaleOrMissingConfiguration(t *testing.T) {
	home := t.TempDir()
	previousHome := constant.Path.HomeDir()
	t.Cleanup(func() { handleShutdown(); constant.SetHomeDir(previousHome) })
	handleInitClash(&InitParams{HomeDir: home})
	params := &delayPreparationParams{Digest: "not-the-live-config"}
	if err := prepareDelayTest(params); err == nil {
		t.Fatal("missing configuration accepted")
	}
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), []byte("mode: rule\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := prepareDelayTest(params); err == nil {
		t.Fatal("mismatched configuration accepted")
	}
}

func TestDelayPreparationDoesNotSerializeMeasurements(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	home := t.TempDir()
	previousHome := constant.Path.HomeDir()
	t.Cleanup(func() { handleShutdown(); constant.SetHomeDir(previousHome) })
	yaml := []byte("proxies:\n  - {name: usable, type: direct}\n")
	if err := os.WriteFile(filepath.Join(home, "config.yaml"), yaml, 0600); err != nil {
		t.Fatal(err)
	}
	handleInitClash(&InitParams{HomeDir: home})
	digest := sha256.Sum256(yaml)
	if err := prepareDelayTest(&delayPreparationParams{Digest: hex.EncodeToString(digest[:])}); err != nil {
		t.Fatal(err)
	}
	arrived := make(chan struct{}, 10)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { arrived <- struct{}{}; <-release; w.WriteHeader(204) }))
	defer server.Close()
	var wg sync.WaitGroup
	for range 10 {
		wg.Go(func() { handleTestDelay(&TestDelayParams{ProxyName: "usable", TestUrl: server.URL}) })
	}
	for range 10 {
		<-arrived
	}
	close(release)
	wg.Wait()
}

func TestDelayConfigurationDescribesAppliedNotDiskConfig(t *testing.T) {
	if isolatedDelayTest(t) {
		return
	}
	home := t.TempDir()
	constant.SetHomeDir(home)
	handleInitClash(&InitParams{HomeDir: home})
	original := []byte("proxies:\n  - {name: usable, type: direct}\n")
	path := filepath.Join(home, "config.yaml")
	if err := os.WriteFile(path, original, 0600); err != nil {
		t.Fatal(err)
	}
	if err := applyConfig(defaultSetupParams()); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("mode: global\n"), 0600); err != nil {
		t.Fatal(err)
	}
	snapshot, err := delayTestConfiguration()
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Digest != delayConfigDigest(original) {
		t.Fatal("snapshot described unapplied disk config")
	}
	preparedDelayDigest = ""
	appliedDelayDigest = ""
	if err := prepareDelayTest(snapshot); err == nil {
		t.Fatal("accepted disk config that differs from live core")
	}
}

func TestMissingMeasurementProxyIsExplicitError(t *testing.T) {
	response := handleMethodCall(&MethodCall{Method: asyncTestDelayMethod, Arguments: json.RawMessage(`{"proxy-name":"missing-measurement-proxy"}`)})
	var decoded MethodResponse
	if err := json.Unmarshal(response, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Error == nil || decoded.Error.Code != "measurement_core_unavailable" || decoded.Result != nil {
		t.Fatalf("missing measurement proxy fabricated a delay: %s", response)
	}
}
