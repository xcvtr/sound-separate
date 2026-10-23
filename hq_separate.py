#!/usr/bin/env python
"""High-quality stem separation pipeline (Demucs).

Stage 1: htdemucs_ft  -> vocals, drums, bass, other   (best 4-stem quality)
Stage 2: htdemucs_6s  -> guitar, piano                 (only model with these stems)

Final stems = ft(vocals, drums, bass) + 6s(guitar, piano) + (ft.other - guitar - piano).
Because ft reconstructs the mix on its own, this keeps the sum equal to the original.
"""
import argparse
import math
import shutil
import sys
import traceback
from pathlib import Path

import numpy as np
import torch
from tqdm import tqdm

import progress
from demucs.api import Separator
from demucs.audio import encode_wav, prevent_clip

progress.apply_tqdm_patch()
progress.install_demucs_ffmpeg_hook()
progress.install_hf_silence_hook()
progress.install_demucs_bag_hook()

try:
    import lameenc
except ImportError:  # pragma: no cover
    lameenc = None


def _trim(a, n):
    return a[..., :n]


class _SepProgress:
    """Monotonic progress bar driven by Demucs callbacks."""

    def __init__(self, bar: tqdm):
        self.bar = bar
        self._seen = set()

    def __call__(self, data: dict) -> None:
        if data.get("state") != "end":
            return
        models = int(data.get("models", 1) or 1)
        shifts = int(data.get("shifts", 1) or 1)
        length = float(data.get("audio_length", 1) or 1)
        length = int(round(length + 1e-9))
        model_idx = int(data.get("model_idx_in_bag", 0))
        shift_idx = int(data.get("shift_idx", 0))
        offset = float(data.get("segment_offset", 0))
        offset = int(math.floor(offset + 1e-9))

        key = (model_idx, shift_idx, offset)
        if key in self._seen:
            return
        self._seen.add(key)

        total_weight = models * shifts * length
        if total_weight <= 0:
            return
        done = (model_idx * shifts + shift_idx) * length + offset
        if done > total_weight:
            done = total_weight
        if done < 0:
            done = 0
        n = int(self.bar.total or length)
        if n <= 0:
            n = length
        self.bar.n = int(min(n, round(n * done / total_weight)))
        self.bar.refresh()


def _separate(sep: Separator, track: Path, label: str):
    """Run separation with a stable progress bar; returns (samplerate, stems)."""
    wav = sep._load_audio(track)
    length = wav.shape[1]
    with tqdm(total=max(1, length), unit="fr", desc=label, leave=False) as bar:
        sep._callback = _SepProgress(bar)
        sep._progress = False
        _, stems = sep.separate_tensor(wav, sr=sep.samplerate)
    return sep._samplerate, stems


def _encode_mp3(wav: torch.Tensor, path: Path, samplerate: int,
                bitrate: int = 320, quality: int = 2, desc: str = "") -> None:
    """Encode [C, T] float tensor to mp3 with a progress bar.

    Prefer ffmpeg (libmp3lame, writes the LAME "Info" gapless tag); lameenc is
    only a fallback when ffmpeg is missing.
    """
    channels, length = wav.shape
    pcm = (wav.clamp_(-1, 1) * (2 ** 15 - 1)).short().t().contiguous().numpy()

    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg:
        command = [
            ffmpeg, "-y", "-v", "error",
            "-f", "s16le", "-ar", str(samplerate), "-ac", str(channels), "-i", "-",
            "-c:a", "libmp3lame", "-b:a", f"{bitrate}k",
            str(path),
        ]
        progress.run_ffmpeg(command, input_bytes=pcm.tobytes(), check=True, desc=desc or "ffmpeg")
        return

    if lameenc is None:
        raise RuntimeError("Neither ffmpeg nor lameenc is available; cannot write mp3.")

    encoder = lameenc.Encoder()
    encoder.set_bit_rate(bitrate)
    encoder.set_in_sample_rate(samplerate)
    encoder.set_channels(channels)
    encoder.set_quality(quality)
    encoder.silence()

    chunk = 1 << 18  # samples per chunk
    with open(path, "wb") as f:
        with tqdm(total=length, unit="fr", desc=desc, leave=False) as bar:
            for start in range(0, length, chunk):
                block = pcm[start:start + chunk].tobytes()
                data = encoder.encode(block)
                if data:
                    f.write(data)
                bar.update(min(chunk, length - start))
            tail = encoder.flush()
            if tail:
                f.write(tail)


def _encode_wav(wav: torch.Tensor, path: Path, samplerate: int,
                bits: int, as_float: bool, desc: str = "") -> None:
    """Write [C, T] float tensor to wav (delegates to Demucs' encoder)."""
    encode_wav(wav, str(path), samplerate, bits_per_sample=bits, as_float=as_float)


def run(track: Path, out_root: Path, device: str, shifts: int, segment, bits: int,
        as_float: bool, stems: list | None = None, fmt: str = "mp3") -> Path:
    name = track.stem
    outdir = out_root / name
    outdir.mkdir(parents=True, exist_ok=True)

    want = set(stems) if stems else None

    def keep(stem: str) -> bool:
        return want is None or stem in want

    sep_ft = Separator(model="htdemucs_ft", device=device, shifts=shifts,
                       segment=segment, progress=False,
                       callback_arg={"shifts": shifts})
    sr, ft = _separate(sep_ft, track, f"[{name}] htdemucs_ft")
    del sep_ft
    if device == "cuda":
        torch.cuda.empty_cache()

    n = ft["vocals"].shape[-1]

    need_guitar_piano = want is None or "guitar" in want or "piano" in want
    six = None
    if need_guitar_piano:
        sep_6s = Separator(model="htdemucs_6s", device=device, shifts=shifts,
                           segment=segment, progress=False,
                           callback_arg={"shifts": shifts})
        _, six = _separate(sep_6s, track, f"[{name}] htdemucs_6s")
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
        wav = prevent_clip(wav, mode="rescale")
        path = outdir / f"{stem}_only.{fmt}"
        desc = f"[{name}] {stem}"
        if fmt == "mp3":
            _encode_mp3(wav, path, sr, desc=desc)
        else:
            _encode_wav(wav, path, sr, bits=bits, as_float=as_float, desc=desc)
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
    ap.add_argument("--format", dest="fmt", default="mp3", choices=["mp3", "wav"], help="Output format.")
    args = ap.parse_args()

    device = args.device or ("cuda" if torch.cuda.is_available() else "cpu")
    out_root = Path(args.out)
    stems = [s.strip() for s in args.stems.split(",") if s.strip()] or None

    for t in args.tracks:
        track = Path(t)
        if not track.is_file():
            print(f"skip (not found): {t}", file=sys.stderr)
            continue
        try:
            run(track, out_root, device, args.shifts, args.segment, args.bits, args.as_float, stems, args.fmt)
        except SystemExit:
            raise
        except BaseException as exc:  # noqa: BLE001 - нужен код возврата для ретрая
            traceback.print_exc()
            if progress.is_oom(exc):
                print(
                    "\n[hq] Not enough VRAM (CUDA out of memory). "
                    "Retry with a smaller segment (--segment 4) or close GPU apps.",
                    file=sys.stderr,
                )
                return 90
            print(f"\n[hq] Failed: {type(exc).__name__}: {exc}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
