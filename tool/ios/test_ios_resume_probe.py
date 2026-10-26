from pathlib import Path
import unittest

class IOSResumeProbeTest(unittest.TestCase):
    def test_resume_invalidates_probe_epoch_and_resubscribes_route(self):
        source = (Path(__file__).resolve().parents[2] / 'lib/providers/route_state.dart').read_text()
        body = source.split('void markResumed()', 1)[1].split('  /// Deferred', 1)[0]
        self.assertIn('hostEpoch: state.hostEpoch + 1', body)
        self.assertIn('synced: false', body)
        self.assertIn('unawaited(_subscribe())', body)

if __name__ == '__main__':
    unittest.main()
