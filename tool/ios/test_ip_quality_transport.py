from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class IPQualityTransportTest(unittest.TestCase):
    def test_ios_uses_container_core_probe_only(self):
        source = (ROOT / 'lib/providers/ip_quality.dart').read_text()
        self.assertIn('fetch: system.isIOS ? ref.read(coreHandlerProvider).probe : null', source)
        self.assertIn('if (!ref.mounted)', source.split('await lookupIpQuality', 1)[1].split('ref.keepAlive()', 1)[0])

    def test_core_transport_is_bounded_and_keeps_browser_ua(self):
        source = (ROOT / 'lib/common/ip_quality.dart').read_text()
        self.assertIn('IpQualityFetch? fetch', source)
        self.assertIn('timeout: timeout.inMilliseconds', source)
        self.assertIn('maxBody: 256 * 1024', source)
        self.assertIn("headers: const {'User-Agent': browserUa}", source)
        self.assertNotIn('result.message', source)
        self.assertNotIn('InsecureSkipVerify', source)

    def test_cancellation_guards_waves_and_late_answers(self):
        source = (ROOT / 'lib/common/ip_quality.dart').read_text()
        self.assertIn('cancelToken.whenCancel.then(_cancel)', source)
        self.assertIn('bool get _stopped =>', source)
        self.assertGreaterEqual(source.count('if (_stopped)'), 3)


if __name__ == '__main__':
    unittest.main()
