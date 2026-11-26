"""The MusicXML sanitizer: OMR-style damage in, structurally clean MusicXML out, music unchanged where it was right.
Run: python -m pytest tests/test_sanitize.py -q"""
import sys
from fractions import Fraction as F
from pathlib import Path

import pytest
from lxml import etree

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from musicscan.compare import compare, parse  # noqa: E402
from musicscan.sanitize import check, context_at, sanitize, split_value, note_value  # noqa: E402

DATA = ROOT / "bench" / "data"
FIXTURES = sorted(DATA.glob("*.musicxml"))


def score(parts, staves=None, clefs=None, beats=4, beat_type=4, fifths=0, divisions=2):
    """Tiny MusicXML builder. parts: list of parts; a part is a list of bars; a bar is a list of
    (staff, voice, kind, quarters) with kind 'C4' / 'r' / 'backup'."""
    staves = staves or [1] * len(parts)
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<score-partwise version="4.0"><part-list>']
    for i in range(len(parts)):
        out.append(f'<score-part id="P{i + 1}"><part-name>P{i + 1}</part-name></score-part>')
    out.append("</part-list>")
    for pi, bars in enumerate(parts):
        out.append(f'<part id="P{pi + 1}">')
        for mi, bar in enumerate(bars):
            out.append(f'<measure number="{mi + 1}">')
            if mi == 0:
                cl = (clefs or [None] * len(parts))[pi] or ["G2", "F4"][: staves[pi]]
                out.append(f"<attributes><divisions>{divisions}</divisions><key><fifths>{fifths}</fifths></key>")
                if beats:
                    out.append(f"<time><beats>{beats}</beats><beat-type>{beat_type}</beat-type></time>")
                if staves[pi] > 1:
                    out.append(f"<staves>{staves[pi]}</staves>")
                for n, c in enumerate(cl, 1):
                    out.append(f'<clef number="{n}"><sign>{c[0]}</sign><line>{c[1]}</line></clef>')
                out.append("</attributes>")
            for staff, voice, kind, q in bar:
                d = int(q * divisions)
                if kind == "backup":
                    out.append(f"<backup><duration>{d}</duration></backup>")
                    continue
                nv = note_value(F(q).limit_denominator(64))
                typ = f"<type>{nv[0]}</type>" + "<dot/>" * nv[1] if nv else "<type>quarter</type>"
                body = "<rest/>" if kind == "r" else (
                    f"<pitch><step>{kind[0]}</step>{'<alter>' + kind[1:-1] + '</alter>' if len(kind) > 2 else ''}"
                    f"<octave>{kind[-1]}</octave></pitch>")
                st = f"<staff>{staff}</staff>" if staves[pi] > 1 else ""
                out.append(f"<note>{body}<duration>{d}</duration><voice>{voice}</voice>{typ}{st}</note>")
            out.append("</measure>")
        out.append("</part>")
    out.append("</score-partwise>")
    return "".join(out)


def voice_lengths(xml):
    """{(part, bar, staff, voice): quarters} from the sanitized output."""
    root = etree.fromstring(xml.encode())
    out = {}
    for pi, p in enumerate(root.findall("part")):
        div = 1
        for mi, m in enumerate(p.findall("measure")):
            for d in m.iter("divisions"):
                div = int(d.text)
            for n in m.findall("note"):
                if n.find("chord") is not None or n.find("grace") is not None:
                    continue
                k = (pi, mi, n.findtext("staff", "1"), n.findtext("voice"))
                out[k] = out.get(k, F(0)) + F(int(n.findtext("duration")), div)
    return out


def notes(xml):
    """Pitched notes as (part, staff, onset-in-score, midi) for every stream (what you hear)."""
    p = parse(xml)
    return sorted((k, e) for k, evs in p["streams"].items() for e in evs if e[0] != "r")


# ---------------------------------------------------------------- real scores survive untouched
@pytest.mark.parametrize("path", FIXTURES, ids=[p.stem for p in FIXTURES])
def test_ground_truth_unchanged(path):
    x = path.read_text()
    y, rep = sanitize(x)
    r = compare(x, y)
    assert r["note_f1"] == 1.0 and r["ser"] == 0.0, r
    assert rep["bars"] == {}, rep
    assert check(y) == []
    # running it twice changes nothing more
    z, _ = sanitize(y)
    assert z == y


@pytest.mark.parametrize("name,clefs", [("beethoven_18_viola", {"C3"}), ("haydn_74_viola", {"C3"}),
                                        ("beethoven_18_vc", {"F4"}), ("mozart_k545", {"G2", "F4"})])
