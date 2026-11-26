"""Make OMR MusicXML structurally sound, so every bar adds up and the file opens cleanly in MuseScore 4,
music21, Verovio and our editor.

    xml, report = sanitize(xml)                       # after a full-page read
    xml, report = sanitize(xml, context=ctx)          # after re-reading a row: carry the score's key/time/clefs/layout

What it does, per part and bar (times are exact fractions of a quarter note):
  * every (staff, voice) is a gap-free stream: overlapping notes move to a free voice (or join a chord when they
    start and end together), gaps become rests (hidden in secondary voices)
  * a voice that runs past the bar end is clamped: trailing rests go first, then the last note is shortened;
    notes that start after the bar end are dropped. A bar where *every* voice is short is padded with rests,
    except a pickup (first bar), which is marked implicit
  * notes and rests whose written type does not match their duration are retyped, or split into tied notes /
    several rests; whole-bar rests become measure rests
  * voices are renumbered per staff the MuseScore way (staff 1: 1-4, staff 2: 5-8 ...), every note in a
    multi-staff part carries <staff>, the first bar declares divisions, key, time, staves and one clef per staff
  * parts get the same number of bars and a matching part-list
  * with a context (from the score being edited): the layout is regrouped to match (e.g. two one-staff parts
    -> one grand-staff part), the time signature in force is used (later rows do not print one), and notes are
    re-spelled when the row's key signature was read differently (like the editor's key fix)

The report lists what changed per global bar index, so the UI can flag those bars."""
from __future__ import annotations

import copy
import math
from dataclasses import dataclass, field
from fractions import Fraction as F

from lxml import etree

TYPE_QL = {"maxima": F(32), "long": F(16), "breve": F(8), "whole": F(4), "half": F(2), "quarter": F(1),
           "eighth": F(1, 2), "16th": F(1, 4), "32nd": F(1, 8), "64th": F(1, 16), "128th": F(1, 32)}
WRITE_TYPES = ["whole", "half", "quarter", "eighth", "16th", "32nd", "64th"]
NOTE_ORDER = ["grace", "cue", "chord", "pitch", "unpitched", "rest", "duration", "tie", "instrument", "voice",
              "type", "dot", "accidental", "time-modification", "stem", "notehead", "notehead-text", "staff",
              "beam", "notations", "lyric", "play", "listen"]
ATTR_ORDER = ["footnote", "level", "divisions", "key", "time", "staves", "part-symbol", "instruments", "clef",
              "staff-details", "transpose", "for-part", "directive", "measure-style"]
SHARPS = "FCGDAEB"
DEFAULT_CLEF = {1: ("G", 2), 2: ("F", 4)}
CLEF_NAMES = {"G2": "treble", "F4": "bass", "C3": "alto", "C4": "tenor", "C1": "soprano", "F3": "baritone",
              "G1": "French violin", "C2": "mezzo-soprano", "C5": "baritone (C)", "F5": "sub-bass"}


def key_alter(fifths: int, step: str) -> int:
    if fifths > 0 and step in SHARPS[:fifths]:
        return 1
    if fifths < 0 and step in SHARPS[::-1][:-fifths]:
        return -1
    return 0


def note_value(ql: F) -> tuple[str, int] | None:
    """(type, dots) for a duration that one plain note can show, else None."""
    for t in WRITE_TYPES:
        base = TYPE_QL[t]
        for dots in (0, 1, 2):
            if base * (2 - F(1, 2 ** dots)) == ql:
                return t, dots
    return None


def split_value(ql: F, onset: F = F(0)) -> list[F]:
    """Split a duration into pieces one plain note can each show, following the beat grid: every piece starts on a
    multiple of its own undotted value (so 5/2 quarters from the off-beat is eighth + quarter + quarter)."""
    out = []
    left, t = ql, onset
    while left > 0:
        nv = note_value(left)
        if nv and t % TYPE_QL[nv[0]] == 0:
            out.append(left)
            break
        piece = None
        for name in WRITE_TYPES:
            b = TYPE_QL[name]
            if b <= left and t % b == 0:
                piece = b * 3 / 2 if b * 3 / 2 <= left and t % (2 * b) == 0 else b
                break
        if piece is None:                       # off any 64th grid: take what reaches the next grid point
            piece = min(left, TYPE_QL["64th"] - t % TYPE_QL["64th"])
        out.append(piece)
        left -= piece
        t += piece
    return out


def _strip_ns(root):
    for el in root.iter():
        if isinstance(el.tag, str) and "}" in el.tag:
            el.tag = el.tag.split("}", 1)[1]
    return root


def _txt(el, path, default=None):
    v = el.findtext(path)
    return v.strip() if v is not None and v.strip() != "" else default


def _int(s, default=0):
    try:
        return int(round(float(s)))
    except (TypeError, ValueError):
        return default


def _insert_ordered(parent, el, order):
    rank = order.index(el.tag) if el.tag in order else len(order)
    for i, c in enumerate(parent):
        if c.tag in order and order.index(c.tag) > rank:
            parent.insert(i, el)
            return el
    parent.append(el)
    return el


