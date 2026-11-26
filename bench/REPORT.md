# MusicScan benchmark

Run on 2026-11-26 in a 4-core cloud container (CPU only), copista-28m, 14 pieces × 7 photo conditions, 182 runs.
Median 11.9 s per page.

## How it works

1. **Ground truth.** 14 excerpts from the music21 corpus (free to use): Bach chorales (4 voices on 2 staves),
   Mozart K.545 and Clara Schumann (piano), Joplin (piano, dense), violin, cello, viola (alto clef), clarinet, a
   string quartet and a Handel aria. Each is shortened until it fits one page and engraved with Verovio, so the
   image shows exactly what the MusicXML says (`bench/make_set.py`).
2. **Damage** (`bench/degrade.py`, seeded): clean · photo (desk, perspective, warm light, blur, JPEG) · shadow
   (hand/phone shadow + vignette) · pen (red/blue circles, arrows, words, fingerings) · pencil (grey marks that can't
   be removed by colour) · combo (photo + shadow + pen) · lowq (far away, out of focus, dim, noisy: must be flagged).
3. **Read it back** two ways: *raw* (the OMR on the photo as is) and *MusicScan* (page finding, dewarp, shadow
   flattening and pen removal, then the OMR). Output is MusicXML (`bench/run.py`).
4. **Score** against the ground truth (`musicscan/compare.py`):
   - *Note F1*: per staff, notes and rests in order as (pitch, length), aligned by longest common subsequence.
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
| clean | 14 | 99.4% → **99.4%** | 99.1% → **99.1%** | 1.2% | 86% | 14/0/0 |
| photo | 14 | 95.3% → **99.1%** | 93.5% → **98.6%** | 1.9% | 86% | 14/0/0 |
| shadow | 14 | 81.6% → **99.2%** | 75.6% → **99.0%** | 1.3% | 86% | 14/0/0 |
| pen | 14 | 99.4% → **99.4%** | 99.0% → **99.1%** | 1.3% | 86% | 14/0/0 |
| pencil | 14 | 99.5% → **99.5%** | 98.9% → **98.9%** | 1.6% | 93% | 14/0/0 |
| combo | 14 | 88.1% → **99.2%** | 85.1% → **99.0%** | 1.4% | 79% | 14/0/0 |
| lowq | 14 | 2.3% → **46.6%** | 1.4% → **33.5%** | 79.3% | 0% | 0/0/14 |

## Does it play the same?

| Condition | Pages | Plays identically raw → MusicScan | Notes at the right beat, pitch and length raw → MusicScan | Key right | Time right |
| --- | --- | --- | --- | --- | --- |
| clean | 14 | 2/14 → **2/14** | 93.8% → **93.8%** | 14/14 | 13/14 |
| photo | 14 | 0/14 → **2/14** | 82.3% → **92.8%** | 14/14 | 13/14 |
| shadow | 14 | 0/14 → **1/14** | 39.8% → **94.8%** | 14/14 | 14/14 |
| pen | 14 | 2/14 → **2/14** | 93.8% → **93.7%** | 14/14 | 13/14 |
| pencil | 14 | 3/14 → **3/14** | 98.6% → **98.6%** | 14/14 | 13/14 |
| combo | 14 | 0/14 → **2/14** | 74.7% → **95.1%** | 14/14 | 13/14 |
| lowq | 14 | 0/14 → **0/14** | 0.3% → **9.7%** | 9/14 | 5/14 |


Note accuracy is about 99%, but whole pages are rarely perfect: most pages have 1 to 4 slips (a 16th read as an
8th, a note a semitone off, a missed barline). The "notes at the right beat" column is lower than note F1 because
a missed or extra barline moves every later note into the wrong bar. In the app those bars show up red (they don't
add up), and fixing them takes a click or two. Cut time (2/2) read as 4/4 on one piece plays identically.

## Is a bad photo caught?

Every one of the 14 *lowq* photos was rated **retake**, and all 84 other pages (clean and the five usable kinds of damage) were
rated good. On those, MusicScan reads 33% of notes; raw OMR reads 1%.

## Are wrong bars flagged?

| Condition | Bars compared | Bars with an error | Wrong bars flagged | Flags that were wrong bars | Correct bars flagged |
| --- | --- | --- | --- | --- | --- |
| clean | 273 | 27 | 37% | 33% | 8% |
| photo | 273 | 29 | 59% | 26% | 20% |
| shadow | 273 | 29 | 34% | 22% | 15% |
| pen | 273 | 29 | 34% | 31% | 9% |
| pencil | 313 | 35 | 57% | 27% | 20% |
| combo | 233 | 24 | 42% | 34% | 9% |
| all | 1638 | 173 | 45% | 28% | 14% |

(72 pages where the bar count matched the ground truth.)

This is the weakest part. Flags catch under half of the wrong bars, and about 1 in 7 correct bars gets a "check".
Most misses are confident misreads (a semitone off, a wrong rhythm) and dropped whole-bar rests. Next step:
calibrate on these results and add a "bar doesn't add up" signal (already drawn in red in the editor).

## Per piece (MusicScan, note F1)

| Piece | clean | photo | shadow | pen | pencil | combo | lowq |
| --- | --- | --- | --- | --- | --- | --- | --- |
| bach_bwv1_6 | 100% | 99% | 99% | 100% | 100% | 100% | 32% |
| bach_bwv269 | 100% | 100% | 100% | 100% | 100% | 100% | 22% |
| bach_bwv66 | 100% | 99% | 99% | 100% | 100% | 100% | 89% |
| beethoven_18_vc | 100% | 95% | 100% | 100% | 99% | 100% | 30% |
| beethoven_18_viola | 100% | 99% | 100% | 100% | 100% | 99% | 58% |
| clara_polonaise | 98% | 97% | 99% | 98% | 98% | 98% | 36% |
| handel_lascia | 100% | 99% | 99% | 100% | 99% | 99% | 10% |
| haydn_74_viola | 100% | 100% | 100% | 100% | 98% | 100% | 12% |
| haydn_74_vn1 | 98% | 98% | 98% | 98% | 98% | 98% | 23% |
| joplin_rag | 100% | 99% | 99% | 100% | 99% | 99% | 10% |
| mozart_k458_quartet | 99% | 99% | 100% | 99% | 99% | 100% | 40% |
| mozart_k545 | 100% | 100% | 100% | 100% | 100% | 100% | 42% |
| mozart_k80_vn1 | 98% | 99% | 98% | 98% | 99% | 98% | 50% |
| weber_clarinet | 96% | 95% | 95% | 96% | 96% | 96% | 15% |

The cleanup matters most for shadows and full phone photos (raw 76–85% → 99%). On clean and pen-marked pages,
raw and MusicScan are the same: the OMR ignores coloured ink well on its own.

## Reproduce

```bash
python bench/make_set.py bench/data
python bench/run.py bench/data bench/results            # resumable
python bench/report.py bench/results bench/data         # these tables
python bench/gallery.py bench/data bench/results out/ mozart_k545   # side-by-side images
```
