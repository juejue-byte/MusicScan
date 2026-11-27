import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from musicscan.omr import merge_slivers
from test_adopt import page


def meta(widths, system=0):
    x, out = 0, []
    for i, w in enumerate(widths):
        out.append({"index": i, "system": system, "bbox": [x, 0, x + w, 50]})
        x += w
    return out


def test_folds_empty_narrow_bar_into_next():
    xml = page(1, [[], [("C", 2)], [("D", 2)], [("E", 2)]])
    out = {"measures": meta([30, 300, 300, 300]), "systems": [{"measures": [0, 1, 2, 3]}]}
    new = merge_slivers(out, xml)
    assert new.count("<measure ") == 3
    assert "<divisions>1</divisions>" in new.split("</measure>")[0]   # the attributes moved to the new first bar
    assert [m["index"] for m in out["measures"]] == [0, 1, 2] and out["systems"][0]["measures"] == [0, 1, 2]


def test_keeps_narrow_bar_with_notes_and_wide_empty_bar():
    xml = page(1, [[("C", 2)], [], [("D", 2)]])
    out = {"measures": meta([30, 300, 300]), "systems": [{"measures": [0, 1, 2]}]}
    assert merge_slivers(out, xml) == xml
