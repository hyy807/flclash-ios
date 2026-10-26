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

if __name__ == '__main__':
    unittest.main()
