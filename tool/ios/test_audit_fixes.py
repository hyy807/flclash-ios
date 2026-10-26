from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class AuditFixRegressionTest(unittest.TestCase):
    def test_foreground_refresh_forces_manager_reload(self):
        source = (ROOT / 'ios/Runner/Tunnel/TunnelManagerStore.swift').read_text()
        self.assertIn('func reloadManager(', source)
        coordinator = (ROOT / 'ios/Runner/Tunnel/TunnelCoordinator.swift').read_text()
        self.assertIn('reloadManager(createIfNeeded: false)', coordinator)

    def test_get_proxies_is_serialized_with_config(self):
        source = (ROOT / 'core/proxy.go').read_text()
        body = source.split('func handleGetProxies()', 1)[1].split('\n}', 1)[0]
        self.assertIn('configMu.Lock()', body)
        self.assertIn('defer configMu.Unlock()', body)

    def test_runner_callback_retains_handler_until_main_queue(self):
        source = (ROOT / 'ios/Runner/IOSCoreBridge.m').read_text()
        body = source.split('static void IOSCoreResult', 1)[1].split('static os_log_t', 1)[0]
        self.assertIn('copy];', body)
        self.assertIn('dispatch_async(dispatch_get_main_queue()', body)

if __name__ == '__main__':
    unittest.main()
