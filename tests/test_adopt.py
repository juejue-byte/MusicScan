from musicscan.compare import parse
from musicscan.omr import adopt_bars, disagreement

HEAD = '<?xml version="1.0"?><score-partwise><part-list><score-part id="P1"/></part-list><part id="P1">'


def page(div, bars):
    out = HEAD
    for i, notes in enumerate(bars):
        out += f'<measure number="{i + 1}">'
        if i == 0:
            out += f"<attributes><divisions>{div}</divisions><time><beats>2</beats><beat-type>4</beat-type></time></attributes>"
        for j, (step, d) in enumerate(notes):
            chord = "<chord/>" if step.endswith("+") else ""
            out += f"<note>{chord}<pitch><step>{step[0]}</step><octave>4</octave></pitch><duration>{d * div}</duration></note>"
        out += "</measure>"
    return out + "</part></score-partwise>"


def test_adopts_missing_chord_note_with_other_divisions():
    main = page(1, [[("C", 1), ("D", 1)], [("E", 2)]])
    second = page(4, [[("C", 1), ("D", 1)], [("E", 2), ("G+", 2)]])
    dis = disagreement(main, second)
    assert dis == {1: "missed"}
    new, done = adopt_bars(main, second, {1})
    assert done == {1}
    assert parse(new)["bars"] == parse(second)["bars"]
    assert "<divisions>1</divisions>" in new


def test_leaves_bar_that_cannot_be_rescaled():
    main = page(1, [[("C", 1), ("D", 1)]])
    second = page(2, [[("C", 1), ("D", 1)]]).replace("<duration>2</duration>", "<duration>1</duration>", 1)
    new, done = adopt_bars(main, second, {0})
    assert done == set() and new == main
