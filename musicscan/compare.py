"""Score an OMR MusicXML against ground truth.

Each score is flattened into streams, one per (part, staff). A stream is the time-ordered list of events
"pitch/duration" (rests "r/duration"; chords as several events at the same onset, pitch-sorted).
Streams are paired between prediction and truth (Hungarian on alignment score), then aligned with an LCS.

Reported (over all ground-truth events):
  note_f1   pitch + duration must both match (rests included)
  pitch_f1  notes only, pitch must match (ignores rhythm)
  ser       symbol error rate: edit distance / ground-truth events (like OMR-NED, simplified)
plus measure count, key and time of the first measure."""
from __future__ import annotations

from fractions import Fraction

import numpy as np
from lxml import etree

STEP = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def _strip_ns(root):
    for el in root.iter():
        if isinstance(el.tag, str) and "}" in el.tag:
            el.tag = el.tag.split("}", 1)[1]
    return root


def parse(xml: str | bytes) -> dict:
    if isinstance(xml, str):
        xml = xml.encode()
    root = _strip_ns(etree.fromstring(xml, etree.XMLParser(recover=True, huge_tree=True)))
    streams = {}
    nmeas = 0
    key = time = None
    for pi, part in enumerate(root.findall("part")):
        div = 1
        t0 = Fraction(0)
        ms = part.findall("measure")
        nmeas = max(nmeas, len(ms))
        for mi, m in enumerate(ms):
            cur = Fraction(0)
            mlen = Fraction(0)
            last_start = Fraction(0)
            for el in m:
                if el.tag == "attributes":
                    d = el.find("divisions")
                    if d is not None and d.text:
                        div = int(float(d.text))
                    if pi == 0 and mi == 0:
                        k = el.find("key/fifths")
                        if k is not None:
                            key = int(k.text)
                        b, bt = el.find("time/beats"), el.find("time/beat-type")
                        if b is not None and bt is not None:
                            time = f"{b.text}/{bt.text}"
                elif el.tag == "backup":
                    cur -= Fraction(int(float(el.findtext("duration", "0"))), div)
                elif el.tag == "forward":
                    cur += Fraction(int(float(el.findtext("duration", "0"))), div)
                elif el.tag == "note":
                    if el.find("grace") is not None or el.find("cue") is not None:
                        continue
                    dur = Fraction(int(float(el.findtext("duration", "0") or 0)), div)
                    chord = el.find("chord") is not None
                    start = last_start if chord else cur
                    staff = el.findtext("staff", "1")
                    pr = el.find("print-object")
                    hidden = el.get("print-object") == "no"
                    if el.find("rest") is not None:
                        if hidden:
                            ev = None
                        else:
                            ev = ("r", dur)
                    else:
                        p = el.find("pitch")
                        if p is None:
                            ev = None
                        else:
                            midi = 12 * (int(p.findtext("octave")) + 1) + STEP[p.findtext("step")] + int(float(p.findtext("alter", "0") or 0))
                            ev = (midi, dur)
                    if ev is not None:
                        streams.setdefault((pi, staff), []).append((t0 + start, mi, ev))
                    if not chord:
                        last_start = cur
                        cur += dur
                    mlen = max(mlen, cur)
            t0 += mlen
    out, bars = {}, {}
    for k, evs in streams.items():
        evs.sort(key=lambda e: (e[0], 0 if e[2][0] == "r" else 1, e[2][0] if e[2][0] != "r" else 0))
        out[k] = [e[2] for e in evs]
        b = {}
        for e in evs:
            b.setdefault(e[1], []).append(e[2])
        bars[k] = {mi: sorted(v, key=str) for mi, v in b.items()}
    return {"streams": out, "bars": bars, "measures": nmeas, "key": key, "time": time}


def _lcs(a: list, b: list) -> int:
    if not a or not b:
        return 0
    prev = [0] * (len(b) + 1)
    for x in a:
        cur = [0]
        for j, y in enumerate(b):
            cur.append(prev[j] + 1 if x == y else max(prev[j + 1], cur[j]))
        prev = cur
    return prev[-1]


def _edit(a: list, b: list) -> int:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def _tok(ev, with_dur=True):
    p, d = ev
    return (p, d) if with_dur else p


def compare(gt_xml: str, pred_xml: str) -> dict:
    gt, pr = parse(gt_xml), parse(pred_xml)
    gk, pk = list(gt["streams"]), list(pr["streams"])
    # pair streams: maximize pitch LCS
    from scipy.optimize import linear_sum_assignment
    S = np.zeros((len(gk), max(len(pk), 1)))
    for i, a in enumerate(gk):
        ap = [e[0] for e in gt["streams"][a] if e[0] != "r"]
        for j, b in enumerate(pk):
            bp = [e[0] for e in pr["streams"][b] if e[0] != "r"]
            S[i, j] = _lcs(ap, bp)
    pairs = {}
    if pk:
        ri, ci = linear_sum_assignment(-S)
        pairs = {gk[i]: pk[j] for i, j in zip(ri, ci)}
    tot_gt = tot_pr = m_full = m_pitch = n_gt_notes = n_pr_notes = edits = 0
    for a in gk:
        g = gt["streams"][a]
        p = pr["streams"][pairs[a]] if a in pairs else []
        tot_gt += len(g)
        tot_pr += len(p)
        m_full += _lcs([_tok(e) for e in g], [_tok(e) for e in p])
        gn = [e[0] for e in g if e[0] != "r"]
        pn = [e[0] for e in p if e[0] != "r"]
        n_gt_notes += len(gn)
        n_pr_notes += len(pn)
        m_pitch += _lcs(gn, pn)
        edits += _edit([_tok(e) for e in g], [_tok(e) for e in p])
    for b in pk:
        if b not in pairs.values():
            tot_pr += len(pr["streams"][b])
            edits += len(pr["streams"][b])
    f1 = lambda m, a, b: 2 * m / max(a + b, 1)          # noqa: E731
    bar_ok = None
    if gt["measures"] == pr["measures"]:
        bar_ok = []
        for mi in range(gt["measures"]):
            ok = True
            for a in gk:
                g = gt["bars"][a].get(mi, [])
                p = pr["bars"][pairs[a]].get(mi, []) if a in pairs else []
                if g != p:
                    ok = False
                    break
            bar_ok.append(ok)
    return {
        "bar_ok": bar_ok,
        "note_f1": round(f1(m_full, tot_gt, tot_pr), 4),
        "pitch_f1": round(f1(m_pitch, n_gt_notes, n_pr_notes), 4),
        "ser": round(edits / max(tot_gt, 1), 4),
        "gt_events": tot_gt, "pred_events": tot_pr,
        "gt_measures": gt["measures"], "pred_measures": pr["measures"],
        "key_ok": gt["key"] == pr["key"], "time_ok": gt["time"] == pr["time"],
        "streams": [len(gk), len(pk)],
    }


