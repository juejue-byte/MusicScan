"""Multi-page: what carries over from the page before (server side), and PDF page selection."""
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from musicscan import imageio  # noqa: E402
from musicscan import sanitize as san  # noqa: E402
from server.app import page_context  # noqa: E402

PIANO_CTX = {"parts": [{"staves": 2, "fifths": -4, "beats": 2, "beat_type": 4, "clefs": {"1": "G2", "2": "F4"}}]}


def page(attrs: str, staves: int = 2) -> str:
    notes = "".join(f'<note><rest/><duration>8</duration><voice>{1 if s == 1 else 5}</voice><staff>{s}</staff></note>'
                    + ('<backup><duration>8</duration></backup>' if s < staves else '') for s in range(1, staves + 1))
    return (f'<score-partwise version="4.0"><part-list><score-part id="P1"><part-name/></score-part></part-list>'
            f'<part id="P1"><measure number="1"><attributes><divisions>4</divisions>{attrs}</attributes>{notes}</measure>'
            f'</part></score-partwise>')


def test_time_carries_when_the_page_prints_none():
    ctx, notes = page_context(page('<key><fifths>-4</fifths></key><staves>2</staves>'), PIANO_CTX)
    p = ctx["parts"][0]
    assert (p["beats"], p["beat_type"]) == (2, 4)
    assert "fifths" not in p          # the page printed its key: keep what was read
    assert p["staves"] == 2 and p["clefs"] == {"1": "G2", "2": "F4"}
    assert notes == []
    xml, _ = san.sanitize(page('<key><fifths>-4</fifths></key><staves>2</staves>'), context=ctx)
    assert "<beats>2</beats>" in xml   # not the 4/4 default


def test_printed_time_wins():
    ctx, _ = page_context(page('<key><fifths>-4</fifths></key><time><beats>3</beats><beat-type>4</beat-type></time>'
                               '<staves>2</staves>'), PIANO_CTX)
    assert "beats" not in ctx["parts"][0]


def test_missing_key_carries_and_a_different_key_is_flagged():
    ctx, notes = page_context(page('<staves>2</staves>'), PIANO_CTX)
    assert ctx["parts"][0]["fifths"] == -4 and notes == []
    ctx, notes = page_context(page('<key><fifths>1</fifths></key><staves>2</staves>'), PIANO_CTX)
    assert "fifths" not in ctx["parts"][0] and notes


def test_layout_lines_up_across_the_page_turn():
    # the next page came back as two one-staff parts: regrouped into the score's grand staff
    two = ('<score-partwise version="4.0"><part-list><score-part id="P1"><part-name/></score-part>'
           '<score-part id="P2"><part-name/></score-part></part-list>'
           + "".join(f'<part id="P{i}"><measure number="1"><attributes><divisions>4</divisions><key><fifths>-4</fifths></key>'
                     f'<clef><sign>{s}</sign><line>{l}</line></clef></attributes><note><rest/><duration>8</duration>'
                     f'<voice>1</voice></note></measure></part>' for i, (s, l) in ((1, ("G", 2)), (2, ("F", 4))))
           + '</score-partwise>')
    ctx, _ = page_context(two, PIANO_CTX)
    xml, _ = san.sanitize(two, context=ctx)
    assert xml.count("<part ") == 1 and "<staves>2</staves>" in xml and "<beats>2</beats>" in xml


def test_no_context_for_a_first_page():
    assert page_context(page(''), None) == (None, [])


def test_pdf_pages():
    from PIL import Image
    buf = io.BytesIO()
    a, b = Image.new("RGB", (400, 300), "white"), Image.new("RGB", (300, 400), "white")
    a.save(buf, format="PDF", save_all=True, append_images=[b])
    data = buf.getvalue()
    from server.app import _pdf_pages
    assert _pdf_pages(data, "x.pdf") == 2
    assert _pdf_pages(b"\x89PNG", "x.png") == 0
    p0, p1 = imageio.load_image(data, "x.pdf", page=0), imageio.load_image(data, "x.pdf", page=1)
    assert p0.width > p0.height and p1.height > p1.width
