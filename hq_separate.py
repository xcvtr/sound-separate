#!/usr/bin/env python
"""High-quality stem separation pipeline (Demucs).

Stage 1: htdemucs_ft  -> vocals, drums, bass, other   (best 4-stem quality)
Stage 2: htdemucs_6s  -> guitar, piano                 (only model with these stems)

Final stems = ft(vocals, drums, bass) + 6s(guitar, piano) + (ft.other - guitar - piano).
Because ft reconstructs the mix on its own, this keeps the sum equal to the original.
"""
import argparse
import sys
from pathlib import Path

import torch

from demucs.api import Separator, save_audio


def _trim(a, n):
    return a[..., :n]


def run(track: Path, out_root: Path, device: str, shifts: int, segment, bits: int,
        as_float: bool, stems: list | None = None) -> Path:
    name = track.stem
    outdir = out_root / name
    outdir.mkdir(parents=True, exist_ok=True)

    want = set(stems) if stems else None

    def keep(stem: str) -> bool:
        return want is None or stem in want

    print(f"[{name}] htdemucs_ft (vocals/drums/bass/other) ...", flush=True)
    sep_ft = Separator(model="htdemucs_ft", device=device, shifts=shifts, segment=segment)
    sr = sep_ft.samplerate
    _, ft = sep_ft.separate_audio_file(track)
    del sep_ft
    if device == "cuda":
        torch.cuda.empty_cache()

    n = ft["vocals"].shape[-1]

    need_guitar_piano = want is None or "guitar" in want or "piano" in want
    six = None
    if need_guitar_piano:
        print(f"[{name}] htdemucs_6s (guitar/piano) ...", flush=True)
        sep_6s = Separator(model="htdemucs_6s", device=device, shifts=shifts, segment=segment)
        _, six = sep_6s.separate_audio_file(track)
        del sep_6s
        if device == "cuda":
            torch.cuda.empty_cache()
        n = min(n, six["guitar"].shape[-1], six["piano"].shape[-1])

    vocals = _trim(ft["vocals"], n)
    drums = _trim(ft["drums"], n)
    bass = _trim(ft["bass"], n)
    guitar = _trim(six["guitar"], n) if six is not None else None
    piano = _trim(six["piano"], n) if six is not None else None
    other = _trim(ft["other"], n)
    if guitar is not None:
        other = other - guitar - piano

    all_stems = {
        "vocals": vocals,
        "drums": drums,
        "bass": bass,
        "guitar": guitar,
        "piano": piano,
        "other": other,
    }

    for stem, wav in all_stems.items():
        if wav is None or not keep(stem):
            continue
        path = outdir / f"{stem}.wav"
        save_audio(
            wav,
            str(path),
            samplerate=sr,
            clip="rescale",
            as_float=as_float,
            bits_per_sample=bits,
        )
    print(f"[{name}] done -> {outdir}", flush=True)
    return outdir


def main():
    ap = argparse.ArgumentParser(description="High-quality Demucs separation (ft + 6s).")
    ap.add_argument("tracks", nargs="+", help="Input audio file(s).")
    ap.add_argument("-o", "--out", default="separated_hq", help="Output root folder.")
    ap.add_argument("--device", default=None, choices=[None, "cuda", "cpu"])
    ap.add_argument("--shifts", type=int, default=2, help="Random shifts (quality vs time).")
    ap.add_argument("--segment", type=int, default=None, help="Segment length (lower = less VRAM).")
    ap.add_argument("--bits", type=int, default=24, choices=[16, 24, 32], help="WAV bit depth.")
    ap.add_argument("--float32", dest="as_float", action="store_true", help="Save float32 WAV.")
    ap.add_argument("--stems", default="", help="Comma-separated stems to save (default: all).")
    args = ap.parse_args()

    device = args.device or ("cuda" if torch.cuda.is_available() else "cpu")
    out_root = Path(args.out)
    stems = [s.strip() for s in args.stems.split(",") if s.strip()] or None

    for t in args.tracks:
        track = Path(t)
        if not track.is_file():
            print(f"skip (not found): {t}", file=sys.stderr)
            continue
        run(track, out_root, device, args.shifts, args.segment, args.bits, args.as_float, stems)


if __name__ == "__main__":
    main()
