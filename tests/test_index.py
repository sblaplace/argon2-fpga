"""index_alpha must match the PHC reference mapping used by the RTL."""

from __future__ import annotations

import unittest

from ref.argon2 import index_alpha


class IndexAlpha(unittest.TestCase):
    def test_first_segment_grows(self) -> None:
        # pass=0, slice=0, same lane: |W| = index - 1, start = 0
        z = index_alpha(
            pass_=0,
            slice_=0,
            index=5,
            lane_length=32,
            segment_length=8,
            pseudo_rand_lo=0,
            same_lane=True,
        )
        # J1=0 → rel = |W|-1 - 0 = 3, z = 3
        self.assertEqual(z, 3)

    def test_j1_all_ones_picks_near_start(self) -> None:
        z = index_alpha(
            pass_=0,
            slice_=0,
            index=5,
            lane_length=32,
            segment_length=8,
            pseudo_rand_lo=0xFFFFFFFF,
            same_lane=True,
        )
        # Large J1 maps close to the beginning of W (recent-biased).
        self.assertEqual(z, 0)

    def test_later_pass_wraps_window(self) -> None:
        z = index_alpha(
            pass_=1,
            slice_=0,
            index=3,
            lane_length=32,
            segment_length=8,
            pseudo_rand_lo=0,
            same_lane=True,
        )
        # |W| = 32-8+3-1 = 26, rel = 25, start = 8, z = (8+25)%32 = 1
        self.assertEqual(z, 1)


if __name__ == "__main__":
    unittest.main()
