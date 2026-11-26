# MusicScan benchmark

## How good is MusicScan? (rough scorecard, 2026-11-26)

| Question | Answer | How sure |
| --- | --- | --- |
| Notes right on a readable page (pitch and length) | **about 97–98%** over 28 pieces and 6 kinds of photo damage; piano 97%, single instrument 99% | measured |
| Sheetly's benchmark, with their scorer | **about 98% strict F1 on clean pages, over every page**, on 7 of their 31 pieces (pages we engraved from their ground truth). Sheetly publishes 97.4% on page one only, on their own images. Roughly level; their photo suite not run yet | partial estimate |
| After fixing the bars MusicScan marks | **about 99%** on the same 7 pieces | partial estimate |
| Whole page perfect with no edits | rare: 6 of 28 clean pages play identically. Median wrong bars per page: 1–2 for single instruments and choir, **3–4 of 14 for piano** | measured |
| Are the wrong bars marked? | **65% of wrong bars are marked; 58% of marks are real errors; 8% of correct bars get a mark** (80% / 51% / 9% on the first 14 pieces) | measured |
| Is a bad photo caught? | **28 of 28** unusable photos rated "retake", **0 of 168** usable pages | measured, simulated damage |
| Key and time signature | key right on every readable page; time right on 27 of 28 (cut time read as 4/4, which plays the same) | measured |

Weak spots, most important first for piano and single-instrument music:

1. **Piano pages** have the most slips: a missed note inside a chord, a triplet sign put on the wrong notes
   (Chopin: quarters read as triplet quarters), irregular runs (C.P.E. Bach: 13 notes in a beat read as
   sextuplets), and a missed clef change that moves a passage (Schoenberg).
2. **Songs** (voice and piano, lyrics between the staves): 95–97%.
3. **String quartets in score** (4 staves): Schumann Op. 41 reads 75%. Choir and ensembles are not a focus and are
   reported separately.
4. Not measured: real phone photos (all damage here is simulated), ties, slurs, dynamics and articulations.

What a user sees: on a typical piano page two or three bars are marked to check, one or two of them really wrong,
plus about one wrong bar that is not marked. A single-instrument page usually needs one fix or none.

**Run Sheetly's benchmark yourself**, from the MusicScan folder on the Mac:

```bash
git pull
bench/sheetly_compare.sh --max-pages 1   # quick, about 10 minutes: page one, the same window as Sheetly's table
bench/sheetly_compare.sh                 # every page of both suites, an hour or more; resumes if stopped
```

It prints strict F1, the number after fixing the marked bars, the page-one number to set next to Sheetly's 97.4%,
and what kind of mistakes are left (missed, extra, wrong pitch, wrong length, wrong beat).

## Setup

Run on 2026-11-26 in a 4-core cloud container (CPU only): copista-28m, 28 pieces × 7 photo conditions, 196 pages.
The second reading behind the bar marks (copista-2m) was run on the same pages separately.

## How it works

1. **Ground truth.** 28 excerpts from the music21 corpus (free to use): 6 piano (Mozart K.545, Clara Schumann,
   Joplin, Chopin, C.P.E. Bach, Schoenberg), 10 single instruments (violin, viola in alto clef, cello, clarinet),
   3 songs (Schubert, Schumann, Handel) and 9 choir and ensemble (Bach chorales, Johnson, string quartets, Corelli). Each is shortened until it fits one page and engraved with Verovio, so the
   image shows exactly what the MusicXML says (`bench/make_set.py`).
2. **Damage** (`bench/degrade.py`, seeded): clean · photo (desk, perspective, warm light, blur, JPEG) · shadow
   (hand/phone shadow + vignette) · pen (red/blue circles, arrows, words, fingerings) · pencil (grey marks that can't
   be removed by colour) · combo (photo + shadow + pen) · lowq (far away, out of focus, dim, noisy: must be flagged).
3. **Read it back** two ways: *raw* (the OMR on the photo as is) and *MusicScan* (page finding, dewarp, shadow
   flattening and pen removal, then the OMR). Output is MusicXML (`bench/run.py`).
4. **Score** against the ground truth (`musicscan/compare.py`):
   - *Note F1*: per staff, notes and rests in order as (pitch, length), aligned by longest common subsequence.
     Lengths are rounded to 1/96 of a beat, so a triplet written with odd divisions still matches.
     Missed and invented notes both count against it. *Pitch F1* is the same for pitches only.
   - *Plays the same*: per part, every sounding note as (bar, beat in the bar, pitch, length), ties joined, rests
     ignored. A page is **identical** only when every note matches at its absolute time and the key and time
     signature agree, so a MIDI player plays both files the same at any tempo.
   - *Quality verdict*: the app's photo check (good / check / retake).
   - *Bar flags*: which bars the app marks "check" or "likely wrong", against the bars that really differ.

