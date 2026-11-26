import sys, os; sys.path.insert(0, os.path.dirname(__file__))
from musicscan.omr import bars_add_up, reconcile
from test_adopt import page


def test_bars_add_up():
    assert bars_add_up(page(1, [[("C", 1), ("D", 1)], [("E", 1)]])) == [True, False]


def test_takes_second_reading_rest_only_when_it_adds_up():
    rest = lambda d: '<note><rest/><duration>%d</duration></note>' % d  # noqa: E731
    main = page(1, [[("C", 1), ("D", 1)], [("E", 1)]])
    second = page(1, [[("C", 1), ("D", 1)], [("E", 1)]]).replace("</measure></part>", rest(1) + "</measure></part>")
    xml, dis, filled = reconcile(main, second)
    assert filled == {1} and dis == {}
    assert bars_add_up(xml) == [True, True]
