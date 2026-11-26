"""Regressions from real iPhone photos (bench/real_photos.py, 2026-11-26)."""
import numpy as np

from musicscan.omr import doubled_staff, level
from musicscan.preprocess import _hugs_frame


def test_outline_along_the_frame_is_rejected():
    shape = (3600, 2700)
    # i2 on a wood table: the bright grain merged with the page, the outline runs down the photo's right edge
    assert _hugs_frame(np.array([[200, 216], [2696, 0], [2696, 3160], [148, 3212]], np.float32), shape)
    # a corner on a corner of the frame
    assert _hugs_frame(np.array([[236, 296], [1520, 160], [2696, 3596], [252, 3220]], np.float32), shape)
    # the real page of the same photo touches the right side once: kept
    assert not _hugs_frame(np.array([[192, 204], [2696, 196], [2560, 3260], [132, 3224]], np.float32), shape)
    # an angled page whose corner reaches the left side: kept
    assert not _hugs_frame(np.array([[420, 348], [2268, 376], [2652, 2948], [8, 2912]], np.float32), shape)


def test_one_staff_read_twice_is_marked_red():
    # m2 (Brahms viola, shadowed): two boxes 10 px apart over the same staff
    assert doubled_staff([[230, 1965, 582, 2046], [230, 1978, 582, 2054]])
    # a grand staff: treble and bass stacked with a gap
    assert not doubled_staff([[100, 400, 600, 480], [100, 560, 600, 640]])
    assert not doubled_staff([[100, 400, 600, 480]])
    m = {"doubled": True, "n": 5, "min": 0.99}
    assert level(m) == "bad" and level(m, second_reading=True) == "bad"