def test_clefs_kept(name, clefs):
    p = DATA / f"{name}.musicxml"
    if not p.exists():
        pytest.skip("fixture missing")
    y, _ = sanitize(p.read_text())
    root = etree.fromstring(y.encode())
    first = root.find("part/measure/attributes")
    got = {c.findtext("sign") + c.findtext("line") for c in first.findall("clef")}
    assert clefs <= got | {c.findtext("sign") + c.findtext("line") for c in root.iter("clef")}


# ---------------------------------------------------------------- bar arithmetic
def test_overfull_voice_trimmed_rests_first():
    x = score([[[(1, "1", "C4", 1), (1, "1", "r", 1), (1, "1", "D4", 1), (1, "1", "E4", 1), (1, "1", "F4", 1)]]])
    y, rep = sanitize(x)
    assert check(y) == []
    assert voice_lengths(y)[(0, 0, "1", "1")] == 4
    assert [e[0] for e in parse(y)["streams"][(0, "1")]] != []
    pitches = [n.findtext("pitch/step") for n in etree.fromstring(y.encode()).iter("note") if n.find("rest") is None]
    assert pitches == ["C", "D", "E", "F"]          # the rest made room, every note kept
    assert "trimmed" in " ".join(rep["bars"]["0"])


def test_overfull_without_rests_shortens_last_note():
    x = score([[[(1, "1", "C4", 2), (1, "1", "D4", 2), (1, "1", "E4", 1)]]])
    y, _ = sanitize(x)
    assert check(y) == []
    assert voice_lengths(y)[(0, 0, "1", "1")] == 4


def test_short_voice_in_grand_staff_padded():
    # treble full, bass has only 3 beats: a rest is added in the bass, not a short bar
    x = score([[[(1, "1", "C5", 4), (1, "1", "backup", 4), (2, "2", "C3", 1), (2, "2", "D3", 2)],
                [(1, "1", "D5", 4), (1, "1", "backup", 4), (2, "2", "E3", 4)]]], staves=[2])
    y, rep = sanitize(x)
    assert check(y) == []
    lens = voice_lengths(y)
    assert lens[(0, 0, "1", "1")] == 4 and lens[(0, 0, "2", "5")] == 4
    assert "gap" in " ".join(rep["bars"]["0"])
    rests = [n for n in etree.fromstring(y.encode()).iter("note") if n.find("rest") is not None]
    assert rests and all(n.get("print-object") == "no" for n in rests)   # a gap is not a printed rest


def test_pickup_and_split_bar_kept():
    x = score([[[(1, "1", "G4", 1)], [(1, "1", "C5", 4)], [(1, "1", "D5", 3)]]])
    y, _ = sanitize(x)
    root = etree.fromstring(y.encode())
    ms = root.findall("part/measure")
    assert ms[0].get("implicit") == "yes" and ms[0].get("number") == "0"
    assert voice_lengths(y)[(0, 0, "1", "1")] == 1   # not padded
    assert check(y) == []


def test_overlap_moves_to_second_voice():
    # OMR put two melodic lines in voice 1 of one staff
    x = score([[[(1, "1", "E5", 2), (1, "1", "F5", 2), (1, "1", "backup", 4), (1, "1", "C5", 4)]]])
    y, _ = sanitize(x)
    assert check(y) == []
    voices = {n.findtext("voice") for n in etree.fromstring(y.encode()).iter("note")}
    assert voices == {"1", "2"}
    assert len(notes(y)) == len(notes(x))


def test_same_start_same_length_becomes_chord():
    x = score([[[(1, "1", "C4", 4), (1, "1", "backup", 4), (1, "1", "E4", 4)]]])
    y, _ = sanitize(x)
    ns = list(etree.fromstring(y.encode()).iter("note"))
    assert len(ns) == 2 and ns[1].find("chord") is not None


# ---------------------------------------------------------------- note values
def test_odd_rest_split_on_beats():
    assert split_value(F(5, 2), F(1, 2)) == [F(1, 2), F(1), F(1)]
    assert split_value(F(11, 4), F(5, 4)) == [F(1, 4), F(1, 2), F(2)]
    assert split_value(F(3), F(1)) == [F(1), F(2)]
    x = score([[[(1, "1", "C4", F(3, 2)), (1, "1", "r", F(5, 2))]]])
    y, _ = sanitize(x)
    assert check(y) == []
    rests = [(n.findtext("type"), len(n.findall("dot"))) for n in etree.fromstring(y.encode()).iter("note")
             if n.find("rest") is not None]
    assert rests == [("eighth", 0), ("half", 0)]


