from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class IOSResumeOrderingTest(unittest.TestCase):
    def test_restore_reports_real_tunnel_state(self):
        setup = (ROOT / 'lib/providers/actions/setup.dart').read_text()
        body = setup.split('Future<bool> restoreIOSRunningState()', 1)[1].split('  Future<void> initStatus', 1)[0]
        self.assertIn('Future<bool>', 'Future<bool> restoreIOSRunningState')
        self.assertIn('return started != null', body)

    def test_groups_reload_only_after_restore_and_only_when_running(self):
        source = (ROOT / 'lib/manager/app_manager.dart').read_text()
        body = source.split('if (system.isIOS && ref.read(initProvider))', 1)[1].split('      }', 1)[0]
        self.assertIn('final restored', body)
        self.assertIn('if (restored)', body)
        self.assertLess(body.index('restoreIOSRunningState'), body.index('updateGroups'))

if __name__ == '__main__':
    unittest.main()
