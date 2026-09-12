"""Cross-component source contract; not a runtime or visual acceptance test."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOST = (ROOT / "MacWSHost/main.m").read_text()
TWEAK = (ROOT / "MacWSWindowing/Tweak.x").read_text()


class BridgeCapabilities(unittest.TestCase):
    def test_published_resize_marker_is_accepted_by_host(self):
        producer = TWEAK[TWEAK.index('dprintf(fd, "version='):]
        published = re.search(r'"(resize=[^ "\\]+)', producer).group(1)
        consumer = HOST[HOST.index('static BOOL MacWSWindowingResizeBridgeIsLoaded(void) {'):]
        consumer = consumer[:consumer.index('\n}')]
        accepted = re.findall(r'@"(resize=[^"\\]+)"', consumer)
        self.assertTrue(any(published.startswith(marker) for marker in accepted),
                        f"Host cannot recognize deployed resize capability: {published}")

    def test_legacy_resize_bridge_remains_supported(self):
        self.assertIn('@"resize=app-layout-transaction"', HOST)

    def test_readiness_still_requires_live_publisher(self):
        self.assertIn('return version >= 29 && publisherAlive &&', HOST)
        self.assertIn('kill(publisherPID, 0)', HOST)


if __name__ == '__main__':
    unittest.main()
