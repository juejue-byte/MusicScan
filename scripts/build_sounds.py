"""Build the bundled playback instruments (web/vendor/sounds/) from the FluidR3 GM soundfont (MIT, Frank Wen).

Source: the npm package soundfont-for-samplers (MIT), which holds one MP3 per note converted from FluidR3_GM.sf2:
    curl -o sf.tgz https://registry.npmjs.org/soundfont-for-samplers/-/soundfont-for-samplers-0.0.3.tgz
    tar xzf sf.tgz && python scripts/build_sounds.py package/FluidR3_GM

Each instrument becomes ONE mono MP3: a sample every 3 semitones, each in a fixed-length slot that starts with a short
lead of silence (so a browser's MP3 decoder delay never clips an attack). audio.js decodes the file once, slices slots
and pitch-shifts to the nearest sample. Needs ffmpeg.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

SR = 44100
LEAD = 0.05     # silence before each sample (s)
NAMES = ['C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B']

# id: (FluidR3 folder, label, GM program for MIDI export, lowest, highest midi, slot seconds, loop region or None)
INSTRUMENTS = {
    'piano':    ('acoustic_grand_piano', 'Piano', 0, 21, 108, 2.6, None),
    'epiano':   ('electric_piano_1', 'Electric piano', 4, 28, 103, 2.2, None),
    'organ':    ('drawbar_organ', 'Organ', 16, 24, 96, 1.6, (0.5, 1.4)),
    'strings':  ('string_ensemble_1', 'Strings', 48, 28, 96, 2.0, (0.8, 1.8)),
    'violin':   ('violin', 'Violin', 40, 55, 100, 2.0, (0.7, 1.8)),
    'cello':    ('cello', 'Cello', 42, 36, 76, 2.0, (0.7, 1.8)),
    'flute':    ('flute', 'Flute', 73, 60, 96, 2.0, (0.7, 1.8)),
    'clarinet': ('clarinet', 'Clarinet', 71, 50, 91, 2.0, (0.7, 1.8)),
    'choir':    ('pad_4_choir', 'Choir', 52, 36, 84, 2.0, (0.9, 1.8)),
    'trumpet':  ('trumpet', 'Trumpet', 56, 54, 84, 1.8, (0.6, 1.6)),
    'sax':      ('alto_sax', 'Saxophone', 65, 49, 84, 1.8, (0.6, 1.6)),
    'guitar':   ('acoustic_guitar_nylon', 'Guitar', 24, 40, 84, 2.0, None),
}


def note_file(folder: Path, midi: int) -> Path:
    return folder / f'{NAMES[midi % 12]}{midi // 12 - 1}.mp3'


def main(src: str, out: str = 'web/vendor/sounds'):
    src, out = Path(src), Path(out)
    out.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for key, (folder, label, program, lo, hi, slot, loop) in INSTRUMENTS.items():
        d = src / f'{folder}-mp3'
        notes = [m for m in range(lo - lo % 3, hi + 3, 3) if note_file(d, m).exists()]
        with tempfile.TemporaryDirectory() as tmp:
            parts = []
            for i, m in enumerate(notes):
                p = Path(tmp) / f'{i:03d}.wav'
                fade = 0.12 if loop is None else 0.08
                af = (f'adelay={int(LEAD * 1000)},apad=whole_dur={slot},atrim=0:{slot},'
                      f'afade=t=out:st={slot - fade}:d={fade}')
                subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(note_file(d, m)), '-ac', '1', '-ar', str(SR),
                                '-af', af, str(p)], check=True)
                parts.append(p)
            lst = Path(tmp) / 'list.txt'
            lst.write_text(''.join(f"file '{p}'\n" for p in parts))
            dst = out / f'{key}.mp3'
            subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(lst),
                            '-ac', '1', '-b:a', '48k', str(dst)], check=True)
        manifest[key] = {'label': label, 'program': program, 'notes': notes, 'slot': slot, 'lead': LEAD,
                         'loop': list(loop) if loop else None, 'file': f'{key}.mp3'}
        print(f'{key:9s} {len(notes):2d} samples {dst.stat().st_size / 1024:6.0f} KB')
    (out / 'sounds.json').write_text(json.dumps(manifest, indent=1))
    (out / 'LICENSE.txt').write_text(
        'Samples converted from the FluidR3 GM SoundFont, Copyright (c) 2000-2002, 2008, 2013 Frank Wen, MIT License,\n'
        'via the npm package soundfont-for-samplers (MIT). Built by scripts/build_sounds.py.\n')


if __name__ == '__main__':
    main(*sys.argv[1:])