def test_unwritable_note_becomes_tied_notes():
    x = score([[[(1, "1", "C4", F(5, 4)), (1, "1", "D4", F(11, 4))]]], divisions=4)
    y, _ = sanitize(x)
    assert check(y) == []
    c = [n for n in etree.fromstring(y.encode()).iter("note") if n.findtext("pitch/step") == "C"]
    assert len(c) == 2 and c[0].find("tie[@type='start']") is not None and c[1].find("tie[@type='stop']") is not None
    # still sounds the same: tied pieces add up to the original lengths
    import music21
    sounding = [(n.pitch.nameWithOctave, n.quarterLength)
                for n in music21.converter.parse(y, format="musicxml").stripTies().recurse().notes]
    assert sounding == [("C4", 1.25), ("D4", 2.75)]


def test_whole_bar_rest_is_measure_rest():
    x = score([[[(1, "1", "r", 3)]], ], beats=3)
    y, _ = sanitize(x)
    r = etree.fromstring(y.encode()).find(".//rest")
    assert r.get("measure") == "yes"


def test_mismatched_type_is_retyped():
    x = score([[[(1, "1", "C4", 4)]]]).replace("<type>whole</type>", "<type>quarter</type>")
    y, _ = sanitize(x)
    assert etree.fromstring(y.encode()).findtext(".//note/type") == "whole"


# ---------------------------------------------------------------- multi-staff structure
def test_missing_bass_clef_and_staff_numbers_added():
    x = score([[[(1, "1", "C5", 4), (1, "1", "backup", 4), (2, "2", "C3", 4)]]], staves=[2], clefs=[["G2"]])
    y, rep = sanitize(x)
    assert check(y) == []
    a = etree.fromstring(y.encode()).find(".//attributes")
    assert [(c.get("number"), c.findtext("sign")) for c in a.findall("clef")] == [("1", "G"), ("2", "F")]
    assert a.findtext("staves") == "2"
    assert any("assumed bass" in s for s in rep["score"])


def test_voices_numbered_per_staff():
    # both staves use voice 1 in the OMR output: MuseScore expects staff 2 to use voices 5-8
    x = score([[[(1, "1", "C5", 4), (1, "1", "backup", 4), (2, "1", "C3", 4)]]], staves=[2])
    y, _ = sanitize(x)
    got = {(n.findtext("staff"), n.findtext("voice")) for n in etree.fromstring(y.encode()).iter("note")}
    assert got == {("1", "1"), ("2", "5")}


def test_missing_time_signature_assumed_and_reported():
    x = score([[[(1, "1", "C4", 4)]]], beats=None)
    y, rep = sanitize(x)
    assert check(y) == [] and any("4/4" in s for s in rep["score"])


def test_parts_get_equal_bar_counts_and_part_list():
    x = score([[[(1, "1", "C5", 4)], [(1, "1", "D5", 4)]], [[(1, "1", "C3", 4)]]], clefs=[["G2"], ["F4"]])
    x = x.replace('<score-part id="P2"><part-name>P2</part-name></score-part>', "")
    y, _ = sanitize(x)
    assert check(y) == []
    root = etree.fromstring(y.encode())
    assert [len(p.findall("measure")) for p in root.findall("part")] == [2, 2]
    assert len(root.findall("part-list/score-part")) == 2


def test_divisions_unified():
    x = score([[[(1, "1", "C4", F(1, 3)), (1, "1", "C4", F(1, 3)), (1, "1", "C4", F(1, 3)), (1, "1", "D4", 3)]]],
              divisions=3)
    x = x.replace("<type>quarter</type>", "<type>eighth</type><time-modification><actual-notes>3</actual-notes>"
                  "<normal-notes>2</normal-notes></time-modification>", 3)
    y, _ = sanitize(x)
    assert check(y) == []
    assert compare(x, y)["note_f1"] == 1.0