def _set_child(parent, tag, text, order):
    el = parent.find(tag)
    if el is None:
        el = _insert_ordered(parent, etree.Element(tag), order)
    el.text = str(text)
    return el


# ---------------------------------------------------------------- model
@dataclass
class Event:
    onset: F
    dur: F
    staff: int
    voice: str
    notes: list                      # [head, chord members...] <note> elements
    graces: list = field(default_factory=list)
    rest: bool = False
    tuplet: bool = False
    hidden: bool = False

    @property
    def end(self):
        return self.onset + self.dur


@dataclass
class Other:                         # direction / attributes / harmony ... anchored at a time on a staff
    onset: F
    staff: int
    el: object


@dataclass
class Bar:
    el: object                       # the original <measure> (for its attributes)
    events: list
    others: list
    lead: list                       # <print>, left <barline>, start-of-bar <attributes>
    tail: list                       # right <barline>s
    start_attrs: dict                # attributes in force at the start (after this bar's own)
    length: F                        # nominal length from the time signature


def _attr_state():
    return {"divisions": 1, "fifths": 0, "mode": None, "beats": 4, "beat_type": 4, "staves": 1, "clefs": {},
            "has_time": False, "has_key": False}


def _apply_attrs(a, st):
    d = _txt(a, "divisions")
    if d and _int(d) > 0:
        st["divisions"] = _int(d)
    k = a.find("key")
    if k is not None and k.find("fifths") is not None:
        st["fifths"] = _int(_txt(k, "fifths", "0"))
        st["mode"] = _txt(k, "mode")
        st["has_key"] = True
    t = a.find("time")
    if t is not None and _txt(t, "beats") and _txt(t, "beat-type"):
        try:
            beats = sum(_int(x) for x in _txt(t, "beats").split("+"))
            bt = _int(_txt(t, "beat-type"))
            if beats > 0 and bt > 0:
                st["beats"], st["beat_type"], st["has_time"] = beats, bt, True
        except ValueError:
            pass
    s = _txt(a, "staves")
    if s and _int(s) > 0:
        st["staves"] = _int(s)
    for c in a.findall("clef"):
        n = _int(c.get("number", "1"), 1)
        st["clefs"][n] = (_txt(c, "sign", "G"), _int(_txt(c, "line", "2"), 2), _int(_txt(c, "clef-octave-change", "0")))


def _bar_len(st):
    return F(4 * st["beats"], st["beat_type"])


def _note_ql(n, div):
    if n.find("grace") is not None:
        return F(0)
    d = _txt(n, "duration")
    if d is not None:
        return F(_int(d), div)
    t = TYPE_QL.get(_txt(n, "type", ""), F(1))
    return t * (2 - F(1, 2 ** len(n.findall("dot"))))


def read_part(part) -> tuple[list[Bar], int]:
    """Parse a <part> into bars of time-stamped events. Returns (bars, number of staves)."""
    st = _attr_state()
    bars = []
    max_staff = 1
    for m in part.findall("measure"):
        div = st["divisions"]
        cur = F(0)
        events, others, lead, tail = [], [], [], []
        last = None
        pending_graces = {}
        start = None
        for el in list(m):
            tag = el.tag
            if not isinstance(tag, str):
                continue
            if tag == "attributes":
                at_start = cur == 0
                _apply_attrs(el, st)
                div = st["divisions"]
                if at_start:
                    lead.append(el)
                else:
                    cl = el.find("clef")
                    others.append(Other(cur, _int(cl.get("number", "1"), 1) if cl is not None else 1, el))
            elif tag == "backup":
                cur = max(F(0), cur - F(_int(_txt(el, "duration", "0")), div))
            elif tag == "forward":
                cur += F(_int(_txt(el, "duration", "0")), div)
            elif tag == "note":
                if start is None:
                    start = copy.deepcopy(st)
                staff = max(1, _int(_txt(el, "staff", "1"), 1))
                max_staff = max(max_staff, staff)
                voice = _txt(el, "voice", "1")
                if el.find("grace") is not None:
                    pending_graces.setdefault((staff, voice), []).append(el)
                    continue
                if el.find("chord") is not None and last is not None:
                    last.notes.append(el)
                    continue
                ql = _note_ql(el, div)
                if ql <= 0:
                    ql = TYPE_QL.get(_txt(el, "type", ""), F(1))
                ev = Event(cur, ql, staff, voice, [el], graces=pending_graces.pop((staff, voice), []),
                           rest=el.find("rest") is not None or el.find("pitch") is None and el.find("unpitched") is None,
                           tuplet=el.find("time-modification") is not None,
                           hidden=el.get("print-object") == "no")
                events.append(ev)
                last = ev
                cur += ql
            elif tag == "barline":
                (tail if el.get("location", "right") == "right" else lead).append(el)
            elif tag == "print":
                lead.append(el)
            elif tag in ("direction", "harmony", "figured-bass", "sound", "listening", "grouping", "link", "bookmark"):
                staff = max(1, _int(_txt(el, "staff", "1"), 1))
                others.append(Other(cur, staff, el))
        # graces left at the end of a bar (no following note): keep them on a dummy anchor at the end
        for (staff, voice), gs in pending_graces.items():
            for g in gs:
                others.append(Other(cur, staff, g))
        if start is None:
            start = copy.deepcopy(st)
        # attributes that open the bar count as the bar's own
        bars.append(Bar(m, events, others, lead, tail, start, _bar_len(start)))
        max_staff = max(max_staff, st["staves"])
    return bars, max_staff


