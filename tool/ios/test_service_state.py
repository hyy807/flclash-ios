from pathlib import Path
import unittest

class ServiceStateTest(unittest.TestCase):
    def test_only_disconnected_state_reports_stopped(self):
        source = (Path(__file__).resolve().parents[2] / 'ios/Runner/ServiceChannel.swift').read_text()
        callback = source.split('onConnectionStateChanged: { state in', 1)[1].split('onExternalStart:', 1)[0]
        self.assertIn('guard state == "disconnected"', callback)
        self.assertIn('let revision = revisionBox.value', callback)
        self.assertIn('arguments: revision)', callback)
        self.assertNotIn('arguments: revisionBox.value)', callback)

if __name__ == '__main__':
    unittest.main()
