from pathlib import Path
import unittest

class IOSListenerLifecycleTest(unittest.TestCase):
    def test_ios_suspend_does_not_schedule_listener_stop(self):
        source = (Path(__file__).resolve().parents[2] / 'lib/providers/actions/setup.dart').read_text()
        body = source.split('void syncSuspend() {', 1)[1].split('Future<void> restartVpn', 1)[0]
        self.assertIn('if (system.isIOS)', body)
        self.assertLess(body.index('return;'), body.index('debouncer.call'))

if __name__ == '__main__':
    unittest.main()