# ---------------------------------------------------------------- rescan context
def test_context_regroups_two_parts_into_grand_staff():
    # a re-read row came back as two one-staff parts; the score is one piano part with two staves
    x = score([[[(1, "1", "E5", 2), (1, "1", "G5", 2)]], [[(1, "1", "C3", 4)]]], clefs=[["G2"], ["F4"]])
    ctx = {"parts": [{"staves": 2, "fifths": 0, "beats": 4, "beat_type": 4, "clefs": {"1": "G2", "2": "F4"}}]}
    y, rep = sanitize(x, context=ctx, base=8)
    assert check(y) == []
    root = etree.fromstring(y.encode())
    assert len(root.findall("part")) == 1 and root.findtext(".//staves") == "2"
    got = sorted((n.findtext("staff"), n.findtext("pitch/step") + n.findtext("pitch/octave"))
                 for n in root.iter("note"))
    assert got == [("1", "E5"), ("1", "G5"), ("2", "C3")]
    assert any("regrouped" in s for s in rep["score"])


def test_context_carries_time_signature():
    # later rows print no time signature; the reader assumes 4/4. 3/4 bars must not be padded to 4/4
    x = score([[[(1, "1", "C4", 3)], [(1, "1", "D4", 1), (1, "1", "E4", 2)]]], beats=None)
    ctx = {"parts": [{"staves": 1, "fifths": 0, "beats": 3, "beat_type": 4, "clefs": {"1": "G2"}}]}
    y, rep = sanitize(x, context=ctx, base=4)
    assert check(y) == []
    root = etree.fromstring(y.encode())
    assert root.findtext(".//time/beats") == "3"
    assert voice_lengths(y)[(0, 0, "1", "1")] == 3 and voice_lengths(y)[(0, 1, "1", "1")] == 3
    assert root.find("part/measure").get("implicit") is None      # a row's first bar is never a pickup
    assert rep["score"] == []


def test_context_respells_misread_key():
    # the row was read in C major, the score is in F major: B (no accidental) is B-flat; a printed natural stays
    x = score([[[(1, "1", "B4", 1), (1, "1", "A4", 1), (1, "1", "B4", 1), (1, "1", "C5", 1)]]])
    x = x.replace("<octave>4</octave></pitch><duration>2</duration><voice>1</voice><type>quarter</type></note>"
                  "<note><pitch><step>C</step>",
                  "<octave>4</octave></pitch><duration>2</duration><voice>1</voice><type>quarter</type>"
                  "<accidental>natural</accidental></note><note><pitch><step>C</step>")
    ctx = {"parts": [{"staves": 1, "fifths": -1, "beats": 4, "beat_type": 4, "clefs": {"1": "G2"}}]}
    y, _ = sanitize(x, context=ctx, base=3)
    root = etree.fromstring(y.encode())
    bs = [n.findtext("pitch/alter") for n in root.iter("note") if n.findtext("pitch/step") == "B"]
    assert bs == ["-1", None]
    assert root.findtext(".//key/fifths") == "-1"


def test_context_at_reads_state_in_force():
    p = DATA / "beethoven_18_viola.musicxml"
    if not p.exists():
        pytest.skip("fixture missing")
    c = context_at(p.read_text(), 10)
    assert c["parts"][0]["clefs"]["1"] == "C3" and c["parts"][0]["staves"] == 1
    c = context_at((DATA / "mozart_k545.musicxml").read_text(), 5)
    assert c["parts"][0]["staves"] == 2 and c["parts"][0]["clefs"] == {"1": "G2", "2": "F4"}


def test_regroup_with_different_divisions():
    a = score([[[(1, "1", "E5", 2), (1, "1", "G5", 2)], [(1, "1", "A5", 4)]]], divisions=1)
    b = score([[[(1, "1", "C3", 1), (1, "1", "D3", 3)], [(1, "1", "F3", 4)]]], clefs=[["F4"]], divisions=8)
    root = etree.fromstring(a.encode())
    p2 = etree.fromstring(b.encode()).find("part")
    p2.set("id", "P2")
    root.append(p2)
    root.find("part-list").append(etree.fromstring('<score-part id="P2"><part-name>B</part-name></score-part>'))
    x = etree.tostring(root).decode()
    ctx = {"parts": [{"staves": 2, "fifths": 0, "beats": 4, "beat_type": 4, "clefs": {"1": "G2", "2": "F4"}}]}
    y, _ = sanitize(x, context=ctx, base=0)
    assert check(y) == []
    import music21
    s = music21.converter.parse(y, format="musicxml")
    got = sorted((float(n.getOffsetInHierarchy(s)), n.pitch.nameWithOctave, float(n.quarterLength))
                 for n in s.recurse().notes)
    assert got == [(0.0, "C3", 1.0), (0.0, "E5", 2.0), (1.0, "D3", 3.0), (2.0, "G5", 2.0), (4.0, "A5", 4.0),
                   (4.0, "F3", 4.0)]