# ---------- "plays the same": what a MIDI player would hear ----------
def _q(x: Fraction) -> Fraction:
    """Round to 1/96 of a quarter so a triplet written with different divisions still matches."""
    return Fraction(round(x * 96), 96)


def sounding(xml: str | bytes) -> dict:
    """Per part: sorted (onset, midi, duration) in quarter notes, tied notes merged, rests and staves ignored."""
    if isinstance(xml, str):
        xml = xml.encode()
    root = _strip_ns(etree.fromstring(xml, etree.XMLParser(recover=True, huge_tree=True)))
    parts, local = [], []
    for part in root.findall("part"):
        div, t0, notes, open_ties = 1, Fraction(0), [], {}
        for bar_i, m in enumerate(part.findall("measure")):
            cur = last = mlen = Fraction(0)
            for el in m:
                if el.tag == "attributes" and el.findtext("divisions"):
                    div = int(float(el.findtext("divisions")))
                elif el.tag == "backup":
                    cur -= Fraction(int(float(el.findtext("duration", "0"))), div)
                elif el.tag == "forward":
                    cur += Fraction(int(float(el.findtext("duration", "0"))), div)
                elif el.tag == "note":
                    if el.find("grace") is not None or el.find("cue") is not None:
                        continue
                    dur = Fraction(int(float(el.findtext("duration", "0") or 0)), div)
                    chord = el.find("chord") is not None
                    start = last if chord else cur
                    p = el.find("pitch")
                    if p is not None and el.find("rest") is None:
                        midi = 12 * (int(p.findtext("octave")) + 1) + STEP[p.findtext("step")] + int(float(p.findtext("alter", "0") or 0))
                        ties = {t.get("type") for t in el.findall("tie")}
                        on = t0 + start
                        if "stop" in ties and midi in open_ties and open_ties[midi][0] + open_ties[midi][2] == on:
                            n = open_ties.pop(midi)
                            n[2] += dur
                        else:
                            n = [on, midi, dur, bar_i, start]
                            notes.append(n)
                        if "start" in ties:
                            open_ties[midi] = n
                    if not chord:
                        last = cur
                        cur += dur
                    mlen = max(mlen, cur)
            t0 += mlen
        parts.append(sorted((_q(a), b, _q(c)) for a, b, c, _, _ in notes))
        local.append(sorted((bi, _q(st), b, _q(c)) for _, b, c, bi, st in notes))
    key = root.findtext(".//attributes/key/fifths")
    b, bt = root.findtext(".//attributes/time/beats"), root.findtext(".//attributes/time/beat-type")
    tempo = root.find(".//sound[@tempo]")
    return {"parts": parts, "local": local, "key": int(key) if key else None, "time": f"{b}/{bt}" if b else None,
            "tempo": float(tempo.get("tempo")) if tempo is not None else None}


def plays_same(gt_xml: str, pred_xml: str) -> dict:
    """play_f1: notes in the same bar, at the same beat, with the same pitch and length, per part (parts paired for
    the best match). Counting beats within each bar keeps one wrong rhythm from shifting every later note.
    `identical` means a MIDI player would play both files the same at any tempo: every note matches and the key
    and time signature agree (key matters for display only; pitches already carry the accidentals)."""
    from collections import Counter
    from scipy.optimize import linear_sum_assignment
    g, p = sounding(gt_xml), sounding(pred_xml)
    def best(G, P):
        M = np.zeros((len(G), max(len(P), 1)))
        for i, a in enumerate(G):
            for j, b in enumerate(P):
                M[i, j] = sum((Counter(a) & Counter(b)).values())
        if not (P and G):
            return 0
        ri, ci = linear_sum_assignment(-M)
        return int(M[ri, ci].sum())
    ng, npred = sum(map(len, g["parts"])), sum(map(len, p["parts"]))
    f1 = 2 * best(g["local"], p["local"]) / max(ng + npred, 1)
    same_notes = best(g["parts"], p["parts"]) == ng == npred
    return {"play_f1": round(f1, 4), "same_notes": same_notes, "key_ok": g["key"] == p["key"],
            "time_ok": g["time"] == p["time"], "identical": same_notes and g["key"] == p["key"] and g["time"] == p["time"],
            "gt_notes": ng, "pred_notes": npred, "tempo_gt": g["tempo"], "tempo_pred": p["tempo"]}
