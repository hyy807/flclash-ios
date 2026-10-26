"""Regression guard for the asynchronous QuickSetup C callback ownership."""
from pathlib import Path
import unittest

class CallbackLifetimeTest(unittest.TestCase):
    def test_quick_setup_releases_only_inside_completion(self):
        source = (Path(__file__).resolve().parents[2] / 'core/cmd/ios/main.go').read_text()
        body = source.split('func quickSetup(', 1)[1].split('// startTunOptions', 1)[0]
        before, completion = body.split('core.QuickSetup(', 1)
        self.assertNotIn('go func()', before,
                         'Do not wrap an already asynchronous API in a releasing frame')
        self.assertIn('once.Do(func() {\n\t\t\tdefer releaseObject(callback)', before)
        self.assertIn('finish(message)', completion)

if __name__ == '__main__':
    unittest.main()