# ---------------------------------------------------------------- repairs
def _voices(bar):
    out = {}
    for ev in bar.events:
        out.setdefault((ev.staff, ev.voice), []).append(ev)
    return out


def separate_voices(bar, report, gi):
    """Make every (staff, voice) a strictly sequential stream; overlaps move to another voice of the staff."""
    streams = {}          # staff -> list of (voice, [events])
    for (staff, voice), evs in sorted(_voices(bar).items(), key=lambda kv: (kv[0][0], kv[0][1])):
        lst = streams.setdefault(staff, [])
        lst.append((voice, []))
        for ev in sorted(evs, key=lambda e: e.onset):
            placed = False
            for vv, seq in [s for s in lst if s[0] == voice] + [s for s in lst if s[0] != voice]:
                if seq and ev.onset < seq[-1].end:
                    prev = seq[-1]
                    if (ev.onset == prev.onset and ev.dur == prev.dur and not ev.rest and not prev.rest):
                        for n in ev.notes:            # same start and length: one chord
                            if n.find("chord") is None:
                                _insert_ordered(n, etree.Element("chord"), NOTE_ORDER)
                        prev.notes.extend(ev.notes)
                        placed = True
                        report.note(gi, "merged into a chord")
                        break
                    continue
                seq.append(ev)
                ev.voice = vv
                placed = True
                if vv != voice:
                    report.note(gi, "moved overlapping notes to another voice")
                break
            if not placed:
                nv = f"x{len(lst)}"
                lst.append((nv, [ev]))
                ev.voice = nv
                report.note(gi, "moved overlapping notes to another voice")
    bar.events = [ev for lst in streams.values() for _, seq in lst for ev in seq]


def clamp_voice(seq, length, report, gi):
    """Trim one voice to the bar length."""
    seq.sort(key=lambda e: e.onset)
    end = max((e.end for e in seq), default=F(0))
    if end <= length:
        return seq
    over = end - length
    # 1) trailing rests and rests anywhere: remove/shorten them, shifting later events earlier
    for ev in sorted([e for e in seq if e.rest], key=lambda e: -e.onset):
        if over <= 0:
            break
        cut = min(ev.dur, over)
        ev.dur -= cut
        over -= cut
        for later in seq:
            if later.onset > ev.onset:
                later.onset -= cut
    seq = [e for e in seq if e.dur > 0]
    if over > 0:
        keep = []
        for ev in seq:
            if ev.onset >= length:
                report.note(gi, "dropped notes past the end of the bar")
                continue
            if ev.end > length:
                ev.dur = length - ev.onset
                ev.retime = True
            keep.append(ev)
        seq = keep
    report.note(gi, "trimmed a voice that ran past the bar end")
    return seq


def _voice_ends(bar):
    """The last event of every voice."""
    last = {}
    for ev in bar.events:
        k = (ev.staff, ev.voice)
        if k not in last or ev.end > last[k].end:
            last[k] = ev
    return list(last.values())


def _rest_note(dur_ql, staff, voice, hidden):
    n = etree.Element("note")
    if hidden:
        n.set("print-object", "no")
    etree.SubElement(n, "rest")
    etree.SubElement(n, "duration").text = "0"
    etree.SubElement(n, "voice").text = voice
    ev = Event(F(0), dur_ql, staff, voice, [n], rest=True, hidden=hidden)
    if note_value(dur_ql) is None and note_value(dur_ql * 3 / 2) is not None:
        # a gap inside a triplet (e.g. a missed triplet 16th): a triplet rest, not a pile of 64ths
        t, dots = note_value(dur_ql * 3 / 2)
        etree.SubElement(n, "type").text = t
        for _ in range(dots):
            etree.SubElement(n, "dot")
        tm = etree.SubElement(n, "time-modification")
        etree.SubElement(tm, "actual-notes").text = "3"
        etree.SubElement(tm, "normal-notes").text = "2"
        ev.tuplet = True
    return ev


def fill_voice(seq, upto, staff, voice, primary):
    """Gaps (and a short tail up to `upto`) become hidden rests: a gap in OMR output is usually a note the reader
    missed, so a printed rest there would be wrong. The editor shows them as empty space to click into.
    Only a staff with nothing at all in the bar gets a visible (whole-bar) rest."""
    if not seq and primary:
        r = _rest_note(upto, staff, voice, False)
        return [r] if upto > 0 else []
    out = []
    t = F(0)
    for ev in sorted(seq, key=lambda e: e.onset):
        if ev.onset > t:
            r = _rest_note(ev.onset - t, staff, voice, True)
            r.onset = t
            out.append(r)
        out.append(ev)
        t = max(t, ev.end)
    if t < upto:
        r = _rest_note(upto - t, staff, voice, True)
        r.onset = t
        out.append(r)
    return out


