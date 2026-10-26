from pathlib import Path
import unittest

class IOSNativeStopTest(unittest.TestCase):
    def test_ios_native_stop_only_adopts_state(self):
        setup = (Path(__file__).resolve().parents[2] / 'lib/providers/actions/setup.dart').read_text()
        self.assertIn('void adoptNativeStopped()', setup)
        body = setup.split('void adoptNativeStopped()', 1)[1].split('Future<bool> setRunning', 1)[0]
        self.assertIn('_setLocalRunning(false)', body)
        self.assertNotIn('setRunning(false)', body)

    def test_android_manager_does_not_call_service_stop_for_ios_native_stop(self):
        source = (Path(__file__).resolve().parents[2] / 'lib/manager/android_manager.dart').read_text()
        body = source.split('void onServiceStopped()', 1)[1].split('  @override\n  Widget build', 1)[0]
        self.assertNotIn("if (system.isIOS) {\n      unawaited(ref.read(setupActionProvider.notifier).setRunning(false));", body)

if __name__ == '__main__':
    unittest.main()
