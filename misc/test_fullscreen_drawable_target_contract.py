"""Source contract for passive fullscreen catalog and explicit app selection.

The visual acceptance is a live Stray launch with a Host/iPadOS screenshot;
this test only guards the identity boundary that previously oscillated.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
HOST = (ROOT / "MacWSHost/main.m").read_text()
VIEW = (ROOT / "MacWSHost/Rendering/MacWSMetalView.m").read_text()
HEADER = (ROOT / "MacWSHost/Rendering/MacWSMetalView.h").read_text()


class FullscreenDrawableTargetContract(unittest.TestCase):
    def test_completed_drawable_is_only_a_passive_catalog_retention(self):
        selector = HOST.split("- (void)metalView:(MacWSMetalView *)view\n  receivedWindows:", 1)[1]
        selector = selector.split("// An explicit activation carries", 1)[0]
        self.assertIn("_fullscreenActivatedInputOwnerPID == previousPID", selector)
        self.assertIn("[_metalView hasCompletedFullscreenDrawableForPID:previousPID]", selector)
        self.assertIn("retainedPreviousTarget || activatedFullscreenCanvasPresent ||", selector)
        self.assertLess(selector.index("retainedPreviousTarget || activatedFullscreenCanvasPresent ||"),
                        selector.index("_metalView.targetPID = targetPID"))
        self.assertIn("_fullscreenActivatedInputOwnerPID = window.descriptor.ownerPID", HOST)

    def test_first_frame_race_is_covered_before_drawable_arrives(self):
        selector = HOST.split("- (void)metalView:(MacWSMetalView *)view\n  receivedWindows:", 1)[1]
        selector = selector.split("// An explicit activation carries", 1)[0]
        self.assertIn("MacWSStreamWindowFocused |", selector)
        self.assertIn("MacWSStreamWindowFullscreenCanvas", selector)
        self.assertIn("descriptor.ownerPID == previousPID", selector)
        self.assertIn("activatedFullscreenCanvasPresent = YES", selector)
        self.assertNotIn("frame.texture", selector)

    def test_drawable_witness_needs_real_canvas_and_process(self):
        self.assertIn("hasCompletedFullscreenDrawableForPID:", HEADER)
        method = VIEW.split("- (BOOL)hasCompletedFullscreenDrawableForPID:", 1)[1]
        method = method.split("\n}\n", 1)[0]
        for witness in ("ownerPID != self.targetPID",
                        "_fullscreenCanvasPIDs containsObject:@(ownerPID)",
                        "MacWSAppInputEndpointReady(ownerPID)",
                        "frameForOwnerPID:ownerPID", "frame.texture",
                        "MacWSStreamWindowFocused",
                        "MacWSStreamWindowFullscreenCanvas"):
            self.assertIn(witness, method)


if __name__ == "__main__":
    unittest.main()
