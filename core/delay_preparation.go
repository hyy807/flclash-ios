package core

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"sync"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/listener"
)

type delayPreparationParams struct {
	Digest         string            `json:"digest"`
	SelectedMap    map[string]string `json:"selected-map"`
	TestURL        string            `json:"test-url"`
	SkipCertVerify bool              `json:"skip-cert-verify"`
}

var appliedDelayDigest string
var preparedDelayDigest string

func delayConfigDigest(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func prepareDelayTest(params *delayPreparationParams) error {
	configMu.Lock()
	defer configMu.Unlock()
	unavailable := func(reason string) error {
		return &MethodError{Code: "measurement_core_unavailable", Message: "measurement preparation failed: " + reason, Details: map[string]any{"reason": reason}}
	}
	if !isInit.Load() {
		return unavailable("not_initialized")
	}
	if params == nil || params.Digest == "" {
		return unavailable("missing_digest")
	}
	if isRunning.Load() && appCachePath == "" {
		return unavailable("active_non_app_core")
	}
	if preparedDelayDigest == params.Digest && currentConfig != nil && !isRunning.Load() {
		patchSelectGroup(params.SelectedMap)
		setTestURL(params.TestURL)
		skipCertVerify.Store(params.SkipCertVerify)
		return nil
	}
	data, err := os.ReadFile(filepath.Join(constant.Path.HomeDir(), "config.yaml"))
	if err != nil {
		return unavailable("config_read_failed")
	}
	if delayConfigDigest(data) != params.Digest {
		return unavailable("digest_mismatch")
	}
	raw, err := unmarshalRawConfig(data)
	if err != nil {
		return unavailable("config_decode_failed")
	}
	raw.Port, raw.SocksPort, raw.RedirPort, raw.TProxyPort, raw.MixedPort = 0, 0, 0, 0, 0
	raw.ExternalController, raw.ExternalControllerTLS, raw.ExternalControllerUnix, raw.ExternalControllerPipe = "", "", "", ""
	raw.ExternalUI, raw.ExternalUIURL, raw.ExternalDohServer = "", "", ""
	raw.DNS.Listen = ""
	raw.Tun.Enable, raw.NTP.Enable, raw.GeoAutoUpdate = false, false, false
	raw.ShadowSocksConfig, raw.VmessConfig = "", ""
	raw.TuicServer.Enable = false
	raw.Tunnels = nil
	for _, mapping := range raw.ProxyProvider {
		mapping["interval"] = 0
		mapping["health-check"] = map[string]any{"enable": false}
	}
	for _, group := range raw.ProxyGroup {
		// Measurement groups follow the live core's picks, never run their own scheduler.
		if group["type"] == "url-test" || group["type"] == "fallback" || group["type"] == "load-balance" {
			group["type"] = "select"
		}
		group["interval"] = 0
		delete(group, "url")
	}
	raw.Profile.StoreSelected, raw.Profile.StoreFakeIP = false, false
	raw.Rule, raw.SubRules, raw.RuleProvider = nil, nil, nil
	raw.Sniffer.Enable = false
	raw.Listeners = nil
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		return unavailable("config_parse_failed")
	}
	// App bootstrap can own listeners before the extension takes over forwarding.
	if isRunning.Load() {
		isRunning.Store(false)
		listener.StopListener()
	}
	preparedDelayDigest = ""
	providers := make([]*delayInitialProvider, 0, len(cfg.Providers))
	for name, provider := range cfg.Providers {
		wrapped := &delayInitialProvider{ProxyProvider: provider}
		cfg.Providers[name] = wrapped
		providers = append(providers, wrapped)
	}
	currentConfig = cfg
	hub.ApplyConfig(cfg)
	failed := false
	for _, provider := range providers {
		if err := provider.Initial(); err != nil {
			failed = true
		}
	}
	if failed {
		return unavailable("provider_initialization_failed")
	}
	patchSelectGroup(params.SelectedMap)
	setTestURL(params.TestURL)
	skipCertVerify.Store(params.SkipCertVerify)
	preparedDelayDigest = params.Digest
	return nil
}

type delayInitialProvider struct {
	P.ProxyProvider
	once sync.Once
	err  error
}

func (p *delayInitialProvider) Initial() error {
	p.once.Do(func() { p.err = p.ProxyProvider.Initial() })
	return p.err
}

func delayTestConfiguration() (*delayPreparationParams, error) {
	configMu.Lock()
	defer configMu.Unlock()
	if currentConfig == nil || appliedDelayDigest == "" {
		return nil, &MethodError{Code: "measurement_core_unavailable", Message: "no applied measurement configuration", Details: map[string]any{"reason": "no_applied_configuration"}}
	}
	picks, _ := readPicks()
	return &delayPreparationParams{Digest: appliedDelayDigest, SelectedMap: picks, TestURL: currentTestURL(), SkipCertVerify: skipCertVerify.Load()}, nil
}

func init() {
	registerMethod(CoreMethod("prepareDelayTest"), withMessage(prepareDelayTest))
	registerMethod(CoreMethod("getDelayTestConfiguration"), func(*MethodCall) (any, error) { return delayTestConfiguration() })
}
