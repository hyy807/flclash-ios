from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class IOSProbeAndSSIDTest(unittest.TestCase):
    def test_ios_skips_missing_wifi_ssid_channel(self):
        source = (ROOT / 'lib/providers/on_demand.dart').read_text()
        body = source.split('Future<void> refresh()', 1)[1].split('  /// Null', 1)[0]
        self.assertIn('system.isIOS', body)
        self.assertLess(body.index('return;'), body.index('checkPermission'))

    def test_foreground_resume_cancels_old_delay_generation(self):
        manager = (ROOT / 'lib/manager/app_manager.dart').read_text()
        self.assertIn('invalidateForResume()', manager)
        source = (ROOT / 'lib/providers/actions/proxies.dart').read_text()
        self.assertIn('generation == _resumeGeneration', source)
        self.assertIn('job.cancelled = true', source)

if __name__ == '__main__':
    unittest.main()
