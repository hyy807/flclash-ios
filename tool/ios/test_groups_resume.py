from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class IOSGroupsResumeTest(unittest.TestCase):
    def test_resume_reloads_groups(self):
        source = (ROOT / 'lib/manager/app_manager.dart').read_text()
        body = source.split('if (system.isIOS && ref.read(initProvider))', 1)[1].split('      }', 1)[0]
        self.assertIn('updateGroups()', body)

    def test_empty_group_refresh_does_not_replace_existing_snapshot(self):
        source = (ROOT / 'lib/providers/actions/proxies.dart').read_text()
        body = source.split('Future<void> updateGroups()', 1)[1].split('  void updateCurrentGroupName', 1)[0]
        self.assertIn('if (groups.isNotEmpty)', body)

if __name__ == '__main__':
    unittest.main()
