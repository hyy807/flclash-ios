from pathlib import Path
import unittest

class IOSDelayRoutingTest(unittest.TestCase):
    def test_delay_test_is_app_core_method(self):
        source = (Path(__file__).resolve().parents[2] / 'ios/Runner/Core/CoreMessageRouter.swift').read_text()
        app_methods = source.split('private enum ConfigurationCoreMethod', 1)[0]
        self.assertIn('case asyncTestDelay', app_methods)

    def test_delay_test_is_not_configuration_fallback(self):
        source = (Path(__file__).resolve().parents[2] / 'ios/Runner/Core/CoreMessageRouter.swift').read_text()
        config = source.split('private enum ConfigurationCoreMethod', 1)[1].split('private struct CoreRoutingError', 1)[0]
        self.assertNotIn('case asyncTestDelay', config)

    def test_live_delay_prepares_app_only_and_ne_is_read_only(self):
        source = (Path(__file__).resolve().parents[2] / 'ios/Runner/Core/CoreMessageRouter.swift').read_text()
        delay = source.split('if method == AppCoreMethod.asyncTestDelay.rawValue {', 1)[1].split('} else if', 1)[0]
        self.assertLess(delay.index('prepareAppDelayCore()'), delay.index('sendCoreMessage(data, route: .app)'))
        prepare = source.split('private func loadAppDelayCore', 1)[1].split('private func sendRoutedCoreMessage', 1)[0]
        self.assertIn('getDelayTestConfiguration', prepare)
        self.assertIn('"prepareDelayTest"', prepare)
        self.assertNotIn('setupConfig', prepare)
        self.assertNotIn('updateConfig', prepare)
        self.assertIn('revision == configurationRevision', prepare)
        self.assertIn('measurement_core_unavailable', prepare)

    def test_configuration_and_preparation_share_transaction_gate(self):
        source = (Path(__file__).resolve().parents[2] / 'ios/Runner/Core/CoreMessageRouter.swift').read_text()
        for start, end in [('private func loadAppDelayCore', 'private func sendRoutedCoreMessage'), ('private func sendConfigurationMessage', 'private func sendCoreMessage'), ('func shutdownAppCore', 'private func prepareAppDelayCore')]:
            body = source.split(start, 1)[1].split(end, 1)[0]
            self.assertIn('await acquireConfigurationTransaction()', body)
            self.assertIn('defer { releaseConfigurationTransaction() }', body)
        prepare = source.split('private func prepareAppDelayCore', 1)[1].split('private func loadAppDelayCore', 1)[0]
        self.assertIn('preparedDelayRevision == configurationRevision', prepare)
        delay = source.split('if method == AppCoreMethod.asyncTestDelay.rawValue {', 1)[1].split('} else if', 1)[0]
        self.assertIn('revision == configurationRevision', delay)

    def test_private_cache_is_supplied_at_first_app_initialization(self):
        source = (Path(__file__).resolve().parents[2] / 'ios/Runner/Core/CoreMessageRouter.swift').read_text()
        app = source.split('private func sendCoreMessage', 1)[1].split('private func route(', 1)[0]
        self.assertIn('AppCoreMethod.initClash.rawValue', app)
        self.assertIn('"cache-path"', app)

    def test_preparation_preserves_structured_method_failure(self):
        source = (Path(__file__).resolve().parents[2] / 'ios/Runner/Core/CoreMessageRouter.swift').read_text()
        prepare = source.split('private func loadAppDelayCore', 1)[1].split('private func sendRoutedCoreMessage', 1)[0]
        self.assertIn('try requireMethodSuccess(snapshot)', prepare)
        self.assertIn('try requireMethodSuccess(response)', prepare)
        self.assertIn('details: error.details', source)
        self.assertIn('details: failure["details"]', source)

if __name__ == '__main__':
    unittest.main()