Not checked: ties/slurs/dynamics/articulations/ornaments, beams, stems, voice numbers, grace notes, layout. Tempo
isn't compared because the test pages carry no tempo marking. Photo damage is simulated, and all pages are
modern engravings.

## Accuracy

| Condition | Pages | Pitch F1 raw → MusicScan | Note F1 (pitch+rhythm) raw → MusicScan | Error rate (SER) MusicScan | Bars right | Quality verdicts (good/check/retake) |
| --- | --- | --- | --- | --- | --- | --- |
| clean | 28 | 99.0% → **99.0%** | 97.8% → **97.8%** | 2.6% | 93% | 28/0/0 |
| photo | 28 | 92.6% → **98.8%** | 89.5% → **97.5%** | 3.1% | 93% | 28/0/0 |
| shadow | 28 | 79.3% → **98.9%** | 72.4% → **97.7%** | 2.8% | 89% | 28/0/0 |
| pen | 28 | 98.9% → **98.9%** | 97.5% → **97.8%** | 2.7% | 93% | 28/0/0 |
| pencil | 28 | 98.1% → **98.1%** | 96.8% → **96.8%** | 3.8% | 96% | 28/0/0 |
| combo | 28 | 91.5% → **98.7%** | 88.0% → **97.5%** | 3.1% | 89% | 28/0/0 |
| lowq | 28 | 1.4% → **39.8%** | 0.9% → **29.1%** | 86.7% | 4% | 0/0/28 |

By kind of page (note F1, MusicScan):

| Kind of page | Pieces | clean | photo | shadow | pen | pencil | combo |
| --- | --- | --- | --- | --- | --- | --- | --- |
| piano | 6 | 97.4% | 97.3% | 97.7% | 97.2% | 97.2% | 97.3% |
| single instrument | 10 | 99.1% | 98.4% | 99.1% | 99.1% | 97.9% | 98.9% |
| voice and piano | 3 | 96.8% | 96.4% | 96.0% | 96.8% | 95.8% | 94.7% |
| choir and ensemble | 9 | 97.0% | 97.0% | 96.8% | 97.0% | 95.7% | 97.0% |

## Does it play the same?

| Condition | Pages | Plays identically raw → MusicScan | Notes at the right beat, pitch and length raw → MusicScan | Key right | Time right |
| --- | --- | --- | --- | --- | --- |
| clean | 28 | 6/28 → **6/28** | 97.2% → **97.2%** | 28/28 | 27/28 |
| photo | 28 | 2/28 → **3/28** | 76.4% → **95.6%** | 28/28 | 27/28 |
| shadow | 28 | 1/28 → **3/28** | 46.8% → **93.5%** | 28/28 | 28/28 |
| pen | 28 | 3/28 → **6/28** | 96.9% → **97.1%** | 28/28 | 27/28 |
| pencil | 28 | 5/28 → **5/28** | 96.1% → **96.1%** | 28/28 | 27/28 |
| combo | 28 | 0/28 → **2/28** | 76.9% → **95.2%** | 28/28 | 27/28 |
| lowq | 28 | 0/28 → **0/28** | 0.2% → **6.9%** | 14/28 | 9/28 |

About 96–99% of notes land in the right bar, on the right beat, with the right pitch and length, and the key is
right on every readable page. Whole pages are rarely perfect: most have 1 to 4 slips (a median of 1–2 wrong bars per page for single
instruments, 3–4 for piano). What they were, over the first 14 pieces' 166 wrong bars: 46% a missed note (often one note of a chord), 28% a wrong pitch (usually a
semitone), 12% a rest, 11% a wrong length. Cut time (2/2) read as 4/4 on one piece plays identically.

Cascading: a wrong length shifts playback until it is fixed, but the bar no longer adds up and the editor draws it
in red. A missed barline is split back into two bars by the sanitizer. Wrong pitches and missed notes stay in
their bar.

## Is a bad photo caught?

Every one of the 28 *lowq* photos was rated **retake**, and all 168 other pages (clean and the five usable kinds of
damage) were rated good. On the bad photos MusicScan still reads 29% of notes (raw OMR: 1%), not enough to use.

## Are wrong bars flagged?

| Condition | Bars compared | Bars with an error | Wrong bars marked | Marks that were wrong bars | Correct bars marked |
| --- | --- | --- | --- | --- | --- |
| clean | 576 | 75 | 64% (44% red) | 55% (red 66%) | 8% |
| photo | 576 | 84 | 61% (44% red) | 57% (red 67%) | 8% |
| shadow | 536 | 79 | 63% (48% red) | 60% (red 70%) | 7% |
| pen | 576 | 76 | 67% (46% red) | 56% (red 62%) | 8% |
| pencil | 616 | 93 | 74% (48% red) | 59% (red 62%) | 9% |
| combo | 536 | 82 | 60% (45% red) | 60% (red 69%) | 7% |
| all | 3416 | 489 | 65% (46% red) | 58% (red 66%) | 8% |