def respell(bars, old_fifths, new_fifths, report, base):
    """Notes that followed the misread key now follow the right one; written accidentals keep their pitch."""
    if old_fifths == new_fifths:
        return
    changed = 0
    for bar in bars:
        for ev in bar.events:
            for n in ev.notes:
                p = n.find("pitch")
                if p is None or n.find("accidental") is not None:
                    continue
                step = _txt(p, "step", "C")
                alter = _int(_txt(p, "alter", "0"))
                if alter == key_alter(old_fifths, step):
                    new = key_alter(new_fifths, step)
                    a = p.find("alter")
                    if new == 0 and a is not None:
                        p.remove(a)
                    elif new != 0:
                        if a is None:
                            a = etree.Element("alter")
                            p.insert(1, a)
                        a.text = str(new)
                    changed += new != alter
    if changed:
        report.note(base, f"re-spelled {changed} notes for the score's key")


class Report:
    def __init__(self):
        self.bars: dict[int, list[str]] = {}
        self.score: list[str] = []

    def note(self, gi, msg):
        lst = self.bars.setdefault(gi, [])
        if msg not in lst:
            lst.append(msg)

    def as_dict(self):
        return {"bars": {str(k): v for k, v in sorted(self.bars.items())}, "score": self.score}


# ---------------------------------------------------------------- emit
def _clear_note_rhythm(n):
    for tag in ("duration", "type"):
        for c in n.findall(tag):
            n.remove(c)
    for c in n.findall("dot"):
        n.remove(c)


def _set_rhythm(n, ql, div, keep_type_if_tuplet):
    _set_child(n, "duration", int(ql * div), NOTE_ORDER)
    if keep_type_if_tuplet and n.find("time-modification") is not None and n.find("type") is not None:
        return
    nv = note_value(ql)
    if nv is None:
        return
    t, dots = nv
    _set_child(n, "type", t, NOTE_ORDER)
    for c in n.findall("dot"):
        n.remove(c)
    for _ in range(dots):
        _insert_ordered(n, etree.Element("dot"), NOTE_ORDER)


def _add_tie(n, kind):
    for t in n.findall("tie"):
        if t.get("type") == kind:
            return
    _insert_ordered(n, etree.Element("tie", type=kind), NOTE_ORDER)
    nots = n.find("notations")
    if nots is None:
        nots = _insert_ordered(n, etree.Element("notations"), NOTE_ORDER)
    etree.SubElement(nots, "tied", type=kind)


def _expand(ev, div, bar_len, whole_bar_rest):
    """The <note> elements for one event, splitting a duration no single note can show."""
    if ev.tuplet:
        for n in ev.notes:
            _set_rhythm(n, ev.dur, div, True)
        return ev.graces + ev.notes
    if ev.rest and whole_bar_rest:
        n = ev.notes[0]
        r = n.find("rest")
        r.set("measure", "yes")
        _set_child(n, "duration", int(ev.dur * div), NOTE_ORDER)
        _set_child(n, "type", "whole", NOTE_ORDER)
        for c in n.findall("dot"):
            n.remove(c)
        return ev.graces + [n]
    if note_value(ev.dur) is not None:
        for n in ev.notes:
            cur_t = _txt(n, "type")
            cur_dots = len(n.findall("dot"))
            if (cur_t, cur_dots) != note_value(ev.dur):
                for b in n.findall("beam"):
                    n.remove(b)
            _set_rhythm(n, ev.dur, div, False)
        return ev.graces + ev.notes
    pieces = split_value(ev.dur, ev.onset)
    out = list(ev.graces)
    for i, q in enumerate(pieces):
        group = ev.notes if i == 0 else [copy.deepcopy(n) for n in ev.notes]
        for n in group:
            for b in n.findall("beam"):
                n.remove(b)
            if i > 0:
                for tag in ("lyric", "accidental"):
                    for c in n.findall(tag):
                        n.remove(c)
                nots = n.find("notations")
                if nots is not None:
                    n.remove(nots)
                for t in n.findall("tie"):
                    n.remove(t)
            _set_rhythm(n, q, div, False)
            if not ev.rest:
                if i > 0:
                    _add_tie(n, "stop")
                if i < len(pieces) - 1:
                    _add_tie(n, "start")
        out.extend(group)
    return out


def _dur_el(tag, ql, div):
    e = etree.Element(tag)
    etree.SubElement(e, "duration").text = str(int(ql * div))
    return e