(155 pages where the bar count matched the ground truth. On 60 of the 131 pages with an error, every wrong bar was marked.)

Each page is read twice, by copista-28m and by the small copista-2m (about 3 s more). How the two readings differ
decides the mark, calibrated on the first 14 pieces. When the second reading has notes the main one lacks, the bar
was wrong 91% of the time (red). When both have notes the other lacks, 43% (red). When only rests differ, 54%
(amber). When only the small model missed notes, 9% (not marked). Bars the sanitizer had to repair, and bars below
0.5 confidence, are amber. Confidence alone marks bars only when there is no second reading, because most errors are
confident misreads or missed symbols. Before the second reading, marks found only 50% of wrong bars. The earlier
rule (mark any disagreement) found 89% but marked 28% of all bars, mostly correct ones.

## Per piece (MusicScan, note F1)

| Piece | clean | photo | shadow | pen | pencil | combo | lowq |
| --- | --- | --- | --- | --- | --- | --- | --- |
| bach_bwv10_7 | 100% | 100% | 100% | 100% | 100% | 100% | 19% |
| bach_bwv1_6 | 100% | 99% | 99% | 100% | 100% | 100% | 32% |
| bach_bwv269 | 100% | 100% | 100% | 100% | 100% | 100% | 22% |
| bach_bwv66 | 100% | 99% | 99% | 100% | 100% | 100% | 89% |
| bach_bwv7_7 | 100% | 100% | 99% | 100% | 100% | 99% | 17% |
| beethoven_18_vc | 100% | 95% | 100% | 100% | 99% | 100% | 30% |
| beethoven_18_viola | 100% | 99% | 100% | 100% | 100% | 99% | 58% |
| beethoven_59_2_vc | 99% | 99% | 99% | 99% | 97% | 99% | 0% |
| beethoven_59_vn1 | 100% | 98% | 100% | 100% | 99% | 99% | 57% |
| chopin_mazurka | 97% | 97% | 98% | 97% | 97% | 98% | 16% |
| clara_polonaise | 98% | 97% | 99% | 98% | 98% | 98% | 36% |
| corelli_trio | 100% | 100% | 100% | 100% | 88% | 100% | 24% |
| cpebach_h186 | 93% | 94% | 94% | 92% | 93% | 92% | 3% |
| handel_lascia | 100% | 99% | 99% | 100% | 99% | 99% | 10% |
| haydn_1_viola | 99% | 99% | 100% | 99% | 99% | 99% | 74% |
| haydn_74_viola | 100% | 100% | 100% | 100% | 98% | 100% | 12% |
| haydn_74_vn1 | 98% | 98% | 98% | 98% | 98% | 98% | 23% |
| johnson_lift | 99% | 99% | 99% | 99% | 99% | 100% | 23% |
| joplin_rag | 100% | 99% | 99% | 100% | 99% | 99% | 10% |
| mozart_k155_vn2 | 100% | 100% | 99% | 100% | 91% | 99% | 32% |
| mozart_k458_quartet | 99% | 99% | 100% | 99% | 99% | 100% | 40% |
| mozart_k545 | 100% | 100% | 100% | 100% | 100% | 100% | 42% |
| mozart_k80_vn1 | 98% | 99% | 98% | 98% | 99% | 98% | 50% |
| schoenberg_op19 | 96% | 96% | 96% | 96% | 96% | 97% | 21% |
| schubert_lindenbaum | 99% | 98% | 97% | 99% | 99% | 97% | 11% |
| schumann_dichterliebe2 | 92% | 92% | 92% | 92% | 90% | 88% | 20% |
| schumann_op41_quartet | 75% | 76% | 75% | 76% | 75% | 76% | 28% |
| weber_clarinet | 99% | 98% | 98% | 99% | 98% | 98% | 15% |

The cleanup matters most for shadows and full phone photos (raw 72–90% → 97–98%). On clean and pen-marked pages,
raw and MusicScan are the same: the OMR ignores coloured ink well on its own.

## Reproduce

```bash
python bench/make_set.py bench/data
python bench/run.py bench/data bench/results            # resumable
python bench/report.py bench/results bench/data         # these tables
python bench/gallery.py bench/data bench/results out/ mozart_k545   # side-by-side images
bench/sheetly_compare.sh --max-pages 1                  # Sheetly's benchmark, quick
```