def emit_bar(m, bar, staves, div, length):
    """Rewrite <measure> m from the repaired bar; every voice is filled to `length`."""
    for c in list(m):
        m.remove(c)
    for el in bar.lead:
        m.append(el)
    implicit = length < bar.length
    streams = {s: {} for s in range(1, staves + 1)}
    for ev in bar.events:
        streams.setdefault(ev.staff, {}).setdefault(ev.voice, []).append(ev)
    for s in streams:
        if not streams[s]:
            streams[s]["1"] = []
    # voice numbers: staff s gets 4(s-1)+1 ... 4s, in order of first onset
    order = []
    for s in sorted(streams):
        vs = sorted(streams[s].items(), key=lambda kv: (min((e.onset for e in kv[1]), default=F(0)), kv[0]))
        for k, (_, seq) in enumerate(vs):
            order.append((s, str(4 * (s - 1) + 1 + k) if k < 4 else str(4 * (s - 1) + 4), k == 0, seq))
    others = sorted(bar.others, key=lambda o: o.onset)
    pos = F(0)
    placed_others = set()
    for s, vnum, primary, seq in order:
        seq = fill_voice(seq, length, s, vnum, primary)
        if pos > 0:
            m.append(_dur_el("backup", pos, div))
            pos = F(0)
        whole_rest = primary and len(seq) == 1 and seq[0].rest and seq[0].dur == length and not implicit
        for ev in seq:
            # directions / mid-bar attributes for this staff, in time order, go into its first voice
            if primary:
                for i, o in enumerate(others):
                    if i in placed_others or o.staff != s or o.onset > ev.onset:
                        continue
                    if o.onset > pos:
                        m.append(_dur_el("forward", o.onset - pos, div))
                        pos = o.onset
                    m.append(o.el)
                    placed_others.add(i)
            if ev.onset > pos:
                m.append(_dur_el("forward", ev.onset - pos, div))
                pos = ev.onset
            for n in _expand(ev, div, length, whole_rest):
                _set_child(n, "voice", vnum, NOTE_ORDER)
                if staves > 1:
                    _set_child(n, "staff", s, NOTE_ORDER)
                else:
                    for c in n.findall("staff"):
                        n.remove(c)
                m.append(n)
            pos = ev.end
        if primary:
            for i, o in enumerate(others):
                if i in placed_others or o.staff != s:
                    continue
                t = min(o.onset, length)
                if t > pos:
                    m.append(_dur_el("forward", t - pos, div))
                    pos = t
                elif t < pos:
                    m.append(_dur_el("backup", pos - t, div))
                    pos = t
                m.append(o.el)
                placed_others.add(i)
    # directions on staves with no notes at all
    for i, o in enumerate(others):
        if i in placed_others:
            continue
        t = min(o.onset, length)
        if t != pos:
            m.append(_dur_el("forward" if t > pos else "backup", abs(t - pos), div))
            pos = t
        if o.el.tag == "direction" and staves > 1:
            _set_child(o.el, "staff", min(o.staff, staves), ["direction-type", "offset", "footnote", "level", "voice", "staff", "sound"])
        m.append(o.el)
    if bar.tail and pos < length:
        m.append(_dur_el("forward", length - pos, div))
    for el in bar.tail:
        m.append(el)


def _first_attrs(m):
    for c in m:
        if c.tag == "note":
            break
        if c.tag == "attributes":
            return c
    a = etree.Element("attributes")
    idx = 0
    for i, c in enumerate(m):
        if c.tag in ("print",) or (c.tag == "barline" and c.get("location") == "left"):
            idx = i + 1
    m.insert(idx, a)
    return a


def _clef_el(n, sign, line, octave=0):
    c = etree.Element("clef", number=str(n))
    etree.SubElement(c, "sign").text = sign
    if sign not in ("percussion", "TAB", "none"):
        etree.SubElement(c, "line").text = str(line)
    if octave:
        etree.SubElement(c, "clef-octave-change").text = str(octave)
    return c


# ---------------------------------------------------------------- regroup parts/staves
def regroup(root, layout: list[int], report):
    """Re-partition the staves of the score into parts with `layout[i]` staves each (same total staff count).
    Used when a row re-read comes back as e.g. two one-staff parts for a grand staff."""
    parts = root.findall("part")
    have = []
    for p in parts:
        _, n = read_part(p)
        have.append(n)
    if have == layout or sum(have) != sum(layout):
        return False
    # flatten: global staff g -> (part element, local staff)
    flat = [(p, s) for p, n in zip(parts, have) for s in range(1, n + 1)]
    nmeas = max(len(p.findall("measure")) for p in parts)
    D = 1
    for p in parts:
        for d in p.iter("divisions"):
            v = max(1, _int(d.text, 1))
            D = D * v // math.gcd(D, v)
    divs = {}
    new_parts = []
    g = 0
    for pi, n in enumerate(layout):
        src = flat[g:g + n]
        g += n
        np_ = etree.Element("part", id=f"P{pi + 1}")
        for mi in range(nmeas):
            nm = None
            for local, (p, s) in enumerate(src, start=1):
                ms = p.findall("measure")
                if mi >= len(ms):
                    continue
                m = ms[mi]
                if nm is None:
                    nm = etree.SubElement(np_, "measure", number=m.get("number", str(mi + 1)))
                    if m.get("implicit"):
                        nm.set("implicit", m.get("implicit"))
                # copy this staff's material, renumbered as `local`, in the common divisions D
                for d in m.iter("divisions"):
                    divs[id(p)] = max(1, _int(d.text, 1))
                div = divs.get(id(p), 1)
                chunk = []
                for c in m:
                    if c.tag == "note":
                        if _int(_txt(c, "staff", "1"), 1) != s:
                            if c.find("chord") is None and c.find("grace") is None:
                                chunk.append(_dur_el("forward", _note_ql(c, div), div))
                            continue
                        cc = copy.deepcopy(c)
                        _set_child(cc, "staff", local, NOTE_ORDER)
                        chunk.append(cc)
                    elif c.tag == "attributes":
                        cc = copy.deepcopy(c)
                        for cl in cc.findall("clef"):
                            if _int(cl.get("number", "1"), 1) != s:
                                cc.remove(cl)
                            else:
                                cl.set("number", str(local))
                        for x in cc.findall("staves"):
                            cc.remove(x)
                        if local > 1:
                            for x in cc.findall("divisions") + cc.findall("key") + cc.findall("time"):
                                cc.remove(x)
                        if len(cc):
                            chunk.append(cc)
                    elif c.tag in ("backup", "forward"):
                        chunk.append(copy.deepcopy(c))
                    elif c.tag == "direction":
                        if _int(_txt(c, "staff", "1"), 1) == s:
                            cc = copy.deepcopy(c)
                            _set_child(cc, "staff", local, ["direction-type", "offset", "footnote", "level", "voice", "staff", "sound"])
                            chunk.append(cc)
                    elif local == 1:
                        chunk.append(copy.deepcopy(c))
                for c in chunk:
                    for d in c.findall("duration"):
                        d.text = str(_int(d.text) * D // div)
                    for d in c.findall("divisions"):
                        d.text = str(D)
                if local > 1:
                    # back up to the bar start (where the merged bar's cursor is now)
                    t = F(0)
                    for c in nm:
                        if c.tag == "backup":
                            t = max(F(0), t - F(_int(_txt(c, "duration", "0")), D))
                        elif c.tag == "forward":
                            t += F(_int(_txt(c, "duration", "0")), D)
                        elif c.tag == "note" and c.find("chord") is None and c.find("grace") is None:
                            t += _note_ql(c, D)
                    if t > 0:
                        nm.append(_dur_el("backup", t, D))
                for c in chunk:
                    nm.append(c)
            if nm is None:
                nm = etree.SubElement(np_, "measure", number=str(mi + 1))
        if n > 1:
            m0 = np_.find("measure")
            a = _first_attrs(m0)
            _set_child(a, "staves", n, ATTR_ORDER)
        new_parts.append(np_)
    for p in parts:
        root.remove(p)
    for np_ in new_parts:
        root.append(np_)
    pl = root.find("part-list")
    if pl is not None:
        for sp in pl.findall("score-part"):
            pl.remove(sp)
    report.score.append(f"regrouped staves {have} into parts {layout}")
    return True


# ---------------------------------------------------------------- main
def sanitize(xml: str | bytes, context: dict | None = None, base: int = 0) -> tuple[str, dict]:
    """context (optional), from the score being edited, describing the bar the result will be spliced at:
        {"parts": [{"staves": 2, "fifths": -1, "beats": 3, "beat_type": 4, "clefs": {"1": "G2", "2": "F4"}}, ...]}
    `base` is the global index of the first bar (for the report)."""
    if isinstance(xml, str):
        xml = xml.encode()
    root = _strip_ns(etree.fromstring(xml, etree.XMLParser(recover=True, huge_tree=True, remove_blank_text=True)))
    if root.tag == "score-timewise":
        raise ValueError("timewise MusicXML is not supported")
    report = Report()
    ctx_parts = (context or {}).get("parts") or []
    if ctx_parts:
        regroup(root, [max(1, int(p.get("staves", 1))) for p in ctx_parts], report)

    parts = root.findall("part")
    nmeas = max((len(p.findall("measure")) for p in parts), default=0)
    prepared = []
    for pi, part in enumerate(parts):
        ctx = ctx_parts[pi] if pi < len(ctx_parts) else None
        ms = part.findall("measure")
        # parts get the same number of bars
        for mi in range(len(ms), nmeas):
            nm = etree.SubElement(part, "measure", number=str(mi + 1))
            ms.append(nm)
        if not ms:
            continue
        # first bar declares everything
        a0 = _first_attrs(ms[0])
        if ctx:
            read_bars, _ = read_part(part)
            read_fifths = read_bars[0].start_attrs["fifths"] if read_bars else 0
            if "beats" in ctx and "beat_type" in ctx:
                for t in a0.findall("time"):
                    a0.remove(t)
                t = _insert_ordered(a0, etree.Element("time"), ATTR_ORDER)
                etree.SubElement(t, "beats").text = str(int(ctx["beats"]))
                etree.SubElement(t, "beat-type").text = str(int(ctx["beat_type"]))
        bars, staves = read_part(part)
        if ctx:
            staves = max(staves, int(ctx.get("staves", 1)))
            if "fifths" in ctx:
                want = int(ctx["fifths"])
                respell(bars, read_fifths, want, report, base)
                k = a0.find("key")
                if k is None:
                    k = _insert_ordered(a0, etree.Element("key"), ATTR_ORDER)
                for c in list(k):
                    k.remove(c)
                etree.SubElement(k, "fifths").text = str(want)
                bars, staves2 = read_part(part)
                staves = max(staves, staves2)
        st0 = bars[0].start_attrs
        if a0.find("divisions") is None:
            _set_child(a0, "divisions", st0["divisions"], ATTR_ORDER)
        if a0.find("key") is None:
            k = _insert_ordered(a0, etree.Element("key"), ATTR_ORDER)
            etree.SubElement(k, "fifths").text = "0"
        if a0.find("time") is None:
            t = _insert_ordered(a0, etree.Element("time"), ATTR_ORDER)
            etree.SubElement(t, "beats").text = "4"
            etree.SubElement(t, "beat-type").text = "4"
            report.score.append(f"part {pi + 1}: no time signature was read; assumed 4/4")
        if staves > 1:
            _set_child(a0, "staves", staves, ATTR_ORDER)
        else:
            for s in a0.findall("staves"):
                a0.remove(s)
        have = {_int(c.get("number", "1"), 1) for c in a0.findall("clef")}
        for c in a0.findall("clef"):
            if _int(c.get("number", "1"), 1) > staves:
                a0.remove(c)
            else:
                c.set("number", c.get("number", "1"))
        for s in range(1, staves + 1):
            if s not in have:
                cl = (ctx or {}).get("clefs", {}).get(str(s))
                sign, line = (cl[0], int(cl[1])) if cl else DEFAULT_CLEF.get(s, ("F", 4))
                _insert_ordered(a0, _clef_el(s, sign, line), ATTR_ORDER)
                if not cl:
                    report.score.append(f"part {pi + 1}: no clef read on staff {s}; assumed {CLEF_NAMES.get(f'{sign}{line}', sign)}")
        # reorder attribute children canonically
        kids = sorted(list(a0), key=lambda c: (ATTR_ORDER.index(c.tag) if c.tag in ATTR_ORDER else 99,
                                              _int(c.get("number", "1"), 1)))
        for c in kids:
            a0.remove(c)
        for c in kids:
            a0.append(c)

        bars, _ = read_part(part)
        # one divisions value for the whole part: lcm of every denominator in use
        dens = {1}
        for b in bars:
            for ev in b.events:
                dens.add(ev.onset.denominator)
                dens.add(ev.dur.denominator)
                if not ev.tuplet and note_value(ev.dur) is None:
                    dens.update(q.denominator for q in split_value(ev.dur, ev.onset))
            dens.add(b.length.denominator)
        div = 1
        for d in dens:
            div = div * d // math.gcd(div, d)
        div = max(div, bars[0].start_attrs["divisions"] if div == 1 else div)
        for b in bars:
            for a in b.lead + [o.el for o in b.others if o.el.tag == "attributes"]:
                for d in a.findall("divisions"):
                    a.remove(d)
        _set_child(a0, "divisions", div, ATTR_ORDER)

        for mi, bar in enumerate(bars):
            gi = base + mi
            separate_voices(bar, report, gi)
            new_events = []
            for (s, v), seq in _voices(bar).items():
                new_events.extend(clamp_voice(seq, bar.length, report, gi))
            bar.events = new_events
        prepared.append((part, ms, bars, staves, div, a0))

    # how long each bar really is, over all parts: a bar every part plays short is a real irregular bar (a pickup,
    # or a bar split around a repeat), anything shorter than that in one voice is a reading gap
    used = [F(0)] * nmeas
    for _, _, bars, _, _, _ in prepared:
        for mi, bar in enumerate(bars):
            used[mi] = max(used[mi], max((e.end for e in bar.events), default=F(0)))
    for part, ms, bars, staves, div, a0 in prepared:
        for mi, (m, bar) in enumerate(zip(ms, bars)):
            gi = base + mi
            length = bar.length
            u = used[mi]
            if 0 < u < length and (context is None or mi > 0):
                length = u
                if mi == 0:
                    m.set("implicit", "yes")
            elif "implicit" in m.attrib:
                del m.attrib["implicit"]
            if any(e.end < length for e in _voice_ends(bar)):
                report.note(gi, "a voice has a gap (missed note?), kept as space")
            emit_bar(m, bar, staves, div, length)
            m.set("number", str(mi if ms[0].get("implicit") == "yes" else mi + 1))
            if "width" in m.attrib:
                del m.attrib["width"]
        # drop empty mid-bar <attributes>
        for a in list(part.iter("attributes")):
            if len(a) == 0 and a is not a0:
                a.getparent().remove(a)

    _fix_part_list(root)
    out = etree.tostring(root, xml_declaration=True, encoding="UTF-8", pretty_print=True,
                         doctype='<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" '
                                 '"http://www.musicxml.org/dtds/partwise.dtd">')
    return out.decode(), report.as_dict()


def _fix_part_list(root):
    parts = root.findall("part")
    pl = root.find("part-list")
    if pl is None:
        pl = etree.Element("part-list")
        idx = 0
        for i, c in enumerate(root):
            if c.tag in ("work", "movement-number", "movement-title", "identification", "defaults", "credit"):
                idx = i + 1
        root.insert(idx, pl)
    known = {sp.get("id"): sp for sp in pl.findall("score-part")}
    seen = set()
    for i, p in enumerate(parts):
        pid = p.get("id") or f"P{i + 1}"
        if pid in seen:
            pid = f"P{i + 1}x"
        p.set("id", pid)
        seen.add(pid)
        if pid not in known:
            sp = etree.SubElement(pl, "score-part", id=pid)
            etree.SubElement(sp, "part-name").text = "Piano" if _staves_of(p) == 2 else f"Part {i + 1}"
        elif known[pid].find("part-name") is None:
            known[pid].insert(0, etree.Element("part-name"))
    for pid, sp in known.items():
        if pid not in seen:
            pl.remove(sp)


def _staves_of(p):
    s = p.findtext("measure/attributes/staves")
    return _int(s, 1) if s else 1


def context_at(xml: str | bytes, bar: int) -> dict:
    """The layout, key, time and clefs in force at global bar `bar` of a score (for rescans)."""
    if isinstance(xml, str):
        xml = xml.encode()
    root = _strip_ns(etree.fromstring(xml, etree.XMLParser(recover=True, huge_tree=True)))
    out = []
    for p in root.findall("part"):
        bars, staves = read_part(p)
        if not bars:
            continue
        st = bars[min(bar, len(bars) - 1)].start_attrs
        clefs = {str(n): f"{c[0]}{c[1]}" for n, c in st["clefs"].items()}
        out.append({"staves": staves, "fifths": st["fifths"], "beats": st["beats"], "beat_type": st["beat_type"],
                    "clefs": clefs})
    return {"parts": out}


def check(xml: str | bytes) -> list[str]:
    """Structural problems MuseScore and the editor care about (empty list = clean)."""
    if isinstance(xml, str):
        xml = xml.encode()
    root = _strip_ns(etree.fromstring(xml, etree.XMLParser(recover=True, huge_tree=True)))
    probs = []
    parts = root.findall("part")
    ids = {sp.get("id") for sp in root.findall("part-list/score-part")}
    counts = {len(p.findall("measure")) for p in parts}
    if len(counts) > 1:
        probs.append(f"parts have different bar counts {sorted(counts)}")
    bar_used = {}
    per_part = []
    for pi, p in enumerate(parts):
        if p.get("id") not in ids:
            probs.append(f"part {pi + 1} missing from part-list")
        bars, staves = read_part(p)
        ms = p.findall("measure")
        a0 = ms[0].find("attributes") if ms else None
        if a0 is None:
            probs.append(f"part {pi + 1}: first bar has no attributes")
            continue
        for tag in ("divisions", "key", "time"):
            if a0.find(tag) is None:
                probs.append(f"part {pi + 1}: first bar has no {tag}")
        clefs = {_int(c.get("number", "1"), 1) for c in a0.findall("clef")}
        if clefs != set(range(1, staves + 1)):
            probs.append(f"part {pi + 1}: clefs {sorted(clefs)} for {staves} staves")
        if staves > 1 and _int(_txt(a0, "staves", "1")) != staves:
            probs.append(f"part {pi + 1}: <staves> missing or wrong")
        for mi, (m, bar) in enumerate(zip(ms, bars)):
            ends = {}
            for ev in bar.events:
                k = (ev.staff, ev.voice)
                if ev.onset < ends.get(k, F(0)):
                    probs.append(f"part {pi + 1} bar {mi + 1}: overlapping notes in voice {k}")
                ends[k] = ev.end
                if staves > 1 and any(n.find("staff") is None for n in ev.notes):
                    probs.append(f"part {pi + 1} bar {mi + 1}: note without <staff>")
                if not ev.tuplet and not (ev.rest and ev.notes[0].find("rest").get("measure") == "yes"):
                    t = _txt(ev.notes[0], "type")
                    if t and note_value(ev.dur) != (t, len(ev.notes[0].findall("dot"))):
                        probs.append(f"part {pi + 1} bar {mi + 1}: {t} note lasting {ev.dur} quarters")
            per_part.append((pi, mi, ends, bar.length))
            bar_used[mi] = max(bar_used.get(mi, F(0)), max(ends.values(), default=F(0)))
    for pi, mi, ends, length in per_part:
        want = min(length, bar_used[mi]) if bar_used[mi] else length
        for k, e in ends.items():
            if e != want:
                probs.append(f"part {pi + 1} bar {mi + 1}: voice {k} lasts {e} of {want} quarters")
    return probs
